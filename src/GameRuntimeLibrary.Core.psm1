$ErrorActionPreference = 'Stop'

$script:ExitCodes = @{
    Success = 0
    RestartRequired = 10
    DownloadOrValidationFailed = 20
    UnsupportedPlatform = 30
    PartialFailure = 40
    IntegrityFailed = 50
    PrerequisiteMissing = 60
}

$script:TempRoot = Join-Path $env:TEMP 'CodexProjectArtifacts\GameRuntimeLibrary'
$script:LogPath = $null
$script:ProgressSupported = $null

function Get-GrlExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if (-not $script:ExitCodes.ContainsKey($Name)) {
        throw "未知退出码名称：$Name"
    }
    return [int]$script:ExitCodes[$Name]
}

function New-GrlException {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [int]$ExitCode = 40,
        [string]$Category = 'GameRuntimeLibrary'
    )

    $exception = New-Object System.Exception($Message)
    $exception.Data['GrlExitCode'] = [int]$ExitCode
    $exception.Data['GrlCategory'] = [string]$Category
    return $exception
}

function Get-GrlExceptionExitCode {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $exception = $ErrorRecord.Exception
    while ($null -ne $exception) {
        $data = $exception.Data
        if ($null -ne $data -and $data.Contains('GrlExitCode')) {
            return [int]$data['GrlExitCode']
        }
        $exception = $exception.InnerException
    }
    return $null
}

function Remove-GrlOldLogFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,
        [int]$Keep = 30
    )

    if ($Keep -le 0) {
        $Keep = 1
    }
    if ([string]::IsNullOrWhiteSpace($Directory)) {
        return
    }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        return
    }

    $files = @(Get-ChildItem -LiteralPath $Directory -File -Filter 'GameRuntimeLibrary-*.log' -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending)
    if ($files.Count -le $Keep) {
        return
    }

    $index = 0
    foreach ($file in $files) {
        $index++
        if ($index -le $Keep) {
            continue
        }
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
        }
        catch {
            # 日志清理失败不影响本次运行，只写入调试日志，避免在控制台产生无关告警。
            Write-GrlLog -Level '调试' -Message "无法删除旧日志文件 $($file.Name)：$($_.Exception.Message)" -Component 'Core'
        }
    }
}

function Initialize-GrlLogging {
    param(
        [string]$RootPath,
        [string]$RunId = (Get-Date -Format 'yyyyMMdd-HHmmss')
    )

    $logDirectory = Join-Path $env:ProgramData 'GameRuntimeLibrary\Logs'
    try {
        if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        }
        $script:LogPath = Join-Path $logDirectory "GameRuntimeLibrary-$RunId.log"
        $newLine = [Environment]::NewLine
        $header = "GameRuntimeLibrary 日志$newLine开始时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')$newLine根目录：$RootPath$newLine"
        [System.IO.File]::AppendAllText($script:LogPath, $header, [System.Text.Encoding]::UTF8)
        # 先创建本次日志再轮转，保证目录中保留的日志（含本次）不超过 30 份。
        Remove-GrlOldLogFiles -Directory $logDirectory -Keep 30
    }
    catch {
        $script:LogPath = $null
        Write-Warning "无法创建程序日志目录，本次仅输出到控制台：$($_.Exception.Message)"
    }
}

function Get-GrlLogPath {
    return $script:LogPath
}

function Complete-GrlLogging {
    param(
        [int]$ExitCode = 0
    )

    if ([string]::IsNullOrWhiteSpace($script:LogPath)) {
        return
    }
    $newLine = [Environment]::NewLine
    $footer = "结束时间：$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')$newLine退出码：$ExitCode$newLine"
    try {
        [System.IO.File]::AppendAllText($script:LogPath, $footer, [System.Text.Encoding]::UTF8)
    }
    catch {
        Write-Warning "写入日志结束信息失败：$($_.Exception.Message)"
    }
}

function Write-GrlLog {
    param(
        [ValidateSet('信息', '警告', '错误', '成功', '调试')]
        [string]$Level,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$Component = 'Core'
    )

    if (-not [string]::IsNullOrWhiteSpace($script:LogPath)) {
        $line = "[{0}][{1}][{2}] {3}{4}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Component, $Message, [Environment]::NewLine
        try {
            [System.IO.File]::AppendAllText($script:LogPath, $line, [System.Text.Encoding]::UTF8)
        }
        catch {
            Write-Warning "写入日志失败：$($_.Exception.Message)"
        }
    }
}

function Write-GrlMessage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('信息', '警告', '错误', '成功', '调试')]
        [string]$Level = '信息',
        [string]$Component = 'Core',
        [switch]$NoNewline
    )

    $colors = @{
        '信息' = 'Gray'
        '警告' = 'Yellow'
        '错误' = 'Red'
        '成功' = 'Green'
        '调试' = 'DarkGray'
    }
    $parameters = @{
        Object = $Message
        ForegroundColor = $colors[$Level]
        NoNewline = $NoNewline
    }
    Write-Host @parameters
    Write-GrlLog -Level $Level -Message $Message -Component $Component
}

function Test-GrlAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-GrlPendingReboot {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            return $true
        }
    }

    $sessionManager = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
    if ($null -ne $sessionManager -and $null -ne $sessionManager.PendingFileRenameOperations -and $sessionManager.PendingFileRenameOperations.Count -gt 0) {
        return $true
    }
    return $false
}

function Test-GrlChildPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ParentPath,
        [Parameter(Mandatory = $true)]
        [string]$ChildPath
    )

    $parent = [System.IO.Path]::GetFullPath($ParentPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $child = [System.IO.Path]::GetFullPath($ChildPath)
    $prefix = $parent + [System.IO.Path]::DirectorySeparatorChar
    return $child.Equals($parent, [System.StringComparison]::OrdinalIgnoreCase) -or $child.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-GrlChildPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ParentPath,
        [Parameter(Mandatory = $true)]
        [string]$ChildPath
    )

    if (-not (Test-GrlChildPath -ParentPath $ParentPath -ChildPath $ChildPath)) {
        throw "路径超出允许范围：$ChildPath"
    }
}

function Get-GrlFileSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-GrlDisplayWidth {
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    $width = 0
    foreach ($character in $Text.ToCharArray()) {
        $code = [int]$character
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($character)
        if ($category -in @(
            [System.Globalization.UnicodeCategory]::NonSpacingMark,
            [System.Globalization.UnicodeCategory]::EnclosingMark,
            [System.Globalization.UnicodeCategory]::Format
        )) {
            continue
        }
        if (($code -ge 0x1100 -and $code -le 0x115F) -or
            ($code -ge 0x2E80 -and $code -le 0xA4CF) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE10 -and $code -le 0xFE6F) -or
            ($code -ge 0xFF01 -and $code -le 0xFF60) -or
            ($code -ge 0xFFE0 -and $code -le 0xFFE6)) {
            $width += 2
        }
        else {
            $width++
        }
    }
    return $width
}

function Format-GrlDisplayCell {
    param(
        [AllowNull()]
        [object]$Value,
        [Parameter(Mandatory = $true)]
        [int]$Width,
        [ValidateSet('Left', 'Right', 'Center')]
        [string]$Alignment = 'Left'
    )

    if ($Width -lt 1) {
        throw '显示单元格宽度必须大于 0。'
    }
    $text = if ($null -eq $Value) { '' } else { ([string]$Value) -replace '[\r\n]+', ' ' }
    $textWidth = Get-GrlDisplayWidth -Text $text
    if ($textWidth -gt $Width) {
        $target = $Width
        if ($Width -ge 4) {
            $target = $Width - 3
        }
        while ($text.Length -gt 0 -and (Get-GrlDisplayWidth -Text $text) -gt $target) {
            $text = $text.Substring(0, $text.Length - 1)
        }
        if ($Width -ge 4) {
            $text += '...'
        }
        $textWidth = Get-GrlDisplayWidth -Text $text
    }
    $padding = [Math]::Max(0, $Width - $textWidth)
    switch ($Alignment) {
        'Right' {
            return ((' ' * $padding) + $text)
        }
        'Center' {
            $left = [Math]::Floor($padding / 2)
            return ((' ' * $left) + $text + (' ' * ($padding - $left)))
        }
        default {
            return ($text + (' ' * $padding))
        }
    }
}

function Get-GrlConsoleWidth {
    $width = 120
    try {
        $bufferWidth = [int]$Host.UI.RawUI.BufferSize.Width
        if ($bufferWidth -ge 80) {
            $width = $bufferWidth
        }
    }
    catch {
        Write-GrlLog -Level '调试' -Message "无法读取控制台宽度：$($_.Exception.Message)" -Component 'Console'
    }
    return [Math]::Min(140, [Math]::Max(80, $width))
}

function ConvertTo-GrlVersion {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    if ($Value -is [version]) {
        return $Value
    }

    $text = [string]$Value
    $match = [regex]::Match($text, '\d+(?:\.\d+){0,3}')
    if (-not $match.Success) {
        return $null
    }
    $parts = $match.Value.Split('.')
    while ($parts.Count -lt 4) {
        $parts += '0'
    }
    try {
        return [version]($parts -join '.')
    }
    catch {
        return $null
    }
}

function Test-GrlVersionAtLeast {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Actual,
        [Parameter(Mandatory = $true)]
        [string]$Minimum
    )

    $actualVersion = ConvertTo-GrlVersion -Value $Actual
    $minimumVersion = ConvertTo-GrlVersion -Value $Minimum
    if ($null -eq $actualVersion -or $null -eq $minimumVersion) {
        return $false
    }
    return $actualVersion -ge $minimumVersion
}

function Get-GrlAuthenticodeState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    $subject = ''
    if ($null -ne $signature.SignerCertificate) {
        $subject = $signature.SignerCertificate.Subject
    }
    return [pscustomobject]@{
        Status = [string]$signature.Status
        Subject = $subject
        IsValid = $signature.Status -eq 'Valid'
    }
}

function Assert-GrlPublisher {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$PublisherContains
    )

    $state = Get-GrlAuthenticodeState -Path $Path
    if (-not $state.IsValid) {
        throw (New-GrlException -Message "数字签名无效：$Path，状态 $($state.Status)" -ExitCode 20 -Category 'Signature')
    }
    if ($state.Subject.IndexOf($PublisherContains, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw (New-GrlException -Message "签名发布者不匹配：$Path，实际 $($state.Subject)" -ExitCode 20 -Category 'Signature')
    }
    return $state
}

function New-GrlTempDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Purpose
    )

    $safeName = $Purpose -replace '[^a-zA-Z0-9_-]', '_'
    $path = Join-Path $script:TempRoot ("{0}-{1}" -f $safeName, [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function Remove-GrlTempDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    Assert-GrlChildPath -ParentPath $script:TempRoot -ChildPath $Path
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Format-GrlByteSize {
    param(
        [Parameter(Mandatory = $true)]
        [long]$Bytes
    )

    if ($Bytes -lt 0) {
        $Bytes = 0
    }
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Bytes -ge 1073741824) {
        return [string]::Format($culture, '{0:N2} GB', ($Bytes / 1073741824))
    }
    if ($Bytes -ge 1048576) {
        return [string]::Format($culture, '{0:N1} MB', ($Bytes / 1048576))
    }
    if ($Bytes -ge 1024) {
        return [string]::Format($culture, '{0:N1} KB', ($Bytes / 1024))
    }
    return ('{0} B' -f $Bytes)
}

function Format-GrlDuration {
    param(
        [Parameter(Mandatory = $true)]
        [TimeSpan]$Duration
    )

    if ($Duration.TotalHours -ge 1) {
        return ('{0:hh\:mm\:ss}' -f $Duration)
    }
    return ('{0:mm\:ss}' -f $Duration)
}

function Test-GrlProgressSupported {
    if ($null -ne $script:ProgressSupported) {
        return [bool]$script:ProgressSupported
    }
    $supported = $true
    try {
        if ([Console]::IsOutputRedirected) {
            $supported = $false
        }
    }
    catch {
        $supported = $false
    }
    $script:ProgressSupported = $supported
    return $supported
}

function Write-GrlProgress {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Activity,
        [string]$Status = '',
        [int]$Percent = -1,
        [switch]$Complete,
        [switch]$Force
    )

    if (-not $Force -and -not (Test-GrlProgressSupported)) {
        return
    }

    $line = $Activity
    if ($Percent -ge 0) {
        $clamped = [Math]::Min(100, [Math]::Max(0, $Percent))
        $barWidth = 20
        $filled = [int][Math]::Floor($clamped * $barWidth / 100)
        $bar = ('#' * $filled) + ('-' * ($barWidth - $filled))
        $line = '{0} [{1}] {2,3}%' -f $Activity, $bar, $clamped
    }
    if (-not [string]::IsNullOrWhiteSpace($Status)) {
        $line = $line + ' ' + $Status
    }

    # 统一填充/截断到控制台宽度减一，既能清掉上一次更长的内容，也不会因补空格而换行。
    $consoleWidth = Get-GrlConsoleWidth
    $line = Format-GrlDisplayCell -Value $line -Width ($consoleWidth - 1)

    if ($Complete) {
        Write-Host ("`r" + $line)
        return
    }
    Write-Host ("`r" + $line) -NoNewline
}

function Send-GrlCompletionNotification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [switch]$Success,
        [switch]$NonInteractive,
        [int]$TimeoutSeconds = 15
    )

    # 非交互运行（CI、远程会话、-NonInteractive）不弹窗、不响铃。
    if ($NonInteractive -or -not [Environment]::UserInteractive) {
        return
    }

    try {
        if ($Success) {
            [Console]::Beep(880, 120)
            Start-Sleep -Milliseconds 80
            [Console]::Beep(1175, 160)
        }
        else {
            [Console]::Beep(520, 250)
            Start-Sleep -Milliseconds 80
            [Console]::Beep(392, 350)
        }
    }
    catch {
        Write-GrlLog -Level '调试' -Message "无法播放完成提示音：$($_.Exception.Message)" -Component 'Notify'
    }

    try {
        $Host.UI.RawUI.WindowTitle = $Title
    }
    catch {
        Write-GrlLog -Level '调试' -Message "无法设置窗口标题：$($_.Exception.Message)" -Component 'Notify'
    }

    if ($env:GRL_NO_POPUP -eq '1') {
        return
    }
    if ($Message.Length -gt 500) {
        $Message = $Message.Substring(0, 497) + '...'
    }
    try {
        $shell = New-Object -ComObject WScript.Shell
        $icon = if ($Success) { 64 } else { 48 }
        $null = $shell.Popup($Message, $TimeoutSeconds, $Title, $icon)
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
    catch {
        Write-GrlLog -Level '调试' -Message "无法显示完成提示框：$($_.Exception.Message)" -Component 'Notify'
    }
}

function New-GrlResult {
    param(
        [int]$ExitCode = 0,
        [string]$Message = '',
        [object[]]$Items = @()
    )

    return [pscustomobject]@{
        ExitCode = $ExitCode
        Message = $Message
        Items = $Items
    }
}

function Get-GrlTestTempRoot {
    return $script:TempRoot
}

Export-ModuleMember -Function Get-GrlExitCode, New-GrlException, Get-GrlExceptionExitCode, Remove-GrlOldLogFiles, Get-GrlLogPath, Complete-GrlLogging, Initialize-GrlLogging, Write-GrlLog, Write-GrlMessage, Test-GrlAdministrator, Test-GrlPendingReboot, Test-GrlChildPath, Assert-GrlChildPath, Get-GrlFileSha256, Get-GrlDisplayWidth, Format-GrlDisplayCell, Get-GrlConsoleWidth, ConvertTo-GrlVersion, Test-GrlVersionAtLeast, Get-GrlAuthenticodeState, Assert-GrlPublisher, Format-GrlByteSize, Format-GrlDuration, Test-GrlProgressSupported, Write-GrlProgress, Send-GrlCompletionNotification, New-GrlTempDirectory, Remove-GrlTempDirectory, New-GrlResult, Get-GrlTestTempRoot
