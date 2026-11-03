$script:RootPath = Split-Path $PSScriptRoot -Parent
Import-Module -Name (Join-Path $script:RootPath 'src\GameRuntimeLibrary.psm1') -Force

function New-GrlSyntheticProfile {
    return [pscustomobject]@{
        id = 'Windows10-x64'
        displayName = 'Windows 10 x64'
        osName = 'Windows 10'
        architecture = 'x64'
        minimumBuild = 10240
        recommendedBuild = 19045
        architectures = @('x86', 'x64', 'any')
    }
}

Describe '卸载项选择' {
    It '同名显示名时按注册表视图选中 x86' {
        $entries = @(
            [pscustomobject]@{ DisplayName = 'Microsoft Visual C++ 2010  x86 Redistributable'; DisplayVersion = '10.0.40219'; Architecture = 'x86' },
            [pscustomobject]@{ DisplayName = 'Microsoft Visual C++ 2010  x86 Redistributable'; DisplayVersion = '10.0.40219'; Architecture = 'x64' }
        )
        $detection = [pscustomobject]@{ type = 'UninstallEntry'; displayNameContains = 'Microsoft Visual C++ 2010'; architectureHint = 'x86'; minimumVersion = '' }
        $entry = Select-GrlUninstallEntry -Entries $entries -Detection $detection
        $entry.Architecture | Should Be 'x86'
    }

    It '同名显示名时按注册表视图选中 x64' {
        $entries = @(
            [pscustomobject]@{ DisplayName = 'Microsoft Visual C++ 2010  x86 Redistributable'; DisplayVersion = '10.0.40219'; Architecture = 'x86' },
            [pscustomobject]@{ DisplayName = 'Microsoft Visual C++ 2010  x86 Redistributable'; DisplayVersion = '10.0.40219'; Architecture = 'x64' }
        )
        $detection = [pscustomobject]@{ type = 'UninstallEntry'; displayNameContains = 'Microsoft Visual C++ 2010'; architectureHint = 'x64'; minimumVersion = '' }
        $entry = Select-GrlUninstallEntry -Entries $entries -Detection $detection
        $entry.Architecture | Should Be 'x64'
    }

    It '无注册表视图信息时退回显示名正则' {
        $entries = @(
            [pscustomobject]@{ DisplayName = 'Microsoft Visual C++ 2013 Redistributable (x86) - 12.0.40664'; DisplayVersion = '12.0.40664'; Architecture = $null },
            [pscustomobject]@{ DisplayName = 'Microsoft Visual C++ 2013 Redistributable (x64) - 12.0.40664'; DisplayVersion = '12.0.40664'; Architecture = $null }
        )
        $base = [pscustomobject]@{ type = 'UninstallEntry'; displayNameContains = 'Microsoft Visual C++ 2013'; minimumVersion = '' }
        $x64Detection = [pscustomobject]@{ type = 'UninstallEntry'; displayNameContains = 'Microsoft Visual C++ 2013'; architectureHint = 'x64'; minimumVersion = '' }
        $x86Detection = [pscustomobject]@{ type = 'UninstallEntry'; displayNameContains = 'Microsoft Visual C++ 2013'; architectureHint = 'x86'; minimumVersion = '' }

        (Select-GrlUninstallEntry -Entries $entries -Detection $x64Detection).DisplayName | Should Match '\(x64\)'
        (Select-GrlUninstallEntry -Entries $entries -Detection $x86Detection).DisplayName | Should Match '\(x86\)'
        (Select-GrlUninstallEntry -Entries $entries -Detection $base).DisplayVersion | Should Be '12.0.40664'
    }

    It '按最低版本过滤并返回最高版本' {
        $entries = @(
            [pscustomobject]@{ DisplayName = 'Sample Runtime'; DisplayVersion = '1.0.0'; Architecture = 'x86' },
            [pscustomobject]@{ DisplayName = 'Sample Runtime'; DisplayVersion = '9.0.0'; Architecture = 'x86' },
            [pscustomobject]@{ DisplayName = 'Sample Runtime'; DisplayVersion = '5.0.0'; Architecture = 'x86' }
        )
        $detection = [pscustomobject]@{ type = 'UninstallEntry'; displayNameContains = 'Sample Runtime'; architectureHint = ''; minimumVersion = '2.0.0' }
        $entry = Select-GrlUninstallEntry -Entries $entries -Detection $detection
        $entry.DisplayVersion | Should Be '9.0.0'

        $highMinimum = [pscustomobject]@{ type = 'UninstallEntry'; displayNameContains = 'Sample Runtime'; architectureHint = ''; minimumVersion = '10.0.0' }
        $null -eq (Select-GrlUninstallEntry -Entries $entries -Detection $highMinimum) | Should Be $true
    }

    It '无匹配项返回 $null' {
        $entries = @(
            [pscustomobject]@{ DisplayName = 'Sample Runtime'; DisplayVersion = '1.0.0'; Architecture = 'x86' }
        )
        $detection = [pscustomobject]@{ type = 'UninstallEntry'; displayNameContains = 'Not Installed Runtime'; architectureHint = ''; minimumVersion = '' }
        $null -eq (Select-GrlUninstallEntry -Entries $entries -Detection $detection) | Should Be $true
        $null -eq (Select-GrlUninstallEntry -Entries @() -Detection $detection) | Should Be $true
    }
}

Describe '平台识别与兼容性' {
    It 'ARM64 无法自动识别时返回 $null' {
        $system = [pscustomobject]@{ OSName = 'Unsupported'; Architecture = 'arm64'; Build = 22000; Caption = 'Unknown'; IsAdministrator = $false; PendingReboot = $false }
        $null -eq (Resolve-GrlProfile -RequestedProfile 'Auto' -SystemInfo $system) | Should Be $true
    }

    It 'Windows 10 x64 仍返回 Windows10-x64' {
        $system = [pscustomobject]@{ OSName = 'Windows 10'; Architecture = 'x64'; Build = 19045; Caption = 'Windows 10'; IsAdministrator = $false; PendingReboot = $false }
        Resolve-GrlProfile -RequestedProfile 'Auto' -SystemInfo $system | Should Be 'Windows10-x64'
        Resolve-GrlProfile -RequestedProfile 'Windows11-x64' -SystemInfo $system | Should Be 'Windows11-x64'
    }

    It 'ARM64 系统不兼容且退出码为 30' {
        $system = [pscustomobject]@{ OSName = 'Windows 11'; Architecture = 'arm64'; Build = 22631; Caption = 'Windows 11 ARM'; IsAdministrator = $false; PendingReboot = $false }
        $profileDefinition = [pscustomobject]@{ id = 'Windows11-x64'; displayName = 'Windows 11 x64'; osName = 'Windows 11'; architecture = 'x64'; minimumBuild = 22000; recommendedBuild = 22000; architectures = @('x86', 'x64', 'any') }
        $result = Assert-GrlPlatformCompatibility -SystemInfo $system -ProfileDefinition $profileDefinition
        $result.IsCompatible | Should Be $false
        $result.IsWarning | Should Be $false
        $result.ExitCode | Should Be 30
    }

    It 'Windows 10 Build 低于推荐基线但不低于最低要求时不告警' {
        $system = [pscustomobject]@{ OSName = 'Windows 10'; Architecture = 'x64'; Build = 19044; Caption = 'Windows 10'; IsAdministrator = $false; PendingReboot = $false }
        $profileDefinition = New-GrlSyntheticProfile
        $result = Assert-GrlPlatformCompatibility -SystemInfo $system -ProfileDefinition $profileDefinition
        $result.IsCompatible | Should Be $true
        $result.IsWarning | Should Be $false
        $result.ExitCode | Should Be 0
    }

    It 'Windows 10 Build 等于最低要求时告警' {
        $system = [pscustomobject]@{ OSName = 'Windows 10'; Architecture = 'x64'; Build = 10240; Caption = 'Windows 10'; IsAdministrator = $false; PendingReboot = $false }
        $profileDefinition = New-GrlSyntheticProfile
        $result = Assert-GrlPlatformCompatibility -SystemInfo $system -ProfileDefinition $profileDefinition
        $result.IsCompatible | Should Be $true
        $result.IsWarning | Should Be $true
        $result.ExitCode | Should Be 0
    }

    It '平台不匹配时显式允许仍可用但退出码为 30' {
        $system = [pscustomobject]@{ OSName = 'Windows 10'; Architecture = 'x64'; Build = 19045; Caption = 'Windows 10'; IsAdministrator = $false; PendingReboot = $false }
        $profileDefinition = [pscustomobject]@{ id = 'Windows11-x64'; displayName = 'Windows 11 x64'; osName = 'Windows 11'; architecture = 'x64'; minimumBuild = 22000; recommendedBuild = 22000; architectures = @('x86', 'x64', 'any') }
        (Assert-GrlPlatformCompatibility -SystemInfo $system -ProfileDefinition $profileDefinition).IsCompatible | Should Be $false
        $allowed = Assert-GrlPlatformCompatibility -SystemInfo $system -ProfileDefinition $profileDefinition -AllowUnsupportedOS
        $allowed.IsCompatible | Should Be $true
        $allowed.ExitCode | Should Be 30
    }
}

Describe '组件状态合并' {
    It '组件级与包级状态合并后存在缺失即报缺失' {
        $temp = New-GrlTempDirectory -Purpose 'test-component-merge-missing'
        try {
            $present = Join-Path $temp 'present.dll'
            [System.IO.File]::WriteAllText($present, 'present')
            $missing = Join-Path $temp 'missing.dll'
            $profileDefinition = New-GrlSyntheticProfile
            $component = [pscustomobject]@{
                id = 'synthetic-merge'
                displayName = 'Synthetic Merge'
                tier = 'Core'
                order = 900
                applicability = [pscustomobject]@{ architectures = @('x86', 'x64') }
                installer = [pscustomobject]@{ type = 'Exe' }
                detection = [pscustomobject]@{ type = 'FileAny'; files = @($present) }
                packages = @(
                    [pscustomobject]@{ id = 'synthetic_merge_x86'; architecture = 'x86'; detection = [pscustomobject]@{ type = 'FileAny'; files = @($present) } },
                    [pscustomobject]@{ id = 'synthetic_merge_x64'; architecture = 'x64'; detection = [pscustomobject]@{ type = 'FileAny'; files = @($missing) } }
                )
            }
            $state = Get-GrlComponentState -Component $component -ProfileDefinition $profileDefinition
            $state.State | Should Be 'Missing'
            $state.PackageStates.Count | Should Be 3
            @($state.PackageStates | Where-Object { $_.Name -eq 'Component' }).Count | Should Be 1
        }
        finally {
            Remove-GrlTempDirectory -Path $temp
        }
    }

    It '组件级与包级全部存在时报已安装' {
        $temp = New-GrlTempDirectory -Purpose 'test-component-merge-installed'
        try {
            $present = Join-Path $temp 'present.dll'
            [System.IO.File]::WriteAllText($present, 'present')
            $other = Join-Path $temp 'other.dll'
            [System.IO.File]::WriteAllText($other, 'other')
            $profileDefinition = New-GrlSyntheticProfile
            $component = [pscustomobject]@{
                id = 'synthetic-merge-ok'
                displayName = 'Synthetic Merge OK'
                tier = 'Core'
                order = 901
                applicability = [pscustomobject]@{ architectures = @('x86', 'x64') }
                installer = [pscustomobject]@{ type = 'Exe' }
                detection = [pscustomobject]@{ type = 'FileAny'; files = @($present) }
                packages = @(
                    [pscustomobject]@{ id = 'synthetic_ok_x86'; architecture = 'x86'; detection = [pscustomobject]@{ type = 'FileAny'; files = @($present) } },
                    [pscustomobject]@{ id = 'synthetic_ok_x64'; architecture = 'x64'; detection = [pscustomobject]@{ type = 'FileAny'; files = @($other) } }
                )
            }
            $state = Get-GrlComponentState -Component $component -ProfileDefinition $profileDefinition
            $state.State | Should Be 'Installed'
            $state.PackageStates.Count | Should Be 3
        }
        finally {
            Remove-GrlTempDirectory -Path $temp
        }
    }

    It '没有检测规则的包不会产生未知状态' {
        $profileDefinition = New-GrlSyntheticProfile
        $component = [pscustomobject]@{
            id = 'synthetic-no-package-detection'
            displayName = 'Synthetic No Package Detection'
            tier = 'Core'
            order = 902
            applicability = [pscustomobject]@{ architectures = @('x86', 'x64') }
            installer = [pscustomobject]@{ type = 'Exe' }
            detection = $null
            packages = @(
                [pscustomobject]@{ id = 'synthetic_none_x86'; architecture = 'x86'; detection = $null },
                [pscustomobject]@{ id = 'synthetic_none_x64'; architecture = 'x64'; detection = $null }
            )
        }
        $state = Get-GrlComponentState -Component $component -ProfileDefinition $profileDefinition
        $state.State | Should Be 'Unknown'
        $state.PackageStates.Count | Should Be 0
    }
}

Describe 'DLL 文件存在性' {
    It '系统目录中的 kernel32.dll 可被找到' {
        Clear-GrlDetectionCache
        $result = Test-GrlDllPresence -FileName 'kernel32.dll'
        $result.Present | Should Be $true
        $result.Path | Should Match '(?i)kernel32\.dll$'
        $result.Searched | Should BeGreaterThan 0
    }

    It '不存在的 DLL 返回未找到' {
        Clear-GrlDetectionCache
        $result = Test-GrlDllPresence -FileName 'definitely-not-a-real-dll-xyz.dll'
        $result.Present | Should Be $false
        $result.Path | Should Be ''
        $result.Searched | Should BeGreaterThan 0
    }

    It '带路径的输入直接抛错' {
        { Test-GrlDllPresence -FileName 'C:\Windows\System32\kernel32.dll' } | Should Throw
        { Test-GrlDllPresence -FileName '..\kernel32.dll' } | Should Throw
    }

    It 'Get-GrlDllStates 每行包含文件存在性' {
        $dllMap = [pscustomobject]@{
            items = @(
                [pscustomobject]@{ componentId = 'synthetic-dll'; files = @('kernel32.dll', 'definitely-not-a-real-dll-xyz.dll') }
            )
        }
        $component = [pscustomobject]@{
            id = 'synthetic-dll'
            displayName = 'Synthetic DLL'
            tier = 'Core'
            order = 903
        }
        $componentStates = @([pscustomobject]@{ Id = 'synthetic-dll'; DisplayName = 'Synthetic DLL'; State = 'Installed'; Summary = '' })
        $rows = @(Get-GrlDllStates -DllMap $dllMap -Components @($component) -ComponentStates $componentStates)
        $rows.Count | Should Be 2
        @($rows | Where-Object { $null -eq $_.PSObject.Properties['Presence'] }).Count | Should Be 0
        @($rows | Where-Object { $null -eq $_.PSObject.Properties['PresencePath'] }).Count | Should Be 0
        ($rows | Where-Object { $_.File -eq 'kernel32.dll' }).Presence | Should Be $true
        ($rows | Where-Object { $_.File -eq 'definitely-not-a-real-dll-xyz.dll' }).Presence | Should Be $false
    }
}
