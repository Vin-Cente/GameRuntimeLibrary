$ErrorActionPreference = 'Stop'

$script:UninstallEntryCache = $null
$script:DllPresenceCache = @{}

function Get-GrlRegistryView {
    param(
        [string]$Name = 'Default'
    )

    if ($Name -eq 'Registry32') {
        return [Microsoft.Win32.RegistryView]::Registry32
    }
    if ($Name -eq 'Registry64') {
        return [Microsoft.Win32.RegistryView]::Registry64
    }
    if ([Environment]::Is64BitOperatingSystem) {
        return [Microsoft.Win32.RegistryView]::Registry64
    }
    return [Microsoft.Win32.RegistryView]::Registry32
}

function Get-GrlRegistryValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [string]$RegistryView = 'Default'
    )

    $baseKey = $null
    $subKey = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, (Get-GrlRegistryView -Name $RegistryView))
        $subKey = $baseKey.OpenSubKey($Key, $false)
        if ($null -eq $subKey) {
            return [pscustomobject]@{ Exists = $false; Value = $null }
        }
        $value = $subKey.GetValue($Name, $null)
        return [pscustomobject]@{ Exists = ($null -ne $value); Value = $value }
    }
    catch {
        return [pscustomobject]@{ Exists = $false; Value = $null; Error = $_.Exception.Message }
    }
    finally {
        if ($null -ne $subKey) {
            $subKey.Dispose()
        }
        if ($null -ne $baseKey) {
            $baseKey.Dispose()
        }
    }
}

function Get-GrlUninstallEntries {
    param(
        [switch]$Refresh
    )

    if ($null -ne $script:UninstallEntryCache -and -not $Refresh) {
        return $script:UninstallEntryCache
    }

    $entries = @()
    $locations = @(
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry64; Architecture = 'x64' },
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry32; Architecture = 'x86' },
        @{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser; View = [Microsoft.Win32.RegistryView]::Default; Architecture = 'user' }
    )
    $path = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'

    foreach ($location in $locations) {
        if (-not [Environment]::Is64BitOperatingSystem -and $location.View -eq [Microsoft.Win32.RegistryView]::Registry64) {
            continue
        }
        $baseKey = $null
        $uninstallKey = $null
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey($location.Hive, $location.View)
            $uninstallKey = $baseKey.OpenSubKey($path, $false)
            if ($null -eq $uninstallKey) {
                continue
            }
            foreach ($subKeyName in $uninstallKey.GetSubKeyNames()) {
                $subKey = $null
                try {
                    $subKey = $uninstallKey.OpenSubKey($subKeyName, $false)
                    if ($null -eq $subKey) {
                        continue
                    }
                    $displayName = [string]$subKey.GetValue('DisplayName', '')
                    if ([string]::IsNullOrWhiteSpace($displayName)) {
                        continue
                    }
                    $entries += [pscustomobject]@{
                        DisplayName = $displayName
                        DisplayVersion = [string]$subKey.GetValue('DisplayVersion', '')
                        Architecture = $location.Architecture
                        KeyName = $subKeyName
                    }
                }
                finally {
                    if ($null -ne $subKey) {
                        $subKey.Dispose()
                    }
                }
            }
        }
        catch {
            Write-GrlLog -Level '警告' -Message "读取卸载信息失败：$($_.Exception.Message)" -Component 'Detection'
        }
        finally {
            if ($null -ne $uninstallKey) {
                $uninstallKey.Dispose()
            }
            if ($null -ne $baseKey) {
                $baseKey.Dispose()
            }
        }
    }

    $script:UninstallEntryCache = @($entries | Sort-Object DisplayName, DisplayVersion -Unique)
    return $script:UninstallEntryCache
}

function Clear-GrlDetectionCache {
    $script:UninstallEntryCache = $null
    $script:DllPresenceCache = @{}
}

function Select-GrlUninstallEntry {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Entries,
        [Parameter(Mandatory = $true)]
        [object]$Detection
    )

    $matchText = [string]$Detection.displayNameContains
    $matched = @()
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) {
            continue
        }
        $displayName = [string]$entry.DisplayName
        if ([string]::IsNullOrWhiteSpace($matchText)) {
            $matched += $entry
            continue
        }
        if ($displayName.IndexOf($matchText, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $matched += $entry
        }
    }

    $hint = [string]$Detection.architectureHint
    if (-not [string]::IsNullOrWhiteSpace($hint)) {
        $hint = $hint.Trim().ToLowerInvariant()
        if ($hint -eq 'x64' -or $hint -eq 'x86') {
            $byArchitecture = @()
            foreach ($entry in $matched) {
                $entryArchitecture = [string]$entry.Architecture
                if ($entryArchitecture.Equals($hint, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $byArchitecture += $entry
                }
            }
            if ($byArchitecture.Count -gt 0) {
                $matched = $byArchitecture
            }
            else {
                $pattern = '(?i)x64|64-bit|AMD64'
                $fallback = @()
                foreach ($entry in $matched) {
                    $displayName = [string]$entry.DisplayName
                    $isX64Name = $displayName -match $pattern
                    if (($hint -eq 'x64' -and $isX64Name) -or ($hint -eq 'x86' -and -not $isX64Name)) {
                        $fallback += $entry
                    }
                }
                $matched = $fallback
            }
        }
    }

    $minimumVersion = [string]$Detection.minimumVersion
    $valid = @()
    foreach ($entry in $matched) {
        if ([string]::IsNullOrWhiteSpace($minimumVersion) -or
            (Test-GrlVersionAtLeast -Actual $entry.DisplayVersion -Minimum $minimumVersion)) {
            $valid += $entry
        }
    }
    if ($valid.Count -eq 0) {
        return $null
    }

    $sorted = @($valid | Sort-Object -Property @{ Expression = { ConvertTo-GrlVersion -Value $_.DisplayVersion } } -Descending)
    return $sorted[0]
}

function Test-GrlNumericOrVersionMinimum {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Actual,
        [Parameter(Mandatory = $true)]
        [object]$Minimum
    )

    $actualText = [string]$Actual
    $minimumText = [string]$Minimum
    if ($actualText -match '^\d+$' -and $minimumText -match '^\d+$') {
        return [long]$actualText -ge [long]$minimumText
    }
    return Test-GrlVersionAtLeast -Actual $actualText -Minimum $minimumText
}

function Test-GrlDetection {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Detection,
        [string]$RegistryView = 'Default'
    )

    switch ($Detection.type) {
        'RegistryValue' {
            $view = $RegistryView
            if (-not [string]::IsNullOrWhiteSpace([string]$Detection.registryView)) {
                $view = [string]$Detection.registryView
            }
            $result = Get-GrlRegistryValue -Key $Detection.key -Name $Detection.name -RegistryView $view
            if ($result.Exists -and [string]$result.Value -eq [string]$Detection.equals) {
                return [pscustomobject]@{ State = 'Installed'; Detail = "注册表值 $($Detection.name)=$($result.Value)" }
            }
            return [pscustomobject]@{ State = 'Missing'; Detail = "未找到注册表值 $($Detection.name)" }
        }
        'RegistryMinimum' {
            $view = $RegistryView
            if (-not [string]::IsNullOrWhiteSpace([string]$Detection.registryView)) {
                $view = [string]$Detection.registryView
            }
            $result = Get-GrlRegistryValue -Key $Detection.key -Name $Detection.name -RegistryView $view
            if (-not $result.Exists) {
                return [pscustomobject]@{ State = 'Missing'; Detail = "未找到注册表值 $($Detection.name)" }
            }
            if (Test-GrlNumericOrVersionMinimum -Actual $result.Value -Minimum $Detection.minimum) {
                return [pscustomobject]@{ State = 'Installed'; Detail = "检测值 $($result.Value)" }
            }
            return [pscustomobject]@{ State = 'Missing'; Detail = "检测值 $($result.Value) 低于 $($Detection.minimum)" }
        }
        'UninstallEntry' {
            $best = Select-GrlUninstallEntry -Entries @(Get-GrlUninstallEntries) -Detection $Detection
            if ($null -ne $best) {
                return [pscustomobject]@{ State = 'Installed'; Detail = "$($best.DisplayName) $($best.DisplayVersion)" }
            }
            return [pscustomobject]@{ State = 'Missing'; Detail = "未找到 $($Detection.displayNameContains)" }
        }
        'FileAny' {
            foreach ($file in @($Detection.files)) {
                $expanded = [Environment]::ExpandEnvironmentVariables([string]$file)
                if (Test-Path -LiteralPath $expanded -PathType Leaf) {
                    return [pscustomobject]@{ State = 'Installed'; Detail = $expanded }
                }
            }
            return [pscustomobject]@{ State = 'Missing'; Detail = '未找到预期运行库文件' }
        }
        'WindowsFeature' {
            if (-not (Test-GrlAdministrator)) {
                return [pscustomobject]@{ State = 'Unknown'; Detail = '需要管理员权限检查 Windows 功能' }
            }
            try {
                $feature = Get-WindowsOptionalFeature -Online -FeatureName $Detection.featureName -ErrorAction Stop
                if ($feature.State -eq 'Enabled') {
                    return [pscustomobject]@{ State = 'Installed'; Detail = 'Windows 功能已启用' }
                }
                return [pscustomobject]@{ State = 'Missing'; Detail = "Windows 功能状态：$($feature.State)" }
            }
            catch {
                return [pscustomobject]@{ State = 'Unknown'; Detail = $_.Exception.Message }
            }
        }
        default {
            return [pscustomobject]@{ State = 'Unknown'; Detail = "未知检测类型：$($Detection.type)" }
        }
    }
}

function Get-GrlComponentState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Component,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition
    )

    $states = @()
    if ($null -ne $Component.detection) {
        $componentResult = Test-GrlDetection -Detection $Component.detection -RegistryView 'Default'
        $states += [pscustomobject]@{
            Name = 'Component'
            State = $componentResult.State
            Detail = $componentResult.Detail
        }
    }
    foreach ($package in @(Get-GrlApplicablePackages -Component $Component -ProfileDefinition $ProfileDefinition)) {
        if ($null -eq $package.detection) {
            continue
        }
        $packageResult = Test-GrlDetection -Detection $package.detection -RegistryView 'Default'
        $states += [pscustomobject]@{
            Name = $package.id
            State = $packageResult.State
            Detail = $packageResult.Detail
        }
    }

    $overall = 'Unknown'
    if ($states.Count -gt 0) {
        if (@($states | Where-Object { $_.State -ne 'Installed' }).Count -eq 0) {
            $overall = 'Installed'
        }
        elseif (@($states | Where-Object { $_.State -eq 'Missing' }).Count -gt 0) {
            $overall = 'Missing'
        }
        else {
            $overall = 'Unknown'
        }
    }

    $installedCount = @($states | Where-Object { $_.State -eq 'Installed' }).Count
    $missingStates = @($states | Where-Object { $_.State -eq 'Missing' })
    $unknownStates = @($states | Where-Object { $_.State -eq 'Unknown' })
    if ($overall -eq 'Installed') {
        $summary = (Get-GrlText -Key 'status.installedSummary') -f $installedCount, $states.Count
    }
    elseif ($missingStates.Count -gt 0) {
        $missingNames = @($missingStates | ForEach-Object {
            if ($_.Name -match '_(x86|x64)$') { $Matches[1] } else { Get-GrlText -Key 'status.mainPackage' }
        }) -join '、'
        $summary = (Get-GrlText -Key 'status.missingSummary') -f $missingStates.Count, $missingNames
    }
    elseif ($unknownStates.Count -gt 0) {
        $summary = (Get-GrlText -Key 'status.unknownSummary') -f $unknownStates.Count
    }
    else {
        $summary = Get-GrlText -Key 'status.noSummary'
    }

    return [pscustomobject]@{
        Id = $Component.id
        DisplayName = Get-GrlComponentName -Component $Component
        Tier = $Component.tier
        Order = $Component.order
        State = $overall
        Summary = $summary
        PackageStates = $states
    }
}

function Get-GrlAllComponentStates {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Components,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition
    )

    return @($Components | ForEach-Object {
        Get-GrlComponentState -Component $_ -ProfileDefinition $ProfileDefinition
    } | Sort-Object -Property Order)
}

function Write-GrlComponentStates {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$States
    )

    $colorMap = @{
        Installed = 'Green'
        Missing = 'Yellow'
        Unknown = 'DarkYellow'
    }
    $labelMap = @{
        Installed = Get-GrlText -Key 'status.installed'
        Missing = Get-GrlText -Key 'status.missing'
        Unknown = Get-GrlText -Key 'status.unknown'
    }

    $consoleWidth = Get-GrlConsoleWidth
    $indexWidth = 4
    $nameWidth = 32
    $statusWidth = 8
    foreach ($label in $labelMap.Values) {
        $statusWidth = [Math]::Max($statusWidth, (Get-GrlDisplayWidth -Text $label))
    }
    $statusWidth += 1
    $gap = 2
    $summaryWidth = [Math]::Max(12, $consoleWidth - $indexWidth - $nameWidth - $statusWidth - ($gap * 3))

    Write-Host ''
    $header = (Format-GrlDisplayCell -Value (Get-GrlText -Key 'status.index') -Width $indexWidth) + (' ' * $gap) +
        (Format-GrlDisplayCell -Value (Get-GrlText -Key 'status.component') -Width $nameWidth) + (' ' * $gap) +
        (Format-GrlDisplayCell -Value (Get-GrlText -Key 'status.state') -Width $statusWidth) + (' ' * $gap) +
        (Format-GrlDisplayCell -Value (Get-GrlText -Key 'status.summary') -Width $summaryWidth)
    Write-Host $header -ForegroundColor Cyan
    Write-Host ('-' * $consoleWidth) -ForegroundColor DarkGray
    $index = 1
    foreach ($state in $States) {
        $summary = if ($null -ne $state.PSObject.Properties['Summary']) { $state.Summary } else { Get-GrlText -Key 'status.noSummary' }
        Write-Host (Format-GrlDisplayCell -Value $index -Width $indexWidth -Alignment Right) -NoNewline
        Write-Host (' ' * $gap) -NoNewline
        Write-Host (Format-GrlDisplayCell -Value $state.DisplayName -Width $nameWidth) -NoNewline
        Write-Host (' ' * $gap) -NoNewline
        Write-Host (Format-GrlDisplayCell -Value $labelMap[$state.State] -Width $statusWidth) -ForegroundColor $colorMap[$state.State] -NoNewline
        Write-Host (' ' * $gap) -NoNewline
        Write-Host (Format-GrlDisplayCell -Value $summary -Width $summaryWidth)
        $index++
    }
}

function Get-GrlDllSearchDirectories {
    $directories = @()
    $systemRoot = [Environment]::ExpandEnvironmentVariables('%SystemRoot%')
    if ([string]::IsNullOrWhiteSpace($systemRoot)) {
        $systemRoot = $env:windir
    }
    if (-not [string]::IsNullOrWhiteSpace($systemRoot)) {
        $directories += (Join-Path $systemRoot 'System32')
        if ([Environment]::Is64BitOperatingSystem) {
            $directories += (Join-Path $systemRoot 'SysWOW64')
        }
        foreach ($frameworkFolder in @('Framework', 'Framework64')) {
            $frameworkRoot = Join-Path $systemRoot ('Microsoft.NET\' + $frameworkFolder)
            foreach ($frameworkVersion in @('v2.0.50727', 'v3.5', 'v4.0.30319')) {
                $directories += (Join-Path $frameworkRoot $frameworkVersion)
            }
        }
    }
    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $xnaRedist = Join-Path (Join-Path $programFilesX86 'Microsoft XNA\XNA Game Studio\v4.0') 'Redist'
        $directories += $xnaRedist
    }

    $existing = @()
    foreach ($directory in $directories) {
        if (Test-Path -LiteralPath $directory -PathType Container) {
            $existing += $directory
        }
    }
    return $existing
}

function Test-GrlDllPresence {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$FileName
    )

    $name = [string]$FileName
    if ([string]::IsNullOrWhiteSpace($name) -or [System.IO.Path]::GetFileName($name) -ne $name) {
        throw "DLL 文件名无效：$FileName"
    }

    $cacheKey = $name.ToLowerInvariant()
    if ($script:DllPresenceCache.ContainsKey($cacheKey)) {
        return $script:DllPresenceCache[$cacheKey]
    }

    $searched = 0
    $foundPath = ''
    foreach ($directory in @(Get-GrlDllSearchDirectories)) {
        $searched++
        $candidate = Join-Path $directory $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $foundPath = $candidate
            break
        }
    }

    $result = [pscustomobject]@{
        Present = -not [string]::IsNullOrWhiteSpace($foundPath)
        Path = [string]$foundPath
        Searched = [int]$searched
    }
    $script:DllPresenceCache[$cacheKey] = $result
    return $result
}

function Get-GrlDllStates {
    param(
        [Parameter(Mandatory = $true)]
        [object]$DllMap,
        [Parameter(Mandatory = $true)]
        [object[]]$Components,
        [Parameter(Mandatory = $true)]
        [object[]]$ComponentStates
    )

    $componentById = @{}
    foreach ($component in $Components) {
        $componentById[$component.id] = $component
    }
    $stateById = @{}
    foreach ($state in $ComponentStates) {
        $stateById[$state.Id] = $state
    }

    $rows = @()
    foreach ($item in @($DllMap.items | Sort-Object {
        if ($componentById.ContainsKey($_.componentId)) { $componentById[$_.componentId].order } else { 9999 }
    })) {
        if (-not $componentById.ContainsKey($item.componentId)) {
            continue
        }
        $state = $stateById[$item.componentId]
        foreach ($file in @($item.files)) {
            $presence = Test-GrlDllPresence -FileName ([string]$file)
            $rows += [pscustomobject]@{
                Order = $componentById[$item.componentId].order
                ComponentId = $item.componentId
                ComponentName = Get-GrlComponentName -Component $componentById[$item.componentId]
                State = $state.State
                File = [string]$file
                Presence = [bool]$presence.Present
                PresencePath = [string]$presence.Path
            }
        }
    }
    return @($rows | Sort-Object Order, File)
}

function Write-GrlDllStates {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$States,
        [string]$Note
    )

    $colorMap = @{ Installed = 'Green'; Missing = 'Yellow'; Unknown = 'DarkYellow' }
    $labelMap = @{
        Installed = Get-GrlText -Key 'status.installed'
        Missing = Get-GrlText -Key 'status.missing'
        Unknown = Get-GrlText -Key 'status.unknown'
    }
    $presenceLabelMap = @{
        $true = Get-GrlText -Key 'status.fileFound'
        $false = Get-GrlText -Key 'status.fileMissing'
    }
    $presenceColorMap = @{
        $true = 'Green'
        $false = 'DarkYellow'
    }
    $consoleWidth = Get-GrlConsoleWidth
    $indexWidth = 4
    $nameWidth = 32
    $statusWidth = 8
    foreach ($label in $labelMap.Values) {
        $statusWidth = [Math]::Max($statusWidth, (Get-GrlDisplayWidth -Text $label))
    }
    $statusWidth += 1
    $presenceWidth = 10
    $gap = 2
    $fileWidth = [Math]::Max(12, $consoleWidth - $indexWidth - $nameWidth - $statusWidth - $presenceWidth - ($gap * 4))

    Write-Host ''
    if (-not [string]::IsNullOrWhiteSpace($Note)) {
        Write-Host $Note -ForegroundColor DarkGray
        Write-Host ''
    }
    $header = (Format-GrlDisplayCell -Value (Get-GrlText -Key 'status.index') -Width $indexWidth) + (' ' * $gap) +
        (Format-GrlDisplayCell -Value (Get-GrlText -Key 'status.component') -Width $nameWidth) + (' ' * $gap) +
        (Format-GrlDisplayCell -Value (Get-GrlText -Key 'status.state') -Width $statusWidth) + (' ' * $gap) +
        (Format-GrlDisplayCell -Value (Get-GrlText -Key 'status.presence') -Width $presenceWidth) + (' ' * $gap) +
        (Format-GrlDisplayCell -Value (Get-GrlText -Key 'status.dll') -Width $fileWidth)
    Write-Host $header -ForegroundColor Cyan
    Write-Host ('-' * $consoleWidth) -ForegroundColor DarkGray

    $index = 1
    foreach ($state in $States) {
        $present = $false
        if ($null -ne $state.PSObject.Properties['Presence']) {
            $present = [bool]$state.Presence
        }
        Write-Host (Format-GrlDisplayCell -Value $index -Width $indexWidth -Alignment Right) -NoNewline
        Write-Host (' ' * $gap) -NoNewline
        Write-Host (Format-GrlDisplayCell -Value $state.ComponentName -Width $nameWidth) -NoNewline
        Write-Host (' ' * $gap) -NoNewline
        Write-Host (Format-GrlDisplayCell -Value $labelMap[$state.State] -Width $statusWidth) -ForegroundColor $colorMap[$state.State] -NoNewline
        Write-Host (' ' * $gap) -NoNewline
        Write-Host (Format-GrlDisplayCell -Value $presenceLabelMap[$present] -Width $presenceWidth) -ForegroundColor $presenceColorMap[$present] -NoNewline
        Write-Host (' ' * $gap) -NoNewline
        Write-Host (Format-GrlDisplayCell -Value $state.File -Width $fileWidth)
        $index++
    }
}

Export-ModuleMember -Function Get-GrlRegistryView, Get-GrlRegistryValue, Get-GrlUninstallEntries, Clear-GrlDetectionCache, Test-GrlNumericOrVersionMinimum, Select-GrlUninstallEntry, Test-GrlDetection, Get-GrlComponentState, Get-GrlAllComponentStates, Write-GrlComponentStates, Test-GrlDllPresence, Get-GrlDllStates, Write-GrlDllStates
