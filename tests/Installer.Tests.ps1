$script:RootPath = Split-Path $PSScriptRoot -Parent
Import-Module -Name (Join-Path $script:RootPath 'src\GameRuntimeLibrary.psm1') -Force

function New-OfflineTestFixture {
    param(
        [switch]$WithoutManifest,
        [switch]$Partial
    )

    $temp = New-GrlTempDirectory -Purpose 'test-offline-bundle'
    $bundleRoot = Join-Path $temp 'bundle'
    $profileDefinition = [pscustomobject]@{
        id = 'Windows10-x64'
        displayName = 'Windows 10 x64'
        architecture = 'x64'
        architectures = @('x86', 'x64', 'any')
    }

    $profileDirectory = Join-Path $bundleRoot $profileDefinition.displayName
    $packageDirectory = Join-Path $profileDirectory 'packages'
    $payloadDirectory = Join-Path $packageDirectory 'feature-payloads'
    New-Item -ItemType Directory -Path $payloadDirectory -Force | Out-Null

    $packagePath = Join-Path $packageDirectory 'synthetic-runtime.exe'
    [System.IO.File]::WriteAllText($packagePath, 'synthetic package payload')
    $packageFile = Get-Item -LiteralPath $packagePath
    $packageHash = Get-GrlFileSha256 -Path $packagePath

    $payloadName = 'Microsoft-Windows-NetFx3-OnDemand-Package-test.cab'
    $payloadPath = Join-Path $payloadDirectory $payloadName
    [System.IO.File]::WriteAllText($payloadPath, 'synthetic feature payload')
    $payloadFile = Get-Item -LiteralPath $payloadPath
    $payloadHash = Get-GrlFileSha256 -Path $payloadPath

    $component = [pscustomobject]@{
        id = 'synthetic-runtime'
        displayName = 'Synthetic Runtime'
        tier = 'Core'
        order = 1
        applicability = [pscustomobject]@{ architectures = @('x86', 'x64') }
        installer = [pscustomobject]@{ type = 'WindowsFeature'; featureName = 'NetFx3' }
        detection = $null
        packages = @(
            [pscustomobject]@{
                id = 'synthetic_runtime_any'
                architecture = 'any'
                url = 'https://download.microsoft.com/synthetic-runtime.exe'
                fileName = 'synthetic-runtime.exe'
                size = $packageFile.Length
                sha256 = $packageHash
                hashPolicy = 'Fixed'
                signature = [pscustomobject]@{ required = $false; publisherContains = '' }
            }
        )
    }

    $catalog = [pscustomobject]@{
        schemaVersion = 1
        officialDomains = @('microsoft.com')
        components = @($component)
    }

    if ($Partial) {
        # 清单只声明 synthetic-runtime，另一个组件及其安装包不在离线包内。
        $extraComponent = [pscustomobject]@{
            id = 'synthetic-extra'
            displayName = 'Synthetic Extra'
            tier = 'Legacy'
            order = 2
            applicability = [pscustomobject]@{ architectures = @('x86', 'x64') }
            installer = [pscustomobject]@{ type = 'Exe'; arguments = @('/quiet') }
            detection = $null
            packages = @(
                [pscustomobject]@{
                    id = 'synthetic_extra_any'
                    architecture = 'any'
                    url = 'https://download.microsoft.com/synthetic-extra.exe'
                    fileName = 'synthetic-extra.exe'
                    size = 1024
                    sha256 = ('D' * 64)
                    hashPolicy = 'Fixed'
                    signature = [pscustomobject]@{ required = $false; publisherContains = '' }
                }
            )
        }
        $catalog.components = @($component, $extraComponent)
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        generatedAt = (Get-Date).ToString('o')
        profileId = $profileDefinition.id
        profileName = $profileDefinition.displayName
        packages = @(
            [ordered]@{
                packageId = 'synthetic_runtime_any'
                fileName = 'synthetic-runtime.exe'
                size = [long]$packageFile.Length
                sha256 = $packageHash
                hashPolicy = 'Fixed'
                signatureStatus = 'NotRequired'
                signerSubject = ''
                verifiedAt = (Get-Date).ToString('o')
            }
        )
        features = @(
            [ordered]@{
                componentId = 'synthetic-runtime'
                featureName = 'NetFx3'
                payloadIncluded = $true
                payloadFileCount = 1
                relativePayloadDirectory = 'packages\feature-payloads'
                note = '测试功能载荷'
                files = @(
                    [ordered]@{
                        name = $payloadName
                        size = [long]$payloadFile.Length
                        sha256 = $payloadHash
                    }
                )
            }
        )
    }

    if ($Partial) {
        $manifest.components = @('synthetic-runtime')
    }

    if (-not $WithoutManifest) {
        $manifestPath = Join-Path $profileDirectory 'offline-manifest.json'
        $json = $manifest | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($manifestPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    }

    return [pscustomobject]@{
        Temp = $temp
        BundleRoot = $bundleRoot
        Profile = $profileDefinition
        Catalog = $catalog
        PackagePath = $packagePath
        PayloadDirectory = $payloadDirectory
        PayloadName = $payloadName
    }
}

Describe '磁盘空间检查' {
    It '所需字节为 1 时通过检查' {
        $temp = New-GrlTempDirectory -Purpose 'test-free-space'
        try {
            { Assert-GrlFreeSpace -Path $temp -RequiredBytes 1 } | Should Not Throw
        }
        finally {
            Remove-GrlTempDirectory -Path $temp
        }
    }

    It '所需空间超大时抛出错误' {
        { Assert-GrlFreeSpace -Path $env:TEMP -RequiredBytes ([long]::MaxValue) } | Should Throw
    }

    It '所需字节为零时直接返回' {
        { Assert-GrlFreeSpace -Path $env:TEMP -RequiredBytes 0 } | Should Not Throw
    }
}

Describe '修复模式计划' {
    It '普通安装跳过已安装包，修复模式重新列入并标记 Repair' {
        $temp = New-GrlTempDirectory -Purpose 'test-repair-plan'
        try {
            $present = Join-Path $temp 'present.dll'
            [System.IO.File]::WriteAllText($present, 'present')
            $profileDefinition = [pscustomobject]@{
                id = 'Windows10-x64'
                displayName = 'Windows 10 x64'
                architecture = 'x64'
                architectures = @('x86', 'x64', 'any')
            }
            $component = [pscustomobject]@{
                id = 'synthetic-repair'
                displayName = 'Synthetic Repair'
                tier = 'Core'
                order = 999
                applicability = [pscustomobject]@{ architectures = @('x86', 'x64') }
                installer = [pscustomobject]@{ type = 'Exe'; arguments = @('/quiet') }
                detection = [pscustomobject]@{ type = 'FileAny'; files = @((Join-Path $temp 'missing.dll')) }
                packages = @(
                    [pscustomobject]@{
                        id = 'synthetic_repair_any'
                        architecture = 'any'
                        fileName = 'repair.exe'
                        size = 1
                        hashPolicy = 'Fixed'
                        sha256 = ('C' * 64)
                        signature = [pscustomobject]@{ required = $false; publisherContains = '' }
                        detection = [pscustomobject]@{ type = 'FileAny'; files = @($present) }
                    }
                )
            }
            $catalog = [pscustomobject]@{ officialDomains = @('microsoft.com') }

            $normal = New-GrlInstallationPlan -Catalog $catalog -ProfileDefinition $profileDefinition -Components @($component) -PackageDirectory $temp -AllowNetwork $true -PreviewOnly
            $repair = New-GrlInstallationPlan -Catalog $catalog -ProfileDefinition $profileDefinition -Components @($component) -PackageDirectory $temp -AllowNetwork $true -PreviewOnly -RepairOnly

            $normal.Entries[0].Skip | Should Be $false
            $normal.Entries[0].Packages.Count | Should Be 1
            $normal.Entries[0].Packages[0].Skip | Should Be $true
            $normal.Entries[0].Packages[0].Repair | Should Be $false

            $repair.Entries[0].Skip | Should Be $false
            $repair.Entries[0].Packages.Count | Should Be 1
            $repair.Entries[0].Packages[0].Skip | Should Be $false
            $repair.Entries[0].Packages[0].Repair | Should Be $true
        }
        finally {
            Remove-GrlTempDirectory -Path $temp
        }
    }
}

Describe '离线包校验' {
    It '正常离线包校验通过' {
        $fixture = New-OfflineTestFixture
        try {
            $result = Test-GrlOfflineBundle -OfflineRoot $fixture.BundleRoot -ProfileDefinition $fixture.Profile -Catalog $fixture.Catalog
            $result.IsValid | Should Be $true
            $result.PackageCount | Should Be 1
            $result.FeatureFileCount | Should Be 1
            @($result.Issues).Count | Should Be 0
        }
        finally {
            Remove-GrlTempDirectory -Path $fixture.Temp
        }
    }

    It '部分离线包只校验清单声明的组件' {
        $fixture = New-OfflineTestFixture -Partial
        try {
            $result = Test-GrlOfflineBundle -OfflineRoot $fixture.BundleRoot -ProfileDefinition $fixture.Profile -Catalog $fixture.Catalog
            $result.IsValid | Should Be $true
            $result.PackageCount | Should Be 1
            @($result.ComponentIds).Count | Should Be 1
            ($result.ComponentIds -contains 'synthetic-runtime') | Should Be $true
            ($result.ComponentIds -contains 'synthetic-extra') | Should Be $false
        }
        finally {
            Remove-GrlTempDirectory -Path $fixture.Temp
        }
    }

    It '安装包被篡改时校验失败并报告大小或哈希问题' {
        $fixture = New-OfflineTestFixture
        try {
            [System.IO.File]::AppendAllText($fixture.PackagePath, 'tampered')
            $result = Test-GrlOfflineBundle -OfflineRoot $fixture.BundleRoot -ProfileDefinition $fixture.Profile -Catalog $fixture.Catalog
            $result.IsValid | Should Be $false
            ($result.Issues -join '；') | Should Match '大小|哈希'
        }
        finally {
            Remove-GrlTempDirectory -Path $fixture.Temp
        }
    }

    It '安装包被删除时校验失败' {
        $fixture = New-OfflineTestFixture
        try {
            Remove-Item -LiteralPath $fixture.PackagePath -Force
            $result = Test-GrlOfflineBundle -OfflineRoot $fixture.BundleRoot -ProfileDefinition $fixture.Profile -Catalog $fixture.Catalog
            $result.IsValid | Should Be $false
            ($result.Issues -join '；') | Should Match '缺少安装包'
        }
        finally {
            Remove-GrlTempDirectory -Path $fixture.Temp
        }
    }

    It '功能载荷哈希不符时校验失败' {
        $fixture = New-OfflineTestFixture
        try {
            $payloadPath = Join-Path $fixture.PayloadDirectory $fixture.PayloadName
            [System.IO.File]::WriteAllText($payloadPath, 'tampered feature payload')
            $result = Test-GrlOfflineBundle -OfflineRoot $fixture.BundleRoot -ProfileDefinition $fixture.Profile -Catalog $fixture.Catalog
            $result.IsValid | Should Be $false
            ($result.Issues -join '；') | Should Match '功能载荷'
        }
        finally {
            Remove-GrlTempDirectory -Path $fixture.Temp
        }
    }

    It '出现未登记的功能载荷文件时校验失败' {
        $fixture = New-OfflineTestFixture
        try {
            $extra = Join-Path $fixture.PayloadDirectory 'extra-payload.cab'
            [System.IO.File]::WriteAllText($extra, 'extra payload')
            $result = Test-GrlOfflineBundle -OfflineRoot $fixture.BundleRoot -ProfileDefinition $fixture.Profile -Catalog $fixture.Catalog
            $result.IsValid | Should Be $false
            ($result.Issues -join '；') | Should Match '未登记'
        }
        finally {
            Remove-GrlTempDirectory -Path $fixture.Temp
        }
    }

    It '离线清单缺失时校验失败且不抛异常' {
        $fixture = New-OfflineTestFixture -WithoutManifest
        try {
            $result = Test-GrlOfflineBundle -OfflineRoot $fixture.BundleRoot -ProfileDefinition $fixture.Profile -Catalog $fixture.Catalog
            $result.IsValid | Should Be $false
            @($result.Issues).Count | Should BeGreaterThan 0
            ($result.Issues -join '；') | Should Match '清单不存在'
        }
        finally {
            Remove-GrlTempDirectory -Path $fixture.Temp
        }
    }
}

Describe '安装程序超时' {
    It '超时后终止安装程序并抛出错误' {
        $powershellPath = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
        {
            Invoke-GrlProcessWithRetry -FilePath $powershellPath -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 5') -MaximumAttempts 1 -TimeoutSeconds 1
        } | Should Throw
    }
}
