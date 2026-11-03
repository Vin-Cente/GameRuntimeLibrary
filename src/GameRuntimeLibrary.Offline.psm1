$ErrorActionPreference = 'Stop'

function Get-GrlFeaturePayloadFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceDirectory,
        [Parameter(Mandatory = $true)]
        [string]$FeatureName
    )

    if (-not (Test-Path -LiteralPath $SourceDirectory -PathType Container)) {
        return @()
    }
    $patterns = switch ($FeatureName) {
        'NetFx3' { @('Microsoft-Windows-NetFx3-OnDemand-Package*.cab', 'Microsoft-Windows-NetFx3-OnDemand-Package*.mum') }
        'DirectPlay' { @('Microsoft-Windows-DirectPlay*.cab', 'Microsoft-Windows-DirectPlay*.mum') }
        default { @() }
    }
    $files = @()
    foreach ($pattern in $patterns) {
        $files += Get-ChildItem -LiteralPath $SourceDirectory -Filter $pattern -File -ErrorAction SilentlyContinue
    }
    return @($files | Sort-Object FullName -Unique)
}

function Write-GrlOfflineManifest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition,
        [Parameter(Mandatory = $true)]
        [object]$SystemInfo,
        [Parameter(Mandatory = $true)]
        [object[]]$PackageStates,
        [object[]]$Features,
        [string[]]$ComponentIds
    )

    $manifest = [ordered]@{
        schemaVersion = 1
        generatedAt = (Get-Date).ToString('o')
        profileId = $ProfileDefinition.id
        profileName = $ProfileDefinition.displayName
        generatedOnOS = $SystemInfo.OSName
        generatedOnBuild = $SystemInfo.Build
        generatedOnArchitecture = $SystemInfo.Architecture
        components = @($ComponentIds)
        packages = @($PackageStates | ForEach-Object {
            [ordered]@{
                packageId = $_.PackageId
                fileName = Split-Path -Leaf $_.Path
                size = $_.Size
                sha256 = $_.Sha256
                hashPolicy = $_.HashPolicy
                signatureStatus = $_.SignatureStatus
                signerSubject = $_.SignerSubject
                verifiedAt = $_.VerifiedAt
            }
        })
        features = @($Features | ForEach-Object {
            $record = $_
            $files = @()
            if ($null -ne $record.files) {
                $files = @($record.files | ForEach-Object {
                    [ordered]@{
                        name = $_.name
                        size = $_.size
                        sha256 = $_.sha256
                    }
                })
            }
            [ordered]@{
                componentId = $record.componentId
                featureName = $record.featureName
                payloadIncluded = $record.payloadIncluded
                payloadFileCount = $record.payloadFileCount
                relativePayloadDirectory = $record.relativePayloadDirectory
                note = $record.note
                files = $files
            }
        })
    }
    $json = $manifest | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Copy-GrlReleaseFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot
    )

    $lockPath = Join-Path $RootPath 'config\release-lock.ps1'
    $GameRuntimeReleaseLock = $null
    . $lockPath
    if ($null -eq $GameRuntimeReleaseLock) {
        throw '发布清单格式无效。'
    }

    $relativeFiles = @($GameRuntimeReleaseLock.Files.Keys)
    $relativeFiles += 'config\release-lock.ps1'
    foreach ($relative in $relativeFiles | Select-Object -Unique) {
        $source = Join-Path $RootPath $relative
        $destination = Join-Path $DestinationRoot $relative
        $parent = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
}

function New-GrlOfflineBundle {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Catalog,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition,
        [Parameter(Mandatory = $true)]
        [object]$SystemInfo,
        [Parameter(Mandatory = $true)]
        [object[]]$Components,
        [string]$FeatureSource,
        [string]$OutputDirectory
    )

    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        $OutputDirectory = Join-Path $RootPath 'dist'
    }
    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    }

    $packageDirectory = Get-GrlPackageDirectory -RootPath $RootPath -ProfileDefinition $ProfileDefinition
    $packageStates = @()
    foreach ($component in $Components) {
        foreach ($package in @(Get-GrlApplicablePackages -Component $component -ProfileDefinition $ProfileDefinition)) {
            $state = Invoke-GrlSafeDownload -Package $package -DestinationDirectory $packageDirectory -AllowedDomains $Catalog.officialDomains -AllowNetwork
            $packageStates += $state
        }
    }
    Write-GrlPackageCacheManifest -Directory $packageDirectory -States $packageStates

    $featureRecords = @()
    $featurePayloadDirectory = Join-Path $packageDirectory 'feature-payloads'
    foreach ($component in @($Components | Where-Object { $_.installer.type -eq 'WindowsFeature' })) {
        $source = Resolve-GrlFeatureSource -FeatureName $component.installer.featureName -FeatureSource $FeatureSource
        $copiedNames = @()
        if (-not [string]::IsNullOrWhiteSpace($source)) {
            if (-not (Test-Path -LiteralPath $featurePayloadDirectory -PathType Container)) {
                New-Item -ItemType Directory -Path $featurePayloadDirectory -Force | Out-Null
            }
            foreach ($file in @(Get-GrlFeaturePayloadFiles -SourceDirectory $source -FeatureName $component.installer.featureName)) {
                Copy-Item -LiteralPath $file.FullName -Destination $featurePayloadDirectory -Force
                $copiedNames += $file.Name
            }
        }
        $featureFiles = @()
        foreach ($name in @($copiedNames | Select-Object -Unique)) {
            $targetPath = Join-Path $featurePayloadDirectory $name
            if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
                continue
            }
            $targetFile = Get-Item -LiteralPath $targetPath
            $featureFiles += [ordered]@{
                name = $targetFile.Name
                size = [long]$targetFile.Length
                sha256 = Get-GrlFileSha256 -Path $targetPath
            }
        }
        $copied = $featureFiles.Count
        $featureRecords += [ordered]@{
            componentId = $component.id
            featureName = $component.installer.featureName
            payloadIncluded = $copied -gt 0
            payloadFileCount = $copied
            relativePayloadDirectory = if ($copied -gt 0) { 'packages\feature-payloads' } else { $null }
            note = if ($copied -gt 0) { '离线功能载荷来自用户提供的匹配 Windows 源。' } else { '需要在目标电脑上尝试系统缓存，或提供匹配版本 Windows ISO 的 sources\sxs。' }
            files = @($featureFiles)
        }
    }

    $profileDirectory = Join-Path $RootPath $ProfileDefinition.displayName
    $manifestPath = Join-Path $profileDirectory 'offline-manifest.json'
    $manifestDirectory = Split-Path -Parent $manifestPath
    if (-not (Test-Path -LiteralPath $manifestDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $manifestDirectory -Force | Out-Null
    }
    $selectedComponentIds = @($Components | ForEach-Object { [string]$_.id })
    Write-GrlOfflineManifest -Path $manifestPath -ProfileDefinition $ProfileDefinition -SystemInfo $SystemInfo -PackageStates $packageStates -Features $featureRecords -ComponentIds $selectedComponentIds

    $stagingRoot = New-GrlTempDirectory -Purpose 'offline-bundle'
    try {
        Copy-GrlReleaseFiles -RootPath $RootPath -DestinationRoot $stagingRoot
        $manifestRelative = Join-Path $ProfileDefinition.displayName 'offline-manifest.json'
        $manifestStagePath = Join-Path $stagingRoot $manifestRelative
        $manifestStageDirectory = Split-Path -Parent $manifestStagePath
        if (-not (Test-Path -LiteralPath $manifestStageDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $manifestStageDirectory -Force | Out-Null
        }
        Copy-Item -LiteralPath $manifestPath -Destination $manifestStagePath -Force

        $targetDirectory = Join-Path (Join-Path $stagingRoot $ProfileDefinition.displayName) 'packages'
        if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $targetDirectory -Force | Out-Null
        }
        foreach ($state in $packageStates) {
            Copy-Item -LiteralPath $state.Path -Destination $targetDirectory -Force
        }
        $packageManifest = Join-Path $packageDirectory 'package-manifest.json'
        if (Test-Path -LiteralPath $packageManifest -PathType Leaf) {
            Copy-Item -LiteralPath $packageManifest -Destination $targetDirectory -Force
        }
        if (Test-Path -LiteralPath $featurePayloadDirectory -PathType Container) {
            $targetFeatureDirectory = Join-Path (Join-Path (Join-Path $stagingRoot $ProfileDefinition.displayName) 'packages') 'feature-payloads'
            if (-not (Test-Path -LiteralPath $targetFeatureDirectory -PathType Container)) {
                New-Item -ItemType Directory -Path $targetFeatureDirectory -Force | Out-Null
            }
            Get-ChildItem -LiteralPath $featurePayloadDirectory -File | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination $targetFeatureDirectory -Force
            }
        }

        Test-GrlReleaseIntegrity -RootPath $stagingRoot | Out-Null

        # 仅校验本次打包的组件，避免离线包因未选中的组件被误判为缺包。
        $bundleCatalog = [pscustomobject]@{
            schemaVersion = $Catalog.schemaVersion
            officialDomains = @($Catalog.officialDomains)
            components = @($Components)
        }
        $verification = Test-GrlOfflineBundle -OfflineRoot $stagingRoot -ProfileDefinition $ProfileDefinition -Catalog $bundleCatalog
        if (-not $verification.IsValid) {
            throw ("离线包校验失败：{0}" -f ($verification.Issues -join '；'))
        }

        $totalPackageBytes = [long]0
        foreach ($state in $packageStates) {
            if ($null -ne $state.Size) {
                $totalPackageBytes += [long]$state.Size
            }
        }
        if ($totalPackageBytes -gt 0) {
            Assert-GrlFreeSpace -Path $OutputDirectory -RequiredBytes $totalPackageBytes -Multiplier 1.2
        }

        $safeProfileName = $ProfileDefinition.id -replace '[^a-zA-Z0-9_-]', '_'
        $zipName = "GameRuntimeLibrary-$safeProfileName-offline-$(Get-Date -Format 'yyyyMMdd-HHmmss').zip"
        $zipPath = Join-Path $OutputDirectory $zipName
        $partZipPath = $zipPath + '.tmp.zip'
        if (Test-Path -LiteralPath $partZipPath) {
            Remove-Item -LiteralPath $partZipPath -Force
        }
        Compress-Archive -Path (Join-Path $stagingRoot '*') -DestinationPath $partZipPath -CompressionLevel Optimal -Force
        Move-Item -LiteralPath $partZipPath -Destination $zipPath
        return [pscustomobject]@{
            ZipPath = $zipPath
            ManifestPath = $manifestPath
            PackageCount = $packageStates.Count
            FeatureRecords = @($featureRecords)
        }
    }
    finally {
        Remove-GrlTempDirectory -Path $stagingRoot
    }
}

function Test-GrlOfflineBundle {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OfflineRoot,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition,
        [Parameter(Mandatory = $true)]
        [object]$Catalog
    )

    $issues = @()
    $manifest = $null
    $packageCount = 0
    $featureFileCount = 0

    $profileDirectory = Join-Path $OfflineRoot $ProfileDefinition.displayName
    $manifestPath = Join-Path $profileDirectory 'offline-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        $issues += "离线清单不存在：$manifestPath"
        return [pscustomobject]@{
            IsValid = $false
            Issues = @($issues)
            Manifest = $null
            PackageCount = 0
            FeatureFileCount = 0
            ComponentIds = @()
        }
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $issues += "离线清单无法解析：$manifestPath（$($_.Exception.Message)）"
        return [pscustomobject]@{
            IsValid = $false
            Issues = @($issues)
            Manifest = $null
            PackageCount = 0
            FeatureFileCount = 0
            ComponentIds = @()
        }
    }
    if ($null -eq $manifest) {
        $issues += "离线清单内容为空：$manifestPath"
        return [pscustomobject]@{
            IsValid = $false
            Issues = @($issues)
            Manifest = $null
            PackageCount = 0
            FeatureFileCount = 0
            ComponentIds = @()
        }
    }

    if ([int]$manifest.schemaVersion -ne 1) {
        $issues += "离线清单 schemaVersion 必须为 1，实际：$($manifest.schemaVersion)"
    }
    if ([string]$manifest.profileId -ne [string]$ProfileDefinition.id) {
        $issues += "离线清单平台不一致：清单为 $($manifest.profileId)，当前为 $($ProfileDefinition.id)"
    }

    $manifestComponentIds = @()
    if ($null -ne $manifest.PSObject.Properties['components']) {
        $manifestComponentIds = @($manifest.components |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { [string]$_ })
    }
    if ($manifestComponentIds.Count -gt 0 -and $null -ne $Catalog -and $null -ne $Catalog.components) {
        $catalogComponentIds = @($Catalog.components | ForEach-Object { [string]$_.id })
        foreach ($componentId in $manifestComponentIds) {
            if ($catalogComponentIds -notcontains $componentId) {
                $issues += "离线清单包含未知组件：$componentId"
            }
        }
    }

    $packageDirectory = Join-Path $profileDirectory 'packages'
    $packageDirectoryExists = Test-Path -LiteralPath $packageDirectory -PathType Container
    if (-not $packageDirectoryExists) {
        $issues += "离线安装包目录不存在：$packageDirectory"
    }

    $manifestPackages = @{}
    foreach ($record in @($manifest.packages)) {
        if ($null -eq $record) {
            continue
        }
        $packageId = [string]$record.packageId
        if ([string]::IsNullOrWhiteSpace($packageId)) {
            continue
        }
        $manifestPackages[$packageId] = $record
    }

    if ($packageDirectoryExists -and $null -ne $Catalog -and $null -ne $Catalog.components) {
        foreach ($component in @($Catalog.components)) {
            if ($manifestComponentIds.Count -gt 0 -and $manifestComponentIds -notcontains [string]$component.id) {
                continue
            }
            if (-not (Test-GrlComponentApplicable -Component $component -ProfileDefinition $ProfileDefinition)) {
                continue
            }
            foreach ($package in @(Get-GrlApplicablePackages -Component $component -ProfileDefinition $ProfileDefinition)) {
                $fileName = [string]$package.fileName
                $filePath = Join-Path $packageDirectory $fileName
                if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
                    $issues += "缺少安装包文件：$fileName"
                    continue
                }
                $packageCount++
                $packageFile = Get-Item -LiteralPath $filePath
                $record = $manifestPackages[[string]$package.id]
                if ($null -eq $record) {
                    $issues += "离线清单缺少安装包记录：$($package.id)（$fileName）"
                    continue
                }
                if ([long]$record.size -ne [long]$packageFile.Length) {
                    $issues += "安装包大小不匹配：$fileName，清单 $($record.size) 字节，实际 $($packageFile.Length) 字节"
                }
                $actualHash = $null
                try {
                    $actualHash = Get-GrlFileSha256 -Path $filePath
                }
                catch {
                    $issues += "无法计算安装包哈希：$fileName（$($_.Exception.Message)）"
                    continue
                }
                $manifestHash = ([string]$record.sha256).ToUpperInvariant()
                if ($actualHash -ne $manifestHash) {
                    $issues += "安装包哈希不匹配：$fileName，清单 $manifestHash，实际 $actualHash"
                }
                if ([string]$package.hashPolicy -eq 'Fixed') {
                    $catalogHash = ([string]$package.sha256).ToUpperInvariant()
                    if ($actualHash -ne $catalogHash) {
                        $issues += "安装包与目录固定哈希不匹配：$fileName，目录 $catalogHash，实际 $actualHash"
                    }
                }
            }
        }
    }

    $registeredFiles = @{}
    foreach ($feature in @($manifest.features)) {
        if ($null -eq $feature) {
            continue
        }
        foreach ($fileRecord in @($feature.files)) {
            if ($null -eq $fileRecord) {
                continue
            }
            $name = [string]$fileRecord.name
            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }
            $registeredFiles[$name] = $fileRecord
        }
    }

    $featureDirectory = Join-Path $packageDirectory 'feature-payloads'
    if (Test-Path -LiteralPath $featureDirectory -PathType Container) {
        $featureDirectoryFull = (Get-Item -LiteralPath $featureDirectory).FullName
        foreach ($featureFile in @(Get-ChildItem -LiteralPath $featureDirectory -File -Recurse)) {
            $featureFileCount++
            $relative = $featureFile.FullName.Substring($featureDirectoryFull.Length)
            $relative = $relative.TrimStart([char]'\', [char]'/')
            $relative = $relative -replace '/', '\'
            $record = $registeredFiles[$relative]
            if ($null -eq $record) {
                $issues += "未登记的功能载荷文件：$relative"
                continue
            }
            if ([long]$record.size -ne [long]$featureFile.Length) {
                $issues += "功能载荷大小不匹配：$relative，清单 $($record.size) 字节，实际 $($featureFile.Length) 字节"
            }
            $actualHash = $null
            try {
                $actualHash = Get-GrlFileSha256 -Path $featureFile.FullName
            }
            catch {
                $issues += "无法计算功能载荷哈希：$relative（$($_.Exception.Message)）"
                continue
            }
            $manifestHash = ([string]$record.sha256).ToUpperInvariant()
            if ($actualHash -ne $manifestHash) {
                $issues += "功能载荷哈希不匹配：$relative，清单 $manifestHash，实际 $actualHash"
            }
        }
    }

    foreach ($name in @($registeredFiles.Keys)) {
        $registeredPath = Join-Path $featureDirectory $name
        if (-not (Test-Path -LiteralPath $registeredPath -PathType Leaf)) {
            $issues += "功能载荷文件缺失：$name"
        }
    }

    return [pscustomobject]@{
        IsValid = ($issues.Count -eq 0)
        Issues = @($issues)
        Manifest = $manifest
        PackageCount = $packageCount
        FeatureFileCount = $featureFileCount
        ComponentIds = @($manifestComponentIds)
    }
}

function Get-GrlOfflineManifest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OfflineRoot,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition
    )
    $path = Join-Path (Join-Path $OfflineRoot $ProfileDefinition.displayName) 'offline-manifest.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "离线清单不存在：$path"
    }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Resolve-GrlOfflinePackageDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OfflineRoot,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition
    )
    $path = Get-GrlPackageDirectory -RootPath $OfflineRoot -ProfileDefinition $ProfileDefinition
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "离线安装包目录不存在：$path"
    }
    return $path
}

Export-ModuleMember -Function Get-GrlFeaturePayloadFiles, Write-GrlOfflineManifest, Copy-GrlReleaseFiles, New-GrlOfflineBundle, Test-GrlOfflineBundle, Get-GrlOfflineManifest, Resolve-GrlOfflinePackageDirectory
