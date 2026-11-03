$ErrorActionPreference = 'Stop'

function Test-GrlOfficialUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [Parameter(Mandatory = $true)]
        [string[]]$AllowedDomains
    )

    $uri = $null
    if (-not [uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) {
        return $false
    }
    if ($uri.Scheme -ne 'https' -or -not [string]::IsNullOrWhiteSpace($uri.UserInfo)) {
        return $false
    }
    $hostName = $uri.Host.TrimEnd('.').ToLowerInvariant()
    foreach ($domain in $AllowedDomains) {
        $normalized = $domain.Trim().TrimStart('.').ToLowerInvariant()
        if ($hostName -eq $normalized -or $hostName.EndsWith('.' + $normalized, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

function Import-GrlCatalog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    $path = Join-Path $RootPath 'config\catalog.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw '组件目录 config\catalog.json 不存在。'
    }
    $catalog = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-GrlCatalog -Catalog $catalog
    return $catalog
}

function Test-GrlIntegerValue {
    param(
        [object]$Value,
        [switch]$AllowZero
    )

    if ($null -eq $Value) {
        return $false
    }
    if ($Value -is [bool] -or $Value -is [string]) {
        return $false
    }
    $number = 0.0
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte] -or $Value -is [uint32] -or $Value -is [uint64]) {
        $number = [double]$Value
    }
    elseif ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        $number = [double]$Value
        if ([math]::Floor($number) -ne $number) {
            return $false
        }
    }
    else {
        return $false
    }
    if ($AllowZero) {
        return ($number -ge 0)
    }
    return ($number -gt 0)
}

function Assert-GrlCatalog {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Catalog
    )

    if ($Catalog.schemaVersion -ne 1) {
        throw '组件目录 schemaVersion 必须为 1。'
    }
    if ($null -eq $Catalog.officialDomains -or $Catalog.officialDomains.Count -eq 0) {
        throw '组件目录缺少 officialDomains。'
    }
    foreach ($domain in @($Catalog.officialDomains)) {
        if ([string]::IsNullOrWhiteSpace([string]$domain)) {
            throw '组件目录的 officialDomains 包含空值。'
        }
        $domainText = [string]$domain
        if ($domainText -eq '*' -or $domainText.IndexOf('.') -lt 0 -or $domainText -notmatch '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$') {
            throw "组件目录的 officialDomains 域名格式无效：$domainText"
        }
    }
    if ($null -eq $Catalog.components -or $Catalog.components.Count -eq 0) {
        throw '组件目录缺少 components。'
    }

    $componentIds = @{}
    $packageIds = @{}
    $packageUrls = @{}
    foreach ($component in $Catalog.components) {
        if ([string]::IsNullOrWhiteSpace($component.id)) {
            throw '组件目录包含空组件 ID。'
        }
        if ($componentIds.ContainsKey($component.id)) {
            throw "组件 ID 重复：$($component.id)"
        }
        $componentIds[$component.id] = $true
        if ($component.tier -notin @('Core', 'Legacy')) {
            throw "组件 $($component.id) 的 tier 无效。"
        }
        if (-not (Test-GrlIntegerValue -Value $component.order -AllowZero)) {
            throw "组件 $($component.id) 的 order 必须是非负整数。"
        }
        if ($null -ne $component.applicability -and $null -ne $component.applicability.architectures) {
            foreach ($architecture in @($component.applicability.architectures)) {
                if ([string]$architecture -notin @('x86', 'x64')) {
                    throw "组件 $($component.id) 的 applicability.architectures 只能包含 x86 或 x64。"
                }
            }
        }
        if ($null -eq $component.installer) {
            throw "组件 $($component.id) 缺少 installer。"
        }
        if ($component.installer.type -notin @('Exe', 'Msi', 'SelfExtractingBundle', 'ArchiveBundle', 'WindowsFeature')) {
            throw "组件 $($component.id) 的安装类型无效。"
        }
        if ($component.installer.type -eq 'WindowsFeature' -and [string]$component.installer.featureName -notin @('NetFx3', 'DirectPlay')) {
            throw "功能组件 $($component.id) 的 featureName 只能是 NetFx3 或 DirectPlay。"
        }
        if ($component.installer.type -in @('SelfExtractingBundle', 'ArchiveBundle')) {
            $innerFile = [string]$component.installer.innerFile
            if ([string]::IsNullOrWhiteSpace($innerFile) -or [System.IO.Path]::GetFileName($innerFile) -ne $innerFile -or $innerFile -notmatch '^[A-Za-z0-9._-]+$') {
                throw "组件 $($component.id) 的内部安装器文件名必须是纯文件名。"
            }
            $innerSha256 = [string]$component.installer.innerSha256
            if ($innerSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or $innerSha256 -match '^0+$') {
                throw "组件 $($component.id) 缺少有效的内部安装器 SHA-256。"
            }
            if ([string]::IsNullOrWhiteSpace([string]$component.installer.innerPublisherContains)) {
                throw "组件 $($component.id) 缺少内部安装器签名发布者。"
            }
        }
        if ($component.installer.type -ne 'WindowsFeature' -and ($null -eq $component.packages -or $component.packages.Count -eq 0)) {
            throw "文件组件 $($component.id) 缺少 packages。"
        }

        foreach ($package in @($component.packages)) {
            if ($packageIds.ContainsKey($package.id)) {
                throw "安装包 ID 重复：$($package.id)"
            }
            $packageIds[$package.id] = $true
            if ($package.architecture -notin @('x86', 'x64', 'any')) {
                throw "安装包 $($package.id) 的架构无效。"
            }
            if (-not (Test-GrlOfficialUrl -Url $package.url -AllowedDomains $Catalog.officialDomains)) {
                throw "安装包 $($package.id) 使用了非官方地址：$($package.url)"
            }
            $urlKey = ([string]$package.url).ToLowerInvariant()
            if ($packageUrls.ContainsKey($urlKey)) {
                throw "安装包 $($package.id) 的下载地址与其他安装包重复：$($package.url)"
            }
            $packageUrls[$urlKey] = $true
            if ($package.hashPolicy -notin @('Fixed', 'SignedLatest')) {
                throw "安装包 $($package.id) 的 hashPolicy 无效。"
            }
            if ($null -eq $package.signature) {
                throw "安装包 $($package.id) 缺少 signature。"
            }
            if ($package.signature.required -isnot [bool]) {
                throw "安装包 $($package.id) 的 signature.required 必须是布尔值。"
            }
            if ([bool]$package.signature.required -and [string]::IsNullOrWhiteSpace([string]$package.signature.publisherContains)) {
                throw "安装包 $($package.id) 的 signature.publisherContains 不能为空。"
            }

            $fileName = [string]$package.fileName
            if ([string]::IsNullOrWhiteSpace($fileName)) {
                throw "安装包 $($package.id) 缺少 fileName。"
            }
            if ([System.IO.Path]::GetFileName($fileName) -ne $fileName -or $fileName -notmatch '^[A-Za-z0-9._-]+$') {
                throw "安装包 $($package.id) 的 fileName 必须是纯文件名。"
            }
            $extension = [System.IO.Path]::GetExtension($fileName).ToLowerInvariant()
            if ($extension -notin @('.exe', '.msi', '.zip')) {
                throw "安装包 $($package.id) 的 fileName 扩展名必须是 .exe、.msi 或 .zip。"
            }

            if ($package.hashPolicy -eq 'Fixed') {
                $sha256 = [string]$package.sha256
                if ($sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
                    throw "安装包 $($package.id) 缺少有效的 SHA-256。"
                }
                if ($sha256 -match '^0+$') {
                    throw "安装包 $($package.id) 的 SHA-256 为占位值。"
                }
                if (-not (Test-GrlIntegerValue -Value $package.size)) {
                    throw "安装包 $($package.id) 的 size 必须是大于 0 的整数。"
                }
            }
            if ($package.hashPolicy -eq 'SignedLatest') {
                if ($null -eq $package.minimumBytes -or $null -eq $package.maximumBytes) {
                    throw "安装包 $($package.id) 的 SignedLatest 策略必须同时提供 minimumBytes 和 maximumBytes。"
                }
                if (-not (Test-GrlIntegerValue -Value $package.minimumBytes)) {
                    throw "安装包 $($package.id) 的 minimumBytes 必须是大于 0 的整数。"
                }
                if (-not (Test-GrlIntegerValue -Value $package.maximumBytes)) {
                    throw "安装包 $($package.id) 的 maximumBytes 必须是大于 0 的整数。"
                }
                if ([double]$package.minimumBytes -gt [double]$package.maximumBytes) {
                    throw "安装包 $($package.id) 的 minimumBytes 不能大于 maximumBytes。"
                }
                if (-not [bool]$package.signature.required) {
                    throw "安装包 $($package.id) 的 SignedLatest 策略要求 signature.required 为 true。"
                }
            }
        }
    }
}

function Import-GrlProfiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    $path = Join-Path $RootPath 'config\profiles.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw '平台配置 config\profiles.json 不存在。'
    }
    $profiles = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($profiles.schemaVersion -ne 1 -or $null -eq $profiles.profiles -or $profiles.profiles.Count -eq 0) {
        throw '平台配置格式无效。'
    }
    $ids = @{}
    foreach ($profileEntry in $profiles.profiles) {
        if ($ids.ContainsKey($profileEntry.id)) {
            throw "平台 ID 重复：$($profileEntry.id)"
        }
        $ids[$profileEntry.id] = $true
        if ($profileEntry.architecture -notin @('x86', 'x64')) {
            throw "平台 $($profileEntry.id) 的架构无效。"
        }
    }
    return $profiles
}

function Import-GrlDllMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    $path = Join-Path $RootPath 'config\dll-map.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'DLL 清单 config\dll-map.json 不存在。'
    }
    $map = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($map.schemaVersion -ne 1 -or $null -eq $map.items -or $map.items.Count -eq 0) {
        throw 'DLL 清单格式无效。'
    }

    $componentIds = @{}
    foreach ($item in $map.items) {
        if ([string]::IsNullOrWhiteSpace([string]$item.componentId)) {
            throw 'DLL 清单包含空组件 ID。'
        }
        if ($componentIds.ContainsKey([string]$item.componentId)) {
            throw "DLL 清单组件重复：$($item.componentId)"
        }
        $componentIds[[string]$item.componentId] = $true
        if ($null -eq $item.files -or $item.files.Count -eq 0) {
            throw "DLL 清单组件缺少文件：$($item.componentId)"
        }
        foreach ($file in @($item.files)) {
            if ([string]::IsNullOrWhiteSpace([string]$file) -or [System.IO.Path]::GetFileName([string]$file) -ne [string]$file) {
                throw "DLL 清单包含无效文件名：$file"
            }
        }
    }
    return $map
}

function Get-GrlProfileDefinition {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [string]$ProfileId
    )

    $profiles = Import-GrlProfiles -RootPath $RootPath
    $profileDefinition = $profiles.profiles | Where-Object { $_.id -eq $ProfileId } | Select-Object -First 1
    if ($null -eq $profileDefinition) {
        throw "未找到平台配置：$ProfileId"
    }
    return $profileDefinition
}

function Get-GrlComponentById {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Catalog,
        [Parameter(Mandatory = $true)]
        [string]$ComponentId
    )

    $component = $Catalog.components | Where-Object { $_.id -eq $ComponentId } | Select-Object -First 1
    if ($null -eq $component) {
        throw "未知组件 ID：$ComponentId"
    }
    return $component
}

function Test-GrlComponentApplicable {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Component,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition
    )

    if ($null -eq $Component.applicability -or $null -eq $Component.applicability.architectures) {
        return $true
    }
    return $ProfileDefinition.architecture -in $Component.applicability.architectures
}

function Get-GrlSelectedComponents {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Catalog,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition,
        [string[]]$ComponentId
    )

    $requested = @()
    if ($null -ne $ComponentId) {
        $requested = @($ComponentId | ForEach-Object {
            ([string]$_).Split(',') | ForEach-Object { $_.Trim() }
        } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    }

    $components = @()
    if ($requested.Count -gt 0) {
        foreach ($id in $requested) {
            $component = Get-GrlComponentById -Catalog $Catalog -ComponentId $id
            if (-not (Test-GrlComponentApplicable -Component $component -ProfileDefinition $ProfileDefinition)) {
                throw "组件 $id 不适用于平台 $($ProfileDefinition.id)。"
            }
            $components += $component
        }
    }
    else {
        foreach ($component in $Catalog.components) {
            if (Test-GrlComponentApplicable -Component $component -ProfileDefinition $ProfileDefinition) {
                $components += $component
            }
        }
    }
    return @($components | Sort-Object -Property order)
}

function Get-GrlApplicablePackages {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Component,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition
    )

    $architectures = @($ProfileDefinition.architectures)
    return @($Component.packages | Where-Object { $_.architecture -in $architectures } | Sort-Object -Property architecture)
}

function Get-GrlComponentIds {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Catalog
    )
    return @($Catalog.components | ForEach-Object { $_.id })
}

function Test-GrlReleaseIntegrity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [switch]$RequireProduction
    )

    $lockPath = Join-Path $RootPath 'config\release-lock.ps1'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        throw '发布清单不存在。'
    }
    if ($RequireProduction) {
        $signature = Get-AuthenticodeSignature -LiteralPath $lockPath
        if ($signature.Status -ne 'Valid') {
            throw "发布清单签名无效：$($signature.Status)"
        }
    }

    $GameRuntimeReleaseLock = $null
    . $lockPath
    if ($null -eq $GameRuntimeReleaseLock) {
        throw '发布清单格式无效。'
    }
    if ($RequireProduction -and $GameRuntimeReleaseLock.ReleaseKind -ne 'Production') {
        throw '当前不是正式发布构建。'
    }

    if ($GameRuntimeReleaseLock.ReleaseKind -eq 'Production') {
        $expectedThumbprint = [string]$GameRuntimeReleaseLock.CertificateThumbprint
        if ([string]::IsNullOrWhiteSpace($expectedThumbprint)) {
            throw '正式发布清单缺少证书指纹。'
        }
        $lockSignature = Get-AuthenticodeSignature -LiteralPath $lockPath
        if ($lockSignature.Status -ne 'Valid' -or $null -eq $lockSignature.SignerCertificate -or $lockSignature.SignerCertificate.Thumbprint -ne $expectedThumbprint) {
            throw "正式发布清单签名无效：$($lockSignature.Status)"
        }
        foreach ($item in $GameRuntimeReleaseLock.Files.GetEnumerator()) {
            if ($item.Key -match '\.(ps1|psm1)$') {
                $scriptSignature = Get-AuthenticodeSignature -LiteralPath (Join-Path $RootPath $item.Key)
                if ($scriptSignature.Status -ne 'Valid' -or $null -eq $scriptSignature.SignerCertificate -or $scriptSignature.SignerCertificate.Thumbprint -ne $expectedThumbprint) {
                    throw "正式版脚本签名无效：$($item.Key)，状态 $($scriptSignature.Status)"
                }
            }
        }
    }

    $failures = @()
    foreach ($item in $GameRuntimeReleaseLock.Files.GetEnumerator()) {
        $path = Join-Path $RootPath $item.Key
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $failures += "缺失：$($item.Key)"
            continue
        }
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($hash -ne $item.Value) {
            $failures += "哈希不匹配：$($item.Key)"
        }
    }
    if ($failures.Count -gt 0) {
        throw ($failures -join '；')
    }
    return $GameRuntimeReleaseLock
}

Export-ModuleMember -Function Test-GrlOfficialUrl, Import-GrlCatalog, Assert-GrlCatalog, Import-GrlProfiles, Import-GrlDllMap, Get-GrlProfileDefinition, Get-GrlComponentById, Test-GrlComponentApplicable, Get-GrlSelectedComponents, Get-GrlApplicablePackages, Get-GrlComponentIds, Test-GrlReleaseIntegrity
