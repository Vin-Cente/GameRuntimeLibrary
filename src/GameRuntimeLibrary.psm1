$moduleRoot = $PSScriptRoot
Import-Module -Name (Join-Path $moduleRoot 'GameRuntimeLibrary.Core.psm1') -Force -Global
Import-Module -Name (Join-Path $moduleRoot 'GameRuntimeLibrary.Localization.psm1') -Force -Global
Import-Module -Name (Join-Path $moduleRoot 'GameRuntimeLibrary.Catalog.psm1') -Force -Global
Import-Module -Name (Join-Path $moduleRoot 'GameRuntimeLibrary.Platform.psm1') -Force -Global
Import-Module -Name (Join-Path $moduleRoot 'GameRuntimeLibrary.Detection.psm1') -Force -Global
Import-Module -Name (Join-Path $moduleRoot 'GameRuntimeLibrary.Download.psm1') -Force -Global
Import-Module -Name (Join-Path $moduleRoot 'GameRuntimeLibrary.Installer.psm1') -Force -Global
Import-Module -Name (Join-Path $moduleRoot 'GameRuntimeLibrary.Offline.psm1') -Force -Global

function Get-GrlBuildDisplayText {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SystemInfo
    )

    $buildText = [string]$SystemInfo.Build
    if ($null -ne $SystemInfo.PSObject.Properties['UpdateBuildRevision']) {
        $revision = [int]$SystemInfo.UpdateBuildRevision
        if ($revision -gt 0) {
            $buildText = '{0}.{1}' -f $buildText, $revision
        }
    }
    if ($null -ne $SystemInfo.PSObject.Properties['DisplayVersion']) {
        $displayVersion = [string]$SystemInfo.DisplayVersion
        if (-not [string]::IsNullOrWhiteSpace($displayVersion)) {
            $buildText = '{0} ({1})' -f $buildText, $displayVersion
        }
    }
    return $buildText
}

function Write-GrlHeader {
    param(
        [Parameter(Mandatory = $true)]
        [object]$SystemInfo,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition,
        [string]$LogPath
    )
    Clear-Host
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host (' ' * 12 + (Get-GrlText -Key 'header.title')) -ForegroundColor Cyan
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ((Get-GrlText -Key 'header.system') + ': ' + $SystemInfo.Caption + ' Build ' + (Get-GrlBuildDisplayText -SystemInfo $SystemInfo) + ' ' + $SystemInfo.Architecture)
    Write-Host ((Get-GrlText -Key 'header.profile') + ': ' + $ProfileDefinition.displayName)
    $permissionText = if ($SystemInfo.IsAdministrator) { Get-GrlText -Key 'header.administrator' } else { Get-GrlText -Key 'header.standardUser' }
    Write-Host ((Get-GrlText -Key 'header.permission') + ': ' + $permissionText)
    $rebootText = if ($SystemInfo.PendingReboot) { Get-GrlText -Key 'header.yes' } else { Get-GrlText -Key 'header.no' }
    Write-Host ((Get-GrlText -Key 'header.pendingReboot') + ': ' + $rebootText)
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        Write-Host ((Get-GrlText -Key 'header.log') + ': ' + $LogPath)
    }
    if ($script:GameRuntimeDevelopmentBuild) {
        Write-Host (Get-GrlText -Key 'header.channelDevelopment') -ForegroundColor Yellow
    }
    Write-Host ''
}

function Show-GrlComponentMenu {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Components
    )
    Write-Host ''
    Write-Host ((Get-GrlText -Key 'common.availableComponents') + ':') -ForegroundColor Cyan
    $index = 1
    foreach ($component in $Components) {
        $tier = if ($component.tier -eq 'Core') { Get-GrlText -Key 'common.componentTierCore' } else { Get-GrlText -Key 'common.componentTierLegacy' }
        Write-Host ('{0,3}. [{1}] {2} ({3})' -f $index, $tier, (Get-GrlComponentName -Component $component), $component.id)
        $index++
    }
}

function Get-GrlRecommendedComponentIds {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Components
    )

    return @($Components | Where-Object { $_.tier -eq 'Core' } | ForEach-Object { [string]$_.id })
}

function Show-GrlComponentSelection {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Components,
        [Parameter(Mandatory = $true)]
        [hashtable]$Selected,
        [string]$Message = ''
    )

    try {
        Clear-Host
    }
    catch {
        # 非控制台宿主（如输出被重定向）下无法清屏时继续用追加输出。
        Write-GrlLog -Level '调试' -Message "无法清屏：$($_.Exception.Message)" -Component 'Menu'
    }
    $width = [Math]::Min(78, (Get-GrlConsoleWidth))
    Write-Host ('=' * $width) -ForegroundColor Cyan
    Write-Host (Get-GrlText -Key 'componentSelect.title') -ForegroundColor Cyan
    Write-Host ('=' * $width) -ForegroundColor Cyan
    if (-not [string]::IsNullOrWhiteSpace($Message)) {
        Write-Host $Message -ForegroundColor Yellow
    }
    Write-Host ((Get-GrlText -Key 'componentSelect.selectedCount') -f $Selected.Count, $Components.Count) -ForegroundColor DarkGray
    Write-Host (Get-GrlText -Key 'componentSelect.presets') -ForegroundColor Yellow
    Write-Host ''

    $index = 1
    foreach ($component in $Components) {
        $checked = $Selected.ContainsKey([string]$component.id)
        $mark = if ($checked) { '[x]' } else { '[ ]' }
        $tier = if ($component.tier -eq 'Core') { Get-GrlText -Key 'common.componentTierCore' } else { Get-GrlText -Key 'common.componentTierLegacy' }
        $line = '{0} {1,2}. [{2}] {3} ({4})' -f $mark, $index, $tier, (Get-GrlComponentName -Component $component), $component.id
        if ($checked) {
            Write-Host $line -ForegroundColor Green
        }
        else {
            Write-Host $line
        }
        $index++
    }

    Write-Host ''
    Write-Host (Get-GrlText -Key 'componentSelect.defaultHint') -ForegroundColor DarkGray
}

function Update-GrlComponentSelection {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$InputText,
        [Parameter(Mandatory = $true)]
        [object[]]$Components,
        [Parameter(Mandatory = $true)]
        [hashtable]$Selected
    )

    $result = [pscustomobject]@{
        Confirm = $false
        Cancel = $false
        Error = ''
    }

    $trimmed = $InputText.Trim()
    if ($trimmed.Length -eq 0) {
        $result.Confirm = $true
        return $result
    }
    if ($trimmed -eq '0') {
        $result.Cancel = $true
        return $result
    }
    if ($trimmed -match '^(?i)q$|^(?i)a$') {
        foreach ($component in $Components) {
            $Selected[[string]$component.id] = $true
        }
        return $result
    }
    if ($trimmed -match '^(?i)t$') {
        $Selected.Clear()
        foreach ($id in @(Get-GrlRecommendedComponentIds -Components $Components)) {
            $Selected[$id] = $true
        }
        return $result
    }
    if ($trimmed -match '^(?i)n$') {
        $Selected.Clear()
        return $result
    }

    $invalid = @()
    foreach ($token in @($trimmed -split '[,，、\s]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        if ($token -notmatch '^\d+$') {
            $invalid += $token
            continue
        }
        $number = [int]$token
        if ($number -lt 1 -or $number -gt $Components.Count) {
            $invalid += $token
            continue
        }
        $id = [string]$Components[$number - 1].id
        if ($Selected.ContainsKey($id)) {
            $Selected.Remove($id)
        }
        else {
            $Selected[$id] = $true
        }
    }
    if ($invalid.Count -gt 0) {
        $result.Error = ($invalid -join ', ')
    }
    return $result
}

function Select-GrlComponentsInteractively {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Components
    )

    $selected = @{}
    foreach ($id in @(Get-GrlRecommendedComponentIds -Components $Components)) {
        $selected[$id] = $true
    }
    if ($selected.Count -eq 0) {
        # 没有 Core 组件时退回全选，避免默认空选。
        foreach ($component in $Components) {
            $selected[[string]$component.id] = $true
        }
    }

    $message = ''
    while ($true) {
        Show-GrlComponentSelection -Components $Components -Selected $selected -Message $message
        $answer = Read-Host (Get-GrlText -Key 'prompts.selectComponents')
        $update = Update-GrlComponentSelection -InputText $answer -Components $Components -Selected $selected
        if ($update.Cancel) {
            return $null
        }
        if ($update.Confirm) {
            if ($selected.Count -eq 0) {
                $message = Get-GrlText -Key 'componentSelect.empty'
                continue
            }
            break
        }
        if (-not [string]::IsNullOrWhiteSpace($update.Error)) {
            $message = (Get-GrlText -Key 'componentSelect.invalid') -f $update.Error
        }
        else {
            $message = ''
        }
    }

    $ids = @($Components | Where-Object { $selected.ContainsKey([string]$_.id) } | ForEach-Object { [string]$_.id })
    Write-Host ((Get-GrlText -Key 'componentSelect.confirmed') -f $ids.Count) -ForegroundColor Green
    return $ids
}

function Get-GrlElevationCommandLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EntryScriptPath,
        [Parameter(Mandatory = $true)]
        [object]$Parameters
    )

    $escapedEntry = $EntryScriptPath.Replace("'", "''")
    $parts = @("& '$escapedEntry'")
    foreach ($name in @('Profile', 'Action', 'OfflineRoot', 'FeatureSource', 'Language')) {
        $value = [string]$Parameters[$name]
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $parts += "-$name '$($value.Replace("'", "''"))'"
        }
    }
    foreach ($name in @('AllowUnsupportedOS', 'NonInteractive')) {
        if ([bool]$Parameters[$name]) {
            $parts += "-$name"
        }
    }
    if ($Parameters.ContainsKey('ComponentId') -and $Parameters.ComponentId.Count -gt 0) {
        $ids = @($Parameters.ComponentId | ForEach-Object { "'$(([string]$_).Replace("'", "''"))'" }) -join ','
        $parts += "-ComponentId @($ids)"
    }
    return $parts -join ' '
}

function Invoke-GrlElevatedAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EntryScriptPath,
        [Parameter(Mandatory = $true)]
        [object]$Parameters
    )

    $commandLine = Get-GrlElevationCommandLine -EntryScriptPath $EntryScriptPath -Parameters $Parameters
    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($commandLine))
    $entrySignature = Get-AuthenticodeSignature -LiteralPath $EntryScriptPath
    $executionPolicy = if ($entrySignature.Status -eq 'Valid') { 'AllSigned' } else { 'Bypass' }
    $arguments = @('-NoProfile', '-ExecutionPolicy', $executionPolicy, '-EncodedCommand', $encodedCommand)
    try {
        Write-GrlMessage -Message (Get-GrlText -Key 'install.elevationRequest') -Level '信息' -Component 'Menu'
        $process = Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -Verb RunAs -Wait -PassThru
        return [int]$process.ExitCode
    }
    catch {
        Write-GrlMessage -Message ((Get-GrlText -Key 'install.elevationFailed') -f $_.Exception.Message) -Level '错误' -Component 'Menu'
        return 60
    }
}

function Invoke-GrlStatusAction {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Components,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition,
        [switch]$RequireAllInstalled
    )

    $states = @(Get-GrlAllComponentStates -Components $Components -ProfileDefinition $ProfileDefinition)
    Write-GrlComponentStates -States $states
    $missing = @($states | Where-Object { $_.State -ne 'Installed' })
    if ($RequireAllInstalled -and $missing.Count -gt 0) {
        Write-GrlMessage -Message ((Get-GrlText -Key 'status.missingOrUnknown') -f $missing.Count) -Level '警告' -Component 'Verify'
        return (Get-GrlExitCode -Name PartialFailure)
    }
    if ($missing.Count -eq 0) {
        Write-GrlMessage -Message (Get-GrlText -Key 'status.allInstalled') -Level '成功' -Component 'Verify'
    }
    return (Get-GrlExitCode -Name Success)
}

function Invoke-GrlDllStatusAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object[]]$Components,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition
    )

    $dllMap = Import-GrlDllMap -RootPath $RootPath
    $componentStates = @(Get-GrlAllComponentStates -Components $Components -ProfileDefinition $ProfileDefinition)
    $rows = @(Get-GrlDllStates -DllMap $dllMap -Components $Components -ComponentStates $componentStates)
    $note = Get-GrlText -Key 'status.dllNote'
    Write-GrlDllStates -States $rows -Note $note
    return (Get-GrlExitCode -Name Success)
}

function Invoke-GrlInstallAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$Catalog,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition,
        [Parameter(Mandatory = $true)]
        [object[]]$Components,
        [Parameter(Mandatory = $true)]
        [bool]$AllowNetwork,
        [string]$OfflineRoot,
        [string]$FeatureSource,
        [switch]$RepairOnly,
        [switch]$WhatIf,
        [switch]$NonInteractive
    )

    if ($AllowNetwork) {
        $packageDirectory = Get-GrlPackageDirectory -RootPath $RootPath -ProfileDefinition $ProfileDefinition
    }
    else {
        $packageDirectory = Resolve-GrlOfflinePackageDirectory -OfflineRoot $OfflineRoot -ProfileDefinition $ProfileDefinition
        if ([string]::IsNullOrWhiteSpace($FeatureSource)) {
            $bundledFeatureSource = Join-Path $packageDirectory 'feature-payloads'
            if (Test-Path -LiteralPath $bundledFeatureSource -PathType Container) {
                $FeatureSource = $bundledFeatureSource
            }
        }
    }

    try {
        $plan = New-GrlInstallationPlan -Catalog $Catalog -ProfileDefinition $ProfileDefinition -Components $Components -PackageDirectory $packageDirectory -AllowNetwork $AllowNetwork -FeatureSource $FeatureSource -PreviewOnly:$WhatIf -RepairOnly:$RepairOnly
    }
    catch {
        if (-not $WhatIf) {
            Send-GrlCompletionNotification -Title (Get-GrlText -Key 'notification.failedTitle') -Message ((Get-GrlText -Key 'notification.planFailedMessage') -f $_.Exception.Message) -NonInteractive:$NonInteractive
        }
        throw
    }
    $result = Start-GrlInstallationPlan -Plan $plan
    if ($result.Items.Count -gt 0) {
        Write-GrlInstallationSummary -Items $result.Items
    }
    Write-GrlMessage -Message $result.SummaryText -Level '信息' -Component 'Menu'

    if (-not $WhatIf) {
        # 安装结束后重新检测，明确告诉用户哪些组件仍未安装（而不是只看安装器退出码）。
        Clear-GrlDetectionCache
        $states = @(Get-GrlAllComponentStates -Components $Components -ProfileDefinition $ProfileDefinition)
        $verification = Write-GrlInstallationResult -Items $result.Items -States $states -ExitCode $result.ExitCode

        $isSuccess = ($verification.Failed.Count -eq 0 -and $verification.NotInstalled.Count -eq 0)
        $noticeTitle = ''
        $noticeMessage = ''
        if ($verification.Failed.Count -gt 0) {
            $noticeTitle = Get-GrlText -Key 'notification.failedTitle'
            $noticeMessage = (Get-GrlText -Key 'notification.failedMessage') -f $verification.Failed.Count
        }
        elseif ($verification.NotInstalled.Count -gt 0) {
            $noticeTitle = Get-GrlText -Key 'notification.partialTitle'
            $nameSeparator = ', '
            if ((Get-GrlCurrentLanguage) -eq 'zh-CN') {
                $nameSeparator = '、'
            }
            $names = (@($verification.NotInstalled | Select-Object -First 3 | ForEach-Object { $_.DisplayName }) -join $nameSeparator)
            $noticeMessage = (Get-GrlText -Key 'notification.partialMessage') -f $verification.NotInstalled.Count, $names
        }
        elseif ($verification.Restart.Count -gt 0) {
            $noticeTitle = Get-GrlText -Key 'notification.restartTitle'
            $noticeMessage = Get-GrlText -Key 'notification.restartMessage'
        }
        else {
            $noticeTitle = Get-GrlText -Key 'notification.successTitle'
            $noticeMessage = (Get-GrlText -Key 'notification.successMessage') -f $verification.Installed.Count
        }
        Send-GrlCompletionNotification -Title $noticeTitle -Message $noticeMessage -Success:$isSuccess -NonInteractive:$NonInteractive

        if ($verification.NotInstalled.Count -gt 0 -and $result.ExitCode -eq 0) {
            $result.ExitCode = 40
        }
    }

    return [int]$result.ExitCode
}

function Invoke-GrlOfflinePreparation {
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
        [switch]$WhatIf,
        [switch]$NonInteractive
    )

    if ($WhatIf) {
        Write-GrlMessage -Message ((Get-GrlText -Key 'offline.preview') -f $Components.Count, $ProfileDefinition.displayName) -Level '信息' -Component 'Offline'
        foreach ($component in $Components) {
            $names = @(Get-GrlApplicablePackages -Component $component -ProfileDefinition $ProfileDefinition | ForEach-Object { $_.fileName }) -join '，'
            Write-Host ("  {0}: {1}" -f (Get-GrlComponentName -Component $component), $names)
        }
        Write-GrlMessage -Message (Get-GrlText -Key 'offline.previewComplete') -Level '信息' -Component 'Offline'
        return (Get-GrlExitCode -Name Success)
    }

    $result = New-GrlOfflineBundle -RootPath $RootPath -Catalog $Catalog -ProfileDefinition $ProfileDefinition -SystemInfo $SystemInfo -Components $Components -FeatureSource $FeatureSource
    Write-GrlMessage -Message ((Get-GrlText -Key 'offline.created') -f $result.ZipPath) -Level '成功' -Component 'Offline'
    foreach ($feature in $result.FeatureRecords) {
        if (-not $feature.payloadIncluded) {
            Write-GrlMessage -Message ((Get-GrlText -Key 'offline.missingFeaturePayload') -f $feature.featureName) -Level '警告' -Component 'Offline'
        }
    }
    Send-GrlCompletionNotification -Title (Get-GrlText -Key 'notification.offlineTitle') -Message ((Get-GrlText -Key 'notification.offlineMessage') -f $result.ZipPath) -Success -NonInteractive:$NonInteractive
    return (Get-GrlExitCode -Name Success)
}

function Invoke-GrlMenuLoop {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [string]$EntryScriptPath,
        [Parameter(Mandatory = $true)]
        [string]$ProfileId,
        [Parameter(Mandatory = $true)]
        [object]$Catalog,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition,
        [Parameter(Mandatory = $true)]
        [object]$SystemInfo,
        [string]$Language,
        [switch]$AllowUnsupportedOS,
        [switch]$NonInteractive,
        [switch]$WhatIf
    )

    if ($NonInteractive) {
        throw (Get-GrlText -Key 'common.menuRequiresInteractive')
    }

    while ($true) {
        Write-GrlHeader -SystemInfo $SystemInfo -ProfileDefinition $ProfileDefinition -LogPath (Get-GrlLogPath)
        Write-Host (Get-GrlText -Key 'menu.hintFirstRun') -ForegroundColor DarkGray
        Write-Host ''

        Write-Host (Get-GrlText -Key 'menu.groupMaintenance') -ForegroundColor DarkCyan
        Write-Host ('  1. ' + (Get-GrlText -Key 'menu.checkStatus'))
        Write-Host ('  2. ' + (Get-GrlText -Key 'menu.installOnline'))
        Write-Host ('  3. ' + (Get-GrlText -Key 'menu.installCustom'))
        Write-Host ('  4. ' + (Get-GrlText -Key 'menu.repairMissing'))
        Write-Host ''
        Write-Host (Get-GrlText -Key 'menu.groupOffline') -ForegroundColor DarkCyan
        Write-Host ('  5. ' + (Get-GrlText -Key 'menu.prepareOffline'))
        Write-Host ('  6. ' + (Get-GrlText -Key 'menu.installOffline'))
        Write-Host ''
        Write-Host (Get-GrlText -Key 'menu.groupInfo') -ForegroundColor DarkCyan
        Write-Host ('  7. ' + (Get-GrlText -Key 'menu.dllStatus'))
        Write-Host ('  8. ' + (Get-GrlText -Key 'menu.componentList'))
        Write-Host ('  9. ' + (Get-GrlText -Key 'menu.language'))
        Write-Host ('  0. ' + (Get-GrlText -Key 'menu.exit'))
        Write-Host ''
        $choice = Read-Host (Get-GrlText -Key 'prompts.selectAction')
        $languageChanged = $false
        $skipPause = $false
        switch ($choice) {
            '1' {
                $components = @(Get-GrlSelectedComponents -Catalog $Catalog -ProfileDefinition $ProfileDefinition)
                Invoke-GrlStatusAction -Components $components -ProfileDefinition $ProfileDefinition | Out-Null
            }
            '2' {
                $components = @(Get-GrlSelectedComponents -Catalog $Catalog -ProfileDefinition $ProfileDefinition)
                $parameters = @{ Profile = $ProfileId; Action = 'InstallOnline'; Language = $Language; AllowUnsupportedOS = $AllowUnsupportedOS; NonInteractive = $false }
                if ((-not $WhatIf) -and (-not (Test-GrlAdministrator))) {
                    Invoke-GrlElevatedAction -EntryScriptPath $EntryScriptPath -Parameters $parameters | Out-Null
                }
                else {
                    Invoke-GrlInstallAction -RootPath $RootPath -Catalog $Catalog -ProfileDefinition $ProfileDefinition -Components $components -AllowNetwork $true -WhatIf:$WhatIf | Out-Null
                }
            }
            '3' {
                $applicable = @(Get-GrlSelectedComponents -Catalog $Catalog -ProfileDefinition $ProfileDefinition)
                $selectedIds = Select-GrlComponentsInteractively -Components $applicable
                if ($null -eq $selectedIds) {
                    $skipPause = $true
                }
                else {
                    $parameters = @{ Profile = $ProfileId; Action = 'InstallOnline'; ComponentId = $selectedIds; Language = $Language; AllowUnsupportedOS = $AllowUnsupportedOS; NonInteractive = $false }
                    if ((-not $WhatIf) -and (-not (Test-GrlAdministrator))) {
                        Invoke-GrlElevatedAction -EntryScriptPath $EntryScriptPath -Parameters $parameters | Out-Null
                    }
                    else {
                        $selected = @(Get-GrlSelectedComponents -Catalog $Catalog -ProfileDefinition $ProfileDefinition -ComponentId $selectedIds)
                        Invoke-GrlInstallAction -RootPath $RootPath -Catalog $Catalog -ProfileDefinition $ProfileDefinition -Components $selected -AllowNetwork $true -WhatIf:$WhatIf | Out-Null
                    }
                }
            }
            '4' {
                $components = @(Get-GrlSelectedComponents -Catalog $Catalog -ProfileDefinition $ProfileDefinition)
                $parameters = @{ Profile = $ProfileId; Action = 'RepairMissing'; Language = $Language; AllowUnsupportedOS = $AllowUnsupportedOS; NonInteractive = $false }
                if ((-not $WhatIf) -and (-not (Test-GrlAdministrator))) {
                    Invoke-GrlElevatedAction -EntryScriptPath $EntryScriptPath -Parameters $parameters | Out-Null
                }
                else {
                    Invoke-GrlInstallAction -RootPath $RootPath -Catalog $Catalog -ProfileDefinition $ProfileDefinition -Components $components -AllowNetwork $true -RepairOnly -WhatIf:$WhatIf | Out-Null
                }
            }
            '5' {
                $components = @(Get-GrlSelectedComponents -Catalog $Catalog -ProfileDefinition $ProfileDefinition)
                Invoke-GrlOfflinePreparation -RootPath $RootPath -Catalog $Catalog -ProfileDefinition $ProfileDefinition -SystemInfo $SystemInfo -Components $components -WhatIf:$WhatIf | Out-Null
            }
            '6' {
                $offlinePath = Read-Host (Get-GrlText -Key 'prompts.offlineRoot')
                if ([string]::IsNullOrWhiteSpace($offlinePath)) {
                    Write-GrlMessage -Message (Get-GrlText -Key 'offline.pathEmpty') -Level '错误' -Component 'Menu'
                }
                else {
                    $offlinePath = [Environment]::ExpandEnvironmentVariables($offlinePath)
                    $parameters = @{ Profile = $ProfileId; Action = 'InstallOffline'; OfflineRoot = $offlinePath; Language = $Language; AllowUnsupportedOS = $AllowUnsupportedOS; NonInteractive = $false }
                    if ((-not $WhatIf) -and (-not (Test-GrlAdministrator))) {
                        Invoke-GrlElevatedAction -EntryScriptPath $EntryScriptPath -Parameters $parameters | Out-Null
                    }
                    else {
                        Invoke-GrlAction -Action 'InstallOffline' -RootPath $RootPath -EntryScriptPath $EntryScriptPath -ProfileId $ProfileId -OfflineRoot $offlinePath -Language $Language -AllowUnsupportedOS:$AllowUnsupportedOS -NonInteractive:$false -WhatIf:$WhatIf | Out-Null
                    }
                }
            }
            '7' {
                $components = @(Get-GrlSelectedComponents -Catalog $Catalog -ProfileDefinition $ProfileDefinition)
                Invoke-GrlDllStatusAction -RootPath $RootPath -Components $components -ProfileDefinition $ProfileDefinition | Out-Null
            }
            '8' {
                Show-GrlComponentMenu -Components @(Get-GrlSelectedComponents -Catalog $Catalog -ProfileDefinition $ProfileDefinition)
            }
            '9' {
                Switch-GrlLanguage | Out-Null
                $Language = Get-GrlCurrentLanguage
                $languageChanged = $true
            }
            '0' {
                return (Get-GrlExitCode -Name Success)
            }
            default {
                Write-GrlMessage -Message (Get-GrlText -Key 'common.invalidOption') -Level '警告' -Component 'Menu'
            }
        }
        if ($languageChanged -or $skipPause) {
            continue
        }
        Write-Host ''
        Read-Host (Get-GrlText -Key 'prompts.pressEnter') | Out-Null
    }
}

function Invoke-GrlAction {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Action,
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [string]$EntryScriptPath,
        [Parameter(Mandatory = $true)]
        [string]$ProfileId,
        [string[]]$ComponentId,
        [string]$OfflineRoot,
        [string]$FeatureSource,
        [string]$Language = 'Auto',
        [switch]$AllowUnsupportedOS,
        [switch]$NonInteractive,
        [switch]$WhatIf
    )

    $languageCode = Resolve-GrlLanguage -RootPath $RootPath -RequestedLanguage $Language -Interactive:($Action -eq 'Menu' -and -not $NonInteractive)
    if ([string]::IsNullOrWhiteSpace($languageCode)) {
        return (Get-GrlExitCode -Name Success)
    }
    $Language = $languageCode

    $systemInfo = Get-GrlSystemInfo
    $profileId = Resolve-GrlProfile -RequestedProfile $ProfileId -SystemInfo $systemInfo
    if ([string]::IsNullOrWhiteSpace([string]$profileId)) {
        Write-GrlMessage -Message ((Get-GrlText -Key 'platform.autoDetectFailed') -f $systemInfo.Caption, $systemInfo.Architecture) -Level '错误' -Component 'Platform'
        return (Get-GrlExitCode -Name UnsupportedPlatform)
    }
    $profileDefinition = Get-GrlProfileDefinition -RootPath $RootPath -ProfileId $profileId
    $compatibility = Assert-GrlPlatformCompatibility -SystemInfo $systemInfo -ProfileDefinition $profileDefinition -AllowUnsupportedOS:$AllowUnsupportedOS
    if (-not $compatibility.IsCompatible) {
        Write-GrlMessage -Message $compatibility.Message -Level '错误' -Component 'Platform'
        return (Get-GrlExitCode -Name UnsupportedPlatform)
    }
    if ($compatibility.IsWarning) {
        Write-GrlMessage -Message $compatibility.Message -Level '警告' -Component 'Platform'
    }
    if ($Action -eq 'Menu') {
        $catalog = Import-GrlCatalog -RootPath $RootPath
        return Invoke-GrlMenuLoop -RootPath $RootPath -EntryScriptPath $EntryScriptPath -ProfileId $profileId -Catalog $catalog -ProfileDefinition $profileDefinition -SystemInfo $systemInfo -Language $Language -AllowUnsupportedOS:$AllowUnsupportedOS -NonInteractive:$NonInteractive -WhatIf:$WhatIf
    }

    Write-GrlHeader -SystemInfo $systemInfo -ProfileDefinition $profileDefinition -LogPath (Get-GrlLogPath)

    if ((-not $WhatIf) -and (Test-GrlActionRequiresAdministrator -Action $Action) -and (-not (Test-GrlAdministrator))) {
        if ($NonInteractive) {
            Write-GrlMessage -Message (Get-GrlText -Key 'install.adminRequired') -Level '错误' -Component 'Environment'
            return (Get-GrlExitCode -Name PrerequisiteMissing)
        }
        $parameters = @{
            Profile = $profileId
            Action = $Action
            ComponentId = $ComponentId
            OfflineRoot = $OfflineRoot
            FeatureSource = $FeatureSource
            Language = $Language
            AllowUnsupportedOS = $AllowUnsupportedOS
            NonInteractive = $true
        }
        return Invoke-GrlElevatedAction -EntryScriptPath $EntryScriptPath -Parameters $parameters
    }

    $effectiveRoot = $RootPath
    if ($Action -eq 'InstallOffline') {
        if ([string]::IsNullOrWhiteSpace($OfflineRoot)) {
            $OfflineRoot = $RootPath
        }
        $effectiveRoot = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($OfflineRoot))
        if (-not (Test-Path -LiteralPath $effectiveRoot -PathType Container)) {
            Write-GrlMessage -Message ((Get-GrlText -Key 'offline.pathNotFound') -f $effectiveRoot) -Level '错误' -Component 'Offline'
            return (Get-GrlExitCode -Name PrerequisiteMissing)
        }
        try {
            $sourceLock = Test-GrlReleaseIntegrity -RootPath $RootPath
            $requireProductionOffline = $sourceLock.ReleaseKind -eq 'Production'
            Test-GrlReleaseIntegrity -RootPath $effectiveRoot -RequireProduction:$requireProductionOffline | Out-Null
        }
        catch {
            Write-GrlMessage -Message ((Get-GrlText -Key 'offline.integrityFailed') -f $_.Exception.Message) -Level '错误' -Component 'Offline'
            return (Get-GrlExitCode -Name IntegrityFailed)
        }
    }

    $catalog = Import-GrlCatalog -RootPath $effectiveRoot
    $profileDefinition = Get-GrlProfileDefinition -RootPath $effectiveRoot -ProfileId $profileId
    $components = @(Get-GrlSelectedComponents -Catalog $catalog -ProfileDefinition $profileDefinition -ComponentId $ComponentId)

    if ($Action -eq 'InstallOffline' -and -not $WhatIf) {
        $bundleReport = Test-GrlOfflineBundle -OfflineRoot $effectiveRoot -ProfileDefinition $profileDefinition -Catalog $catalog
        if (-not $bundleReport.IsValid) {
            $details = (@($bundleReport.Issues) | Select-Object -First 5) -join '；'
            Write-GrlMessage -Message ((Get-GrlText -Key 'offline.bundleInvalid') -f $details) -Level '错误' -Component 'Offline'
            return (Get-GrlExitCode -Name IntegrityFailed)
        }

        $explicitComponentIds = @($ComponentId | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($explicitComponentIds.Count -eq 0) {
            $bundleComponentIds = @($bundleReport.ComponentIds)
            if ($bundleComponentIds.Count -gt 0) {
                $includedComponents = @($components | Where-Object { $bundleComponentIds -contains [string]$_.id })
                $excludedCount = $components.Count - $includedComponents.Count
                if ($excludedCount -gt 0) {
                    Write-GrlMessage -Message ((Get-GrlText -Key 'offline.partialBundle') -f $includedComponents.Count, $excludedCount) -Level '警告' -Component 'Offline'
                }
                $components = $includedComponents
            }
        }
    }

    switch ($Action) {
        'Status' {
            return Invoke-GrlStatusAction -Components $components -ProfileDefinition $profileDefinition
        }
        'DllStatus' {
            return Invoke-GrlDllStatusAction -RootPath $effectiveRoot -Components $components -ProfileDefinition $profileDefinition
        }
        'Verify' {
            return Invoke-GrlStatusAction -Components $components -ProfileDefinition $profileDefinition -RequireAllInstalled
        }
        'InstallOnline' {
            return Invoke-GrlInstallAction -RootPath $RootPath -Catalog $catalog -ProfileDefinition $profileDefinition -Components $components -AllowNetwork $true -WhatIf:$WhatIf -NonInteractive:$NonInteractive
        }
        'RepairMissing' {
            return Invoke-GrlInstallAction -RootPath $RootPath -Catalog $catalog -ProfileDefinition $profileDefinition -Components $components -AllowNetwork $true -RepairOnly -WhatIf:$WhatIf -NonInteractive:$NonInteractive
        }
        'PrepareOffline' {
            return Invoke-GrlOfflinePreparation -RootPath $RootPath -Catalog $catalog -ProfileDefinition $profileDefinition -SystemInfo $systemInfo -Components $components -FeatureSource $FeatureSource -WhatIf:$WhatIf -NonInteractive:$NonInteractive
        }
        'InstallOffline' {
            Get-GrlOfflineManifest -OfflineRoot $effectiveRoot -ProfileDefinition $profileDefinition | Out-Null
            return Invoke-GrlInstallAction -RootPath $effectiveRoot -Catalog $catalog -ProfileDefinition $profileDefinition -Components $components -AllowNetwork $false -OfflineRoot $effectiveRoot -FeatureSource $FeatureSource -WhatIf:$WhatIf -NonInteractive:$NonInteractive
        }
        default {
            throw "未知操作：$Action"
        }
    }
}

function Invoke-GameRuntimeLibrary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Alias('Profile')]
        [string]$ProfileId = 'Auto',
        [string]$Action = 'Menu',
        [string[]]$ComponentId,
        [string]$OfflineRoot,
        [string]$FeatureSource,
        [string]$Language = 'Auto',
        [switch]$AllowUnsupportedOS,
        [switch]$NonInteractive,
        [switch]$WhatIf,
        [string]$ReleaseChannel = 'Development',
        [Parameter(Mandatory = $true)]
        [string]$EntryScriptPath
    )

    $script:GameRuntimeDevelopmentBuild = $ReleaseChannel -ne 'Production'
    $finalExitCode = Get-GrlExitCode -Name PartialFailure

    try {
        if (-not $WhatIf) {
            Initialize-GrlLogging -RootPath $RootPath
        }
        $exitCode = Invoke-GrlAction -Action $Action -RootPath $RootPath -EntryScriptPath $EntryScriptPath -ProfileId $ProfileId -ComponentId $ComponentId -OfflineRoot $OfflineRoot -FeatureSource $FeatureSource -Language $Language -AllowUnsupportedOS:$AllowUnsupportedOS -NonInteractive:$NonInteractive -WhatIf:$WhatIf
        $finalExitCode = [int]$exitCode
        return New-GrlResult -ExitCode $finalExitCode
    }
    catch [System.UnauthorizedAccessException] {
        Write-GrlMessage -Message $_.Exception.Message -Level '错误' -Component 'Environment'
        $finalExitCode = Get-GrlExitCode -Name PrerequisiteMissing
        return New-GrlResult -ExitCode $finalExitCode
    }
    catch {
        $message = $_.Exception.Message
        Write-GrlMessage -Message $message -Level '错误' -Component 'Environment'

        $structuredExitCode = Get-GrlExceptionExitCode -ErrorRecord $_
        if ($null -ne $structuredExitCode) {
            $finalExitCode = [int]$structuredExitCode
            return New-GrlResult -ExitCode $finalExitCode
        }

        if ($message -match '管理员|挂起重启|Windows 功能|功能组件|Sources\\sxs|功能载荷') {
            $finalExitCode = Get-GrlExitCode -Name PrerequisiteMissing
        }
        elseif ($message -match '下载|SHA-256|数字签名|文件大小|官方地址|离线模式缺少|压缩包|条目名称') {
            $finalExitCode = Get-GrlExitCode -Name DownloadOrValidationFailed
        }
        elseif ($message -match '离线包|离线清单|功能载荷') {
            $finalExitCode = Get-GrlExitCode -Name IntegrityFailed
        }
        else {
            $finalExitCode = Get-GrlExitCode -Name PartialFailure
        }
        return New-GrlResult -ExitCode $finalExitCode
    }
    finally {
        if (-not $WhatIf) {
            Complete-GrlLogging -ExitCode $finalExitCode
        }
    }
}

Export-ModuleMember -Function Invoke-GameRuntimeLibrary, Get-GrlElevationCommandLine, Invoke-GrlElevatedAction, Write-GrlHeader, Select-GrlComponentsInteractively
