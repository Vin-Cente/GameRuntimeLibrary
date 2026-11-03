$ErrorActionPreference = 'Stop'

function Get-GrlWindowsDisplayVersion {
    $displayVersion = ''
    $updateBuildRevision = 0
    $baseKey = $null
    $subKey = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $subKey = $baseKey.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion', $false)
        if ($null -ne $subKey) {
            $value = $subKey.GetValue('DisplayVersion', '')
            if ($null -ne $value) {
                $displayVersion = ([string]$value).Trim()
            }
            $revisionValue = $subKey.GetValue('UBR', 0)
            if ($null -ne $revisionValue) {
                $parsedRevision = 0
                if ([int]::TryParse([string]$revisionValue, [ref]$parsedRevision)) {
                    $updateBuildRevision = $parsedRevision
                }
            }
        }
    }
    catch {
        $displayVersion = ''
        $updateBuildRevision = 0
    }
    finally {
        if ($null -ne $subKey) {
            $subKey.Dispose()
        }
        if ($null -ne $baseKey) {
            $baseKey.Dispose()
        }
    }

    return [pscustomobject]@{
        DisplayVersion = [string]$displayVersion
        UpdateBuildRevision = [int]$updateBuildRevision
    }
}

function Get-GrlSystemInfo {
    $version = [Environment]::OSVersion.Version
    $caption = "Windows $($version.Major).$($version.Minor)"
    $osArchitecture = [string]$env:PROCESSOR_ARCHITECTURE
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $caption = $os.Caption
        $version = [version]$os.Version
        $osArchitecture = [string]$os.OSArchitecture
    }
    catch {
        Write-GrlLog -Level '警告' -Message "无法读取完整系统信息，使用环境回退：$($_.Exception.Message)" -Component 'Platform'
    }

    $processorArchitecture = [string]$env:PROCESSOR_ARCHITECTURE
    $architecture = 'x86'
    if ($processorArchitecture -in @('ARM64', 'ARM64EC') -or $osArchitecture -match '(?i)ARM') {
        $architecture = 'arm64'
    }
    elseif ([Environment]::Is64BitOperatingSystem) {
        $architecture = 'x64'
    }

    $osName = 'Unsupported'
    if ($version.Major -eq 10 -and $version.Build -ge 22000) {
        $osName = 'Windows 11'
    }
    elseif ($version.Major -eq 10 -and $version.Build -ge 10240) {
        $osName = 'Windows 10'
    }

    $displayVersionInfo = Get-GrlWindowsDisplayVersion

    return [pscustomobject]@{
        Caption = [string]$caption
        Version = $version
        OSName = $osName
        Build = $version.Build
        Architecture = $architecture
        IsAdministrator = Test-GrlAdministrator
        PendingReboot = Test-GrlPendingReboot
        DisplayVersion = [string]$displayVersionInfo.DisplayVersion
        UpdateBuildRevision = [int]$displayVersionInfo.UpdateBuildRevision
    }
}

<#
.SYNOPSIS
    根据系统信息解析目标平台标识。
.DESCRIPTION
    RequestedProfile 为 Auto 时按系统信息推断受支持的平台标识；
    无法识别（例如 ARM64 或未知操作系统）时返回 $null 表示平台不受支持，不再抛出异常。
    显式传入的 Profile 原样返回，由调用方负责校验。
.OUTPUTS
    System.String，可能取值 Windows11-x64 / Windows10-x64 / Windows10-x86，无法识别时为 $null。
#>
function Resolve-GrlProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RequestedProfile,
        [Parameter(Mandatory = $true)]
        [object]$SystemInfo
    )

    if ($RequestedProfile -ne 'Auto') {
        return $RequestedProfile
    }
    if ($SystemInfo.OSName -eq 'Windows 11' -and $SystemInfo.Architecture -eq 'x64') {
        return 'Windows11-x64'
    }
    if ($SystemInfo.OSName -eq 'Windows 10' -and $SystemInfo.Architecture -eq 'x64') {
        return 'Windows10-x64'
    }
    if ($SystemInfo.OSName -eq 'Windows 10' -and $SystemInfo.Architecture -eq 'x86') {
        return 'Windows10-x86'
    }
    return $null
}

function Assert-GrlPlatformCompatibility {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SystemInfo,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition,
        [switch]$AllowUnsupportedOS
    )

    $unsupportedExitCode = Get-GrlExitCode -Name UnsupportedPlatform

    if ($SystemInfo.Architecture -eq 'arm64') {
        return [pscustomobject]@{
            IsCompatible = $false
            IsWarning = $false
            ExitCode = $unsupportedExitCode
            Message = Get-GrlText -Key 'platform.armUnsupported'
        }
    }
    if ($SystemInfo.OSName -notin @('Windows 10', 'Windows 11')) {
        return [pscustomobject]@{
            IsCompatible = $false
            IsWarning = $false
            ExitCode = $unsupportedExitCode
            Message = (Get-GrlText -Key 'platform.osUnsupported') -f $SystemInfo.Caption
        }
    }

    $minimumBuild = [int]$ProfileDefinition.minimumBuild
    $recommendedBuild = [int]$ProfileDefinition.recommendedBuild
    $buildTooLow = [int]$SystemInfo.Build -lt $minimumBuild
    $buildExitCode = 0
    if ($buildTooLow) {
        $buildExitCode = $unsupportedExitCode
    }

    $osMismatch = $SystemInfo.OSName -ne $ProfileDefinition.osName
    $architectureMismatch = $SystemInfo.Architecture -ne $ProfileDefinition.architecture
    if ($osMismatch -or $architectureMismatch) {
        $message = (Get-GrlText -Key 'platform.mismatch') -f $SystemInfo.OSName, $SystemInfo.Architecture, $ProfileDefinition.displayName
        return [pscustomobject]@{
            IsCompatible = [bool]$AllowUnsupportedOS
            IsWarning = $true
            ExitCode = $buildExitCode
            Message = $message
        }
    }

    if ($buildTooLow) {
        $message = (Get-GrlText -Key 'platform.buildTooLow') -f $SystemInfo.Build, $ProfileDefinition.minimumBuild
        return [pscustomobject]@{
            IsCompatible = [bool]$AllowUnsupportedOS
            IsWarning = $true
            ExitCode = $unsupportedExitCode
            Message = $message
        }
    }

    $baselineMismatch = $false
    if ($ProfileDefinition.osName -eq 'Windows 10' -and [int]$SystemInfo.Build -lt $recommendedBuild) {
        # 同一 servicing 分支（如 19041-19045 同属一个基线）不视为偏离，避免 LTSC/累积更新误报。
        $currentBranch = [Math]::Floor([int]$SystemInfo.Build / 100)
        $baselineBranch = [Math]::Floor($recommendedBuild / 100)
        if ($currentBranch -lt $baselineBranch) {
            $baselineMismatch = $true
        }
    }

    if ($baselineMismatch) {
        return [pscustomobject]@{
            IsCompatible = $true
            IsWarning = $true
            ExitCode = 0
            Message = (Get-GrlText -Key 'platform.win10Baseline') -f $SystemInfo.Build, $ProfileDefinition.recommendedBuild
        }
    }

    return [pscustomobject]@{
        IsCompatible = $true
        IsWarning = $false
        ExitCode = 0
        Message = '平台兼容。'
    }
}

function Test-GrlActionRequiresAdministrator {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action
    )
    return $Action -in @('InstallOnline', 'InstallOffline', 'RepairMissing')
}

function Get-GrlActionDisplayName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action
    )
    $names = @{
        Menu = '主菜单'
        InstallOnline = '在线全量安装'
        PrepareOffline = '下载并制作离线包'
        InstallOffline = '离线安装'
        Verify = '验证运行库状态'
        Status = '查看组件状态'
        DllStatus = '查看 DLL / 程序集状态'
        RepairMissing = '修复缺失组件'
    }
    return $names[$Action]
}

Export-ModuleMember -Function Get-GrlSystemInfo, Resolve-GrlProfile, Assert-GrlPlatformCompatibility, Test-GrlActionRequiresAdministrator, Get-GrlActionDisplayName
