$script:RootPath = Split-Path $PSScriptRoot -Parent
Import-Module -Name (Join-Path $script:RootPath 'src\GameRuntimeLibrary.psm1') -Force
Initialize-GrlLocalization -RootPath $script:RootPath | Out-Null
Set-GrlLanguage -Language 'zh-CN'

Describe '进度显示' {
    It '按单位格式化字节数' {
        (Format-GrlByteSize -Bytes 0) | Should Be '0 B'
        (Format-GrlByteSize -Bytes 1024) | Should Be '1.0 KB'
        (Format-GrlByteSize -Bytes 1572864) | Should Be '1.5 MB'
        (Format-GrlByteSize -Bytes 1073741824) | Should Be '1.00 GB'
    }

    It '格式化耗时' {
        (Format-GrlDuration -Duration (New-TimeSpan -Seconds 65)) | Should Be '01:05'
        (Format-GrlDuration -Duration (New-TimeSpan -Seconds 3661)) | Should Be '01:01:01'
    }

    It '强制输出时包含活动名与百分比' {
        $captured = (& { Write-GrlProgress -Activity '下载 sample.exe' -Status '1.0 MB / 2.0 MB' -Percent 50 -Force } 6>&1 | ForEach-Object { $_.ToString() }) -join ''
        $captured | Should Match 'sample.exe'
        $captured | Should Match '50%'
        $captured | Should Match '1.0 MB'
    }

    It '非交互模式不弹完成提示' {
        { Send-GrlCompletionNotification -Title 'test' -Message 'test' -NonInteractive } | Should Not Throw
    }
}

Describe '安装结果汇总' {
    It '区分已安装、未安装与需重启' {
        $states = @(
            [pscustomobject]@{ Id = 'a'; DisplayName = '组件 A'; State = 'Installed'; Summary = '1/1 项通过' }
            [pscustomobject]@{ Id = 'b'; DisplayName = '组件 B'; State = 'Missing'; Summary = '缺少主体' }
            [pscustomobject]@{ Id = 'c'; DisplayName = '组件 C'; State = 'Missing'; Summary = '等待重启' }
        )
        $items = @(
            [pscustomobject]@{ ComponentId = 'a'; Status = 'Succeeded' }
            [pscustomobject]@{ ComponentId = 'c'; Status = 'RestartRequired' }
        )
        $captured = (& { Write-GrlInstallationResult -Items $items -States $states -ExitCode 10 } 6>&1 | ForEach-Object { $_.ToString() }) -join "`n"
        $result = Write-GrlInstallationResult -Items $items -States $states -ExitCode 10

        $result.Installed.Count | Should Be 1
        $result.NotInstalled.Count | Should Be 1
        $result.Restart.Count | Should Be 1
        $result.NotInstalled[0].Id | Should Be 'b'
        $captured | Should Match '仍未安装'
        $captured | Should Match '组件 B'
    }

    It '全部安装时不报告未安装项' {
        $states = @(
            [pscustomobject]@{ Id = 'a'; DisplayName = '组件 A'; State = 'Installed'; Summary = '1/1 项通过' }
        )
        $items = @([pscustomobject]@{ ComponentId = 'a'; Status = 'Succeeded' })
        $result = Write-GrlInstallationResult -Items $items -States $states -ExitCode 0
        $result.NotInstalled.Count | Should Be 0
        $result.Installed.Count | Should Be 1
    }
}
