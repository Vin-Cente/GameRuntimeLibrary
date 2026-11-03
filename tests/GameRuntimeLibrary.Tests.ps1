$script:RootPath = Split-Path $PSScriptRoot -Parent
Import-Module -Name (Join-Path $script:RootPath 'src\GameRuntimeLibrary.psm1') -Force
Import-Module -Name (Join-Path $script:RootPath 'src\GameRuntimeLibrary.Bootstrap.psm1') -Force

Describe 'GameRuntimeLibrary 目录' {
    It '目录包含全部默认组件' {
        $catalog = Import-GrlCatalog -RootPath $script:RootPath
        $catalog.components.Count | Should Be 14
        (@(Get-GrlComponentIds -Catalog $catalog) -contains 'dotnet35') | Should Be $true
        (@(Get-GrlComponentIds -Catalog $catalog) -contains 'directplay') | Should Be $true
    }

    It '固定哈希算法均为有效 SHA-256' {
        $catalog = Import-GrlCatalog -RootPath $script:RootPath
        foreach ($component in $catalog.components) {
            foreach ($package in @($component.packages)) {
                if ($package.hashPolicy -eq 'Fixed') {
                    $package.sha256 | Should Match '^[A-F0-9]{64}$'
                    $package.size | Should BeGreaterThan 0
                }
            }
        }
    }

    It 'DLL 清单覆盖全部默认组件' {
        $catalog = Import-GrlCatalog -RootPath $script:RootPath
        $dllMap = Import-GrlDllMap -RootPath $script:RootPath
        $mappedIds = @($dllMap.items | ForEach-Object { $_.componentId })
        foreach ($component in $catalog.components) {
            ($mappedIds -contains $component.id) | Should Be $true
        }
    }

    It '所有下载地址属于官方白名单' {
        $catalog = Import-GrlCatalog -RootPath $script:RootPath
        foreach ($component in $catalog.components) {
            foreach ($package in @($component.packages)) {
                Test-GrlOfficialUrl -Url $package.url -AllowedDomains $catalog.officialDomains | Should Be $true
            }
        }
    }

    It '拒绝非官方 HTTPS 地址' {
        Test-GrlOfficialUrl -Url 'https://evil.example.com/file.exe' -AllowedDomains @('microsoft.com') | Should Be $false
        Test-GrlOfficialUrl -Url 'http://download.microsoft.com/file.exe' -AllowedDomains @('microsoft.com') | Should Be $false
        Test-GrlOfficialUrl -Url 'https://download.microsoft.com.evil.example/file.exe' -AllowedDomains @('microsoft.com') | Should Be $false
    }
}

Describe '平台与组件选择' {
    It '自动识别 Windows 10 x64' {
        $system = [pscustomobject]@{ OSName = 'Windows 10'; Architecture = 'x64'; Build = 19045; Caption = 'Windows 10'; IsAdministrator = $false; PendingReboot = $false }
        Resolve-GrlProfile -RequestedProfile Auto -SystemInfo $system | Should Be 'Windows10-x64'
    }

    It 'Windows 10 x64 同时选择 x86 和 x64 VC++ 包' {
        $catalog = Import-GrlCatalog -RootPath $script:RootPath
        $profileDefinition = Get-GrlProfileDefinition -RootPath $script:RootPath -ProfileId 'Windows10-x64'
        $component = Get-GrlComponentById -Catalog $catalog -ComponentId 'vcredist2015-2022'
        $architectures = @(Get-GrlApplicablePackages -Component $component -ProfileDefinition $profileDefinition | ForEach-Object { $_.architecture })
        ($architectures -contains 'x86') | Should Be $true
        ($architectures -contains 'x64') | Should Be $true
    }

    It 'Windows 10 x86 不选择 x64 包' {
        $catalog = Import-GrlCatalog -RootPath $script:RootPath
        $profileDefinition = Get-GrlProfileDefinition -RootPath $script:RootPath -ProfileId 'Windows10-x86'
        $components = @(Get-GrlSelectedComponents -Catalog $catalog -ProfileDefinition $profileDefinition)
        foreach ($component in $components) {
            @(Get-GrlApplicablePackages -Component $component -ProfileDefinition $profileDefinition | Where-Object { $_.architecture -eq 'x64' }).Count | Should Be 0
        }
    }

    It '命令行逗号分隔组件 ID 可正确拆分' {
        $catalog = Import-GrlCatalog -RootPath $script:RootPath
        $profileDefinition = Get-GrlProfileDefinition -RootPath $script:RootPath -ProfileId 'Windows10-x64'
        $components = @(Get-GrlSelectedComponents -Catalog $catalog -ProfileDefinition $profileDefinition -ComponentId 'dotnet481,directx9')
        $components.Count | Should Be 2
        $components[0].id | Should Be 'dotnet481'
        $components[1].id | Should Be 'directx9'
    }

    It '错误平台需要显式允许' {
        $system = [pscustomobject]@{ OSName = 'Windows 10'; Architecture = 'x64'; Build = 19045; Caption = 'Windows 10'; IsAdministrator = $false; PendingReboot = $false }
        $profileDefinition = [pscustomobject]@{ id = 'Windows11-x64'; displayName = 'Windows 11 x64'; osName = 'Windows 11'; architecture = 'x64'; minimumBuild = 22000; recommendedBuild = 22000; architectures = @('x86', 'x64', 'any') }
        (Assert-GrlPlatformCompatibility -SystemInfo $system -ProfileDefinition $profileDefinition).IsCompatible | Should Be $false
        (Assert-GrlPlatformCompatibility -SystemInfo $system -ProfileDefinition $profileDefinition -AllowUnsupportedOS).IsCompatible | Should Be $true
    }
}

Describe '安全校验' {
    It '退出码映射稳定' {
        (Get-GrlExitCode -Name Success) | Should Be 0
        (Get-GrlExitCode -Name RestartRequired) | Should Be 10
        (Get-GrlExitCode -Name DownloadOrValidationFailed) | Should Be 20
        (Get-GrlExitCode -Name UnsupportedPlatform) | Should Be 30
        (Get-GrlExitCode -Name PartialFailure) | Should Be 40
        (Get-GrlExitCode -Name IntegrityFailed) | Should Be 50
        (Get-GrlExitCode -Name PrerequisiteMissing) | Should Be 60
    }

    It '拒绝越界路径' {
        Test-GrlChildPath -ParentPath 'C:\safe' -ChildPath 'C:\safe\file.txt' | Should Be $true
        Test-GrlChildPath -ParentPath 'C:\safe' -ChildPath 'C:\safe\..\escape.txt' | Should Be $false
    }

    It '哈希不匹配时拒绝文件' {
        $temp = New-GrlTempDirectory -Purpose 'test-hash'
        try {
            $file = Join-Path $temp 'payload.bin'
            [System.IO.File]::WriteAllText($file, 'test')
            $package = [pscustomobject]@{
                id = 'test'
                size = 4
                hashPolicy = 'Fixed'
                sha256 = ('0' * 64)
                signature = [pscustomobject]@{ required = $false; publisherContains = '' }
            }
            { Get-GrlDownloadedPackageState -Package $package -Path $file } | Should Throw
        }
        finally {
            Remove-GrlTempDirectory -Path $temp
        }
    }

    It '未签名文件不能通过签名校验' {
        $temp = New-GrlTempDirectory -Purpose 'test-signature'
        try {
            $file = Join-Path $temp 'payload.exe'
            [System.IO.File]::WriteAllText($file, 'test')
            { Assert-GrlPublisher -Path $file -PublisherContains 'Microsoft Corporation' } | Should Throw
        }
        finally {
            Remove-GrlTempDirectory -Path $temp
        }
    }

    It '离线模式缺少安装包时禁止联网' {
        $catalog = Import-GrlCatalog -RootPath $script:RootPath
        $package = ($catalog.components | Where-Object id -eq 'dotnet481').packages[0]
        $temp = New-GrlTempDirectory -Purpose 'test-offline'
        try {
            { Invoke-GrlSafeDownload -Package $package -DestinationDirectory $temp -AllowedDomains $catalog.officialDomains } | Should Throw
        }
        finally {
            Remove-GrlTempDirectory -Path $temp
        }
    }

    It '识别 ZIP 路径穿越' {
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $temp = New-GrlTempDirectory -Purpose 'test-zip'
        try {
            $archivePath = Join-Path $temp 'unsafe.zip'
            $fileStream = [System.IO.File]::Create($archivePath)
            $archive = New-Object System.IO.Compression.ZipArchive($fileStream, [System.IO.Compression.ZipArchiveMode]::Create)
            $entry = $archive.CreateEntry('../escape.txt')
            $writer = New-Object System.IO.StreamWriter($entry.Open())
            $writer.Write('escape')
            $writer.Dispose()
            $archive.Dispose()
            $fileStream.Dispose()
            $destination = Join-Path $temp 'extract'
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            Test-GrlArchiveTraversal -ArchivePath $archivePath -DestinationPath $destination | Should Be $false
        }
        finally {
            Remove-GrlTempDirectory -Path $temp
        }
    }

    It '下载缓存清单包含实际哈希' {
        $temp = New-GrlTempDirectory -Purpose 'test-cache-manifest'
        try {
            $state = [pscustomobject]@{
                PackageId = 'sample'
                Path = 'C:\Temp\sample.exe'
                Size = 123
                Sha256 = ('A' * 64)
                HashPolicy = 'Fixed'
                SignatureStatus = 'Valid'
                SignerSubject = 'CN=Sample'
                VerifiedAt = '2026-11-02T00:00:00Z'
            }
            Write-GrlPackageCacheManifest -Directory $temp -States @($state)
            $manifest = Get-Content -LiteralPath (Join-Path $temp 'package-manifest.json') -Raw | ConvertFrom-Json
            $manifest.packages[0].packageId | Should Be 'sample'
            $manifest.packages[0].sha256 | Should Be ('A' * 64)
        }
        finally {
            Remove-GrlTempDirectory -Path $temp
        }
    }

    It '按中文实际显示宽度格式化和截断' {
        (Get-GrlDisplayWidth -Text '中文ABC') | Should Be 7
        $cell = Format-GrlDisplayCell -Value '已安装' -Width 10
        (Get-GrlDisplayWidth -Text $cell) | Should Be 10
        (Get-GrlDisplayWidth -Text (Format-GrlDisplayCell -Value '这是一个很长的中文说明' -Width 12)) | Should Be 12
    }
}

Describe '安装行为' {
    It '正确处理标准退出码' {
        Get-GrlInstalledExitCategory -ExitCode 0 | Should Be 'Succeeded'
        Get-GrlInstalledExitCategory -ExitCode 1638 | Should Be 'Succeeded'
        Get-GrlInstalledExitCategory -ExitCode 3010 | Should Be 'RestartRequired'
        Get-GrlInstalledExitCategory -ExitCode 1641 | Should Be 'RestartRequired'
        Get-GrlInstalledExitCategory -ExitCode 1 | Should Be 'Failed'
    }

    It 'WhatIf 计划不下载文件' {
        $catalog = Import-GrlCatalog -RootPath $script:RootPath
        $profileDefinition = Get-GrlProfileDefinition -RootPath $script:RootPath -ProfileId 'Windows10-x64'
        $component = Get-GrlComponentById -Catalog $catalog -ComponentId 'dotnet481'
        $temp = New-GrlTempDirectory -Purpose 'test-plan'
        try {
            $plan = New-GrlInstallationPlan -Catalog $catalog -ProfileDefinition $profileDefinition -Components @($component) -PackageDirectory $temp -AllowNetwork $true -PreviewOnly
            $plan.PreviewOnly | Should Be $true
            @(Get-ChildItem -LiteralPath $temp -File).Count | Should Be 0
        }
        finally {
            Remove-GrlTempDirectory -Path $temp
        }
    }

    It '只补缺失的架构安装包并跳过已安装包' {
        $temp = New-GrlTempDirectory -Purpose 'test-package-skip'
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
                id = 'synthetic-vc'
                displayName = 'Synthetic VC++'
                tier = 'Core'
                order = 999
                applicability = [pscustomobject]@{ architectures = @('x86', 'x64') }
                installer = [pscustomobject]@{ type = 'Exe'; arguments = @('/quiet') }
                detection = $null
                packages = @(
                    [pscustomobject]@{
                        id = 'synthetic_x86'
                        architecture = 'x86'
                        fileName = 'x86.exe'
                        size = 1
                        hashPolicy = 'Fixed'
                        sha256 = ('A' * 64)
                        signature = [pscustomobject]@{ required = $false; publisherContains = '' }
                        detection = [pscustomobject]@{ type = 'FileAny'; files = @($present) }
                    },
                    [pscustomobject]@{
                        id = 'synthetic_x64'
                        architecture = 'x64'
                        fileName = 'x64.exe'
                        size = 1
                        hashPolicy = 'Fixed'
                        sha256 = ('B' * 64)
                        signature = [pscustomobject]@{ required = $false; publisherContains = '' }
                        detection = [pscustomobject]@{ type = 'FileAny'; files = @((Join-Path $temp 'missing.dll')) }
                    }
                )
            }
            $plan = New-GrlInstallationPlan -Catalog ([pscustomobject]@{ officialDomains = @('microsoft.com') }) -ProfileDefinition $profileDefinition -Components @($component) -PackageDirectory $temp -AllowNetwork $true -PreviewOnly
            $x86Plan = $plan.Entries[0].Packages | Where-Object { $_.Definition.id -eq 'synthetic_x86' } | Select-Object -First 1
            $x64Plan = $plan.Entries[0].Packages | Where-Object { $_.Definition.id -eq 'synthetic_x64' } | Select-Object -First 1
            $x86Plan.Skip | Should Be $true
            $x64Plan.Skip | Should Be $false
        }
        finally {
            Remove-GrlTempDirectory -Path $temp
        }
    }

    It '提权命令保留组件参数' {
        $line = Get-GrlElevationCommandLine -EntryScriptPath 'C:\Path With Space\Start.ps1' -Parameters @{
            Profile = 'Windows10-x64'
            Action = 'InstallOnline'
            ComponentId = @('dotnet481', 'directx9')
            OfflineRoot = ''
            FeatureSource = ''
            AllowUnsupportedOS = $true
            NonInteractive = $true
        }
        $line | Should Match 'InstallOnline'
        $line | Should Match 'dotnet481'
        $line | Should Match 'directx9'
        $line | Should Match 'AllowUnsupportedOS'
    }
}

Describe '发布完整性' {
    It 'release-lock 覆盖运行时脚本和配置' {
        $lock = Test-GrlReleaseIntegrity -RootPath $script:RootPath
        $lock.Files.Contains('Start-GameRuntimeLibrary.ps1') | Should Be $true
        $lock.Files.Contains('src\GameRuntimeLibrary.psm1') | Should Be $true
        $lock.Files.Contains('config\catalog.json') | Should Be $true
    }

    It '检测配置文件篡改' {
        $temp = New-GrlTempDirectory -Purpose 'test-release-integrity'
        try {
            Copy-GrlReleaseFiles -RootPath $script:RootPath -DestinationRoot $temp
            $catalogPath = Join-Path $temp 'config\catalog.json'
            [System.IO.File]::AppendAllText($catalogPath, ' ')
            { Test-GrlReleaseIntegrity -RootPath $temp } | Should Throw
        }
        finally {
            Remove-GrlTempDirectory -Path $temp
        }
    }
}

Describe 'GitHub 启动器' {
    It '规范化 HTTPS 与 SSH GitHub 地址' {
        $https = ConvertFrom-GrlGitHubRepositoryUrl -Url 'https://github.com/example/GameRuntimeLibrary'
        $https.CloneUrl | Should Be 'https://github.com/example/GameRuntimeLibrary.git'
        $ssh = ConvertFrom-GrlGitHubRepositoryUrl -Url 'git@github.com:example/GameRuntimeLibrary.git'
        $ssh.Slug | Should Be 'example/GameRuntimeLibrary'
    }

    It '拒绝非 GitHub 地址' {
        { ConvertFrom-GrlGitHubRepositoryUrl -Url 'https://example.com/example/repo.git' } | Should Throw
        { ConvertFrom-GrlGitHubRepositoryUrl -Url 'https://github.com/example/repo/extra' } | Should Throw
    }

    It '拒绝不安全分支名' {
        { Assert-GrlGitHubBranch -Branch '../main' } | Should Throw
        { Assert-GrlGitHubBranch -Branch 'main branch' } | Should Throw
        Assert-GrlGitHubBranch -Branch 'release/2026-11' | Should Be 'release/2026-11'
    }

    It '生成 GitHub ZIP 回退地址' {
        $repository = ConvertFrom-GrlGitHubRepositoryUrl -Url 'https://github.com/example/GameRuntimeLibrary.git'
        (Get-GrlGitHubArchiveUrl -Repository $repository -Branch 'main') | Should Be 'https://github.com/example/GameRuntimeLibrary/archive/refs/heads/main.zip'
    }

    It '优先使用当前 Git 仓库的 GitHub origin' {
        $repository = Resolve-GrlBootstrapRepository -SettingsRepositoryUrl 'https://github.com/old/GameRuntimeLibrary.git' -LocalRepositoryUrl 'https://github.com/current/GameRuntimeLibrary.git'
        $repository.Slug | Should Be 'current/GameRuntimeLibrary'
    }

    It '保存并读取首次运行配置' {
        $temp = New-GrlTempDirectory -Purpose 'test-bootstrap-settings'
        try {
            $settingsPath = Join-Path $temp 'bootstrap.json'
            Save-GrlBootstrapSettings -SettingsPath $settingsPath -RepositoryUrl 'https://github.com/example/GameRuntimeLibrary.git' -Branch 'main' -InstallRoot (Join-Path $temp 'app')
            $settings = Read-GrlBootstrapSettings -SettingsPath $settingsPath
            $settings.RepositoryUrl | Should Be 'https://github.com/example/GameRuntimeLibrary.git'
            $settings.Branch | Should Be 'main'
        }
        finally {
            Remove-GrlTempDirectory -Path $temp
        }
    }

    It '从发布清单识别构建通道' {
        $temp = New-GrlTempDirectory -Purpose 'test-bootstrap-channel'
        try {
            (Get-GrlBootstrapReleaseKind -InstallRoot $temp) | Should Be 'Unknown'
            $config = Join-Path $temp 'config'
            New-Item -ItemType Directory -Path $config -Force | Out-Null
            $lock = Join-Path $config 'release-lock.ps1'
            [System.IO.File]::WriteAllText($lock, "`$GameRuntimeReleaseLock = [ordered]@{`r`n    ReleaseKind = 'Production'`r`n}`r`n", (New-Object System.Text.UTF8Encoding($true)))
            (Get-GrlBootstrapReleaseKind -InstallRoot $temp) | Should Be 'Production'
        }
        finally {
            Remove-GrlTempDirectory -Path $temp
        }
    }

    It '正式版入口未签名时拒绝启动' {
        $temp = New-GrlTempDirectory -Purpose 'test-bootstrap-production'
        try {
            [System.IO.File]::WriteAllText((Join-Path $temp 'Start-GameRuntimeLibrary.ps1'), "Write-Host 'test'`r`n", (New-Object System.Text.UTF8Encoding($true)))
            $config = Join-Path $temp 'config'
            New-Item -ItemType Directory -Path $config -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $config 'release-lock.ps1'), "`$GameRuntimeReleaseLock = [ordered]@{`r`n    ReleaseKind = 'Production'`r`n}`r`n", (New-Object System.Text.UTF8Encoding($true)))
            { Start-GrlBootstrapMenu -InstallRoot $temp } | Should Throw
        }
        finally {
            Remove-GrlTempDirectory -Path $temp
        }
    }

    It '本地仓库有未提交修改时拒绝自动更新' {
        $git = Get-GrlGitExecutable
        if ($null -eq $git) {
            return
        }
        $temp = New-GrlTempDirectory -Purpose 'test-bootstrap-git'
        try {
            & $git init $temp | Out-Null
            & $git -C $temp config user.email 'test@example.com' | Out-Null
            & $git -C $temp config user.name 'GameRuntimeLibrary Test' | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $temp 'file.txt'), 'initial')
            & $git -C $temp add . | Out-Null
            & $git -C $temp commit -m 'initial' | Out-Null
            & $git -C $temp remote add origin 'https://github.com/example/GameRuntimeLibrary.git' | Out-Null
            [System.IO.File]::AppendAllText((Join-Path $temp 'file.txt'), 'dirty')
            $repository = ConvertFrom-GrlGitHubRepositoryUrl -Url 'https://github.com/example/GameRuntimeLibrary.git'
            { Update-GrlGitCheckout -GitPath $git -InstallRoot $temp -Repository $repository -Branch 'main' } | Should Throw
        }
        finally {
            Remove-GrlTempDirectory -Path $temp
        }
    }

    It '拒绝包含路径穿越的仓库 ZIP' {
        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $temp = New-GrlTempDirectory -Purpose 'test-bootstrap-zip'
        try {
            $archivePath = Join-Path $temp 'unsafe.zip'
            $fileStream = [System.IO.File]::Create($archivePath)
            $archive = New-Object System.IO.Compression.ZipArchive($fileStream, [System.IO.Compression.ZipArchiveMode]::Create)
            $entry = $archive.CreateEntry('../escape.txt')
            $writer = New-Object System.IO.StreamWriter($entry.Open())
            $writer.Write('escape')
            $writer.Dispose()
            $archive.Dispose()
            $fileStream.Dispose()
            $destination = Join-Path $temp 'extract'
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            { Assert-GrlArchiveSafe -ArchivePath $archivePath -DestinationPath $destination } | Should Throw
        }
        finally {
            Remove-GrlTempDirectory -Path $temp
        }
    }

    It '提供 CMD 双击入口和平台入口' {
        Test-Path -LiteralPath (Join-Path $script:RootPath 'GameRuntimeLibrary.cmd') -PathType Leaf | Should Be $true
        Test-Path -LiteralPath (Join-Path $script:RootPath 'tools\Bootstrap-GameRuntimeLibrary.ps1') -PathType Leaf | Should Be $true
        Test-Path -LiteralPath (Join-Path $script:RootPath 'Windows 10 x64\GameRuntimeLibrary.cmd') -PathType Leaf | Should Be $true
    }
}

Describe '界面语言' {
    It '首次无配置时默认简体中文' {
        $temp = New-GrlTempDirectory -Purpose 'test-language-default'
        try {
            $settings = Join-Path $temp 'ui-settings.json'
            $language = Resolve-GrlLanguage -RootPath $script:RootPath -RequestedLanguage 'Auto' -SettingsPath $settings
            $language | Should Be 'zh-CN'
            (Test-Path -LiteralPath $settings) | Should Be $false
        }
        finally {
            Remove-GrlTempDirectory -Path $temp
        }
    }

    It '保存并恢复英文语言偏好' {
        $temp = New-GrlTempDirectory -Purpose 'test-language-preference'
        try {
            $settings = Join-Path $temp 'ui-settings.json'
            (Resolve-GrlLanguage -RootPath $script:RootPath -RequestedLanguage 'en-US' -SettingsPath $settings) | Should Be 'en-US'
            (Resolve-GrlLanguage -RootPath $script:RootPath -RequestedLanguage 'Auto' -SettingsPath $settings) | Should Be 'en-US'
            (Get-GrlText -Key 'menu.checkStatus') | Should Be 'Check component status'
            (Get-GrlText -Key 'menu.installOnline') | Should Match 'skip installed'
        }
        finally {
            Set-GrlLanguage -Language 'zh-CN'
            Remove-GrlTempDirectory -Path $temp
        }
    }

    It '中英文菜单包含完整分组' {
        Set-GrlLanguage -Language 'zh-CN'
        (Get-GrlText -Key 'menu.groupMaintenance') | Should Be '安装与维护'
        (Get-GrlText -Key 'menu.groupOffline') | Should Be '离线部署'
        (Get-GrlText -Key 'menu.groupInfo') | Should Be '信息与设置'
        Set-GrlLanguage -Language 'en-US'
        (Get-GrlText -Key 'menu.groupMaintenance') | Should Be 'Installation & Maintenance'
        (Get-GrlText -Key 'menu.groupOffline') | Should Be 'Offline Deployment'
        (Get-GrlText -Key 'menu.groupInfo') | Should Be 'Information & Settings'
        Set-GrlLanguage -Language 'zh-CN'
    }

    It '提权命令保留界面语言' {
        $line = Get-GrlElevationCommandLine -EntryScriptPath 'C:\Path\Start.ps1' -Parameters @{
            Profile = 'Windows10-x64'
            Action = 'InstallOnline'
            Language = 'en-US'
            ComponentId = @()
            OfflineRoot = ''
            FeatureSource = ''
            AllowUnsupportedOS = $false
            NonInteractive = $true
        }
        $line | Should Match "-Language 'en-US'"
    }
}
