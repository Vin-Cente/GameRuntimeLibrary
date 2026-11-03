$ErrorActionPreference = 'Stop'

function Get-GrlPackageDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition
    )
    return Join-Path (Join-Path $RootPath $ProfileDefinition.displayName) 'packages'
}

function Resolve-GrlFeatureSource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FeatureName,
        [string]$FeatureSource
    )

    if (-not [string]::IsNullOrWhiteSpace($FeatureSource)) {
        $candidate = [Environment]::ExpandEnvironmentVariables($FeatureSource)
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $nested = Join-Path $candidate 'sources\sxs'
            if (Test-Path -LiteralPath $nested -PathType Container) {
                return (Resolve-Path -LiteralPath $nested).Path
            }
            return (Resolve-Path -LiteralPath $candidate).Path
        }
        throw "功能组件源不存在：$candidate"
    }

    $patterns = switch ($FeatureName) {
        'NetFx3' { @('Microsoft-Windows-NetFx3-OnDemand-Package*.cab') }
        'DirectPlay' { @('Microsoft-Windows-DirectPlay*.cab', 'Microsoft-Windows-DirectPlay*.mum') }
        default { @() }
    }
    $searchRoots = @(
        (Join-Path $env:windir 'servicing\Packages'),
        (Join-Path $env:windir 'SoftwareDistribution\Download'),
        (Join-Path $env:windir 'WinSxS')
    )

    foreach ($root in $searchRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }
        foreach ($pattern in $patterns) {
            $match = Get-ChildItem -LiteralPath $root -Filter $pattern -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $match) {
                return $match.DirectoryName
            }
        }
    }
    return $null
}

function Test-GrlPackageAlreadyInstalled {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Package
    )

    if ($null -eq $Package.detection) {
        return $false
    }
    $result = Test-GrlDetection -Detection $Package.detection -RegistryView 'Default'
    return $result.State -eq 'Installed'
}

function New-GrlDiskSpaceException {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $command = Get-Command -Name 'New-GrlException' -CommandType Function -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return (New-GrlException -Message $Message -ExitCode 40 -Category 'DiskSpace')
    }
    return (New-Object System.Exception($Message))
}

function Assert-GrlFreeSpace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [long]$RequiredBytes,
        [double]$Multiplier = 1.2
    )

    if ($RequiredBytes -le 0) {
        return
    }

    $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Path))
    $drive = [System.IO.DriveInfo]::new($root)
    $available = [long]$drive.AvailableFreeSpace
    $required = [math]::Ceiling([double]$RequiredBytes * $Multiplier)
    if ($available -ge $required) {
        return
    }

    $requiredMb = [long][math]::Ceiling($required / 1MB)
    $availableMb = [long][math]::Floor($available / 1MB)
    $message = "磁盘空间不足，至少需要 $requiredMb MB，当前可用 $availableMb MB（路径：$Path）。"
    throw (New-GrlDiskSpaceException -Message $message)
}

function New-GrlInstallationPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Catalog,
        [Parameter(Mandatory = $true)]
        [object]$ProfileDefinition,
        [Parameter(Mandatory = $true)]
        [object[]]$Components,
        [Parameter(Mandatory = $true)]
        [string]$PackageDirectory,
        [Parameter(Mandatory = $true)]
        [bool]$AllowNetwork,
        [string]$FeatureSource,
        [switch]$PreviewOnly,
        [switch]$RepairOnly
    )

    if (-not $PreviewOnly) {
        if (-not (Test-GrlAdministrator)) {
            throw [System.UnauthorizedAccessException]::new((Get-GrlText -Key 'install.adminRequired'))
        }
        if (Test-GrlPendingReboot) {
            throw [System.InvalidOperationException]::new((Get-GrlText -Key 'install.rebootRequired'))
        }
    }

    $states = @(Get-GrlAllComponentStates -Components $Components -ProfileDefinition $ProfileDefinition)
    $entries = @()
    $requiredBytes = [long]0
    foreach ($component in $Components) {
        $state = $states | Where-Object { $_.Id -eq $component.id } | Select-Object -First 1
        $skip = $state.State -eq 'Installed'
        if ($RepairOnly -and $state.State -eq 'Installed') {
            $skip = $true
        }
        if ($skip) {
            $entries += [pscustomobject]@{
                Component = $component
                InitialState = $state
                Packages = @()
                FeatureSource = $null
                Skip = $true
            }
            continue
        }

        $validatedPackages = @()
        foreach ($package in @(Get-GrlApplicablePackages -Component $component -ProfileDefinition $ProfileDefinition)) {
            $destination = Join-Path $PackageDirectory $package.fileName
            $packageInstalled = Test-GrlPackageAlreadyInstalled -Package $package
            if ($packageInstalled -and -not $RepairOnly) {
                $validatedPackages += [pscustomobject]@{
                    Definition = $package
                    Path = $destination
                    State = $null
                    WouldDownload = $false
                    Skip = $true
                    SkipReason = '已安装'
                    Repair = $false
                }
                continue
            }
            $packageAlreadyPresent = Test-Path -LiteralPath $destination -PathType Leaf
            if (-not $packageAlreadyPresent -and $null -ne $package.size) {
                $requiredBytes += [long]$package.size
            }
            if ($PreviewOnly) {
                $validatedPackages += [pscustomobject]@{
                    Definition = $package
                    Path = $destination
                    State = $null
                    WouldDownload = -not $packageAlreadyPresent
                    Skip = $false
                    SkipReason = $null
                    Repair = [bool]$RepairOnly
                }
                continue
            }
            $packageState = Invoke-GrlSafeDownload -Package $package -DestinationDirectory $PackageDirectory -AllowedDomains $Catalog.officialDomains -AllowNetwork:$AllowNetwork
            $validatedPackages += [pscustomobject]@{
                Definition = $package
                Path = $packageState.Path
                State = $packageState
                WouldDownload = $false
                Skip = $false
                SkipReason = $null
                Repair = [bool]$RepairOnly
            }
        }

        $resolvedFeatureSource = $null
        if ($component.installer.type -eq 'WindowsFeature') {
            $resolvedFeatureSource = Resolve-GrlFeatureSource -FeatureName $component.installer.featureName -FeatureSource $FeatureSource
            if (-not $AllowNetwork -and [string]::IsNullOrWhiteSpace($resolvedFeatureSource) -and -not $PreviewOnly -and $component.id -eq 'dotnet35') {
                throw "离线模式缺少 $($component.displayName) 的功能载荷，请提供匹配 Windows 版本的 sources\sxs。"
            }
        }

        $entries += [pscustomobject]@{
            Component = $component
            InitialState = $state
            Packages = @($validatedPackages)
            FeatureSource = $resolvedFeatureSource
            Skip = $false
            SkipReason = $null
        }
    }

    if (-not $PreviewOnly -and $AllowNetwork -and $requiredBytes -gt 0) {
        Assert-GrlFreeSpace -Path $PackageDirectory -RequiredBytes $requiredBytes -Multiplier 1.2
    }

    if (-not $PreviewOnly) {
        $verifiedStates = @($entries | ForEach-Object {
            foreach ($packageEntry in @($_.Packages)) {
                if ($null -ne $packageEntry.State) {
                    $packageEntry.State
                }
            }
        })
        Write-GrlPackageCacheManifest -Directory $PackageDirectory -States $verifiedStates
    }

    return [pscustomobject]@{
        Profile = $ProfileDefinition
        Entries = @($entries)
        PreviewOnly = [bool]$PreviewOnly
        AllowNetwork = $AllowNetwork
        PackageDirectory = $PackageDirectory
    }
}

function Invoke-GrlProcessWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$MaximumAttempts = 3,
        [int]$TimeoutSeconds = 3600
    )

    $timeoutMilliseconds = [int]($TimeoutSeconds * 1000)
    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru -WindowStyle Hidden
        $exited = $process.WaitForExit($timeoutMilliseconds)
        if (-not $exited) {
            try {
                $process.Kill()
            }
            catch {
                Write-GrlLog -Level '警告' -Message "无法结束超时的安装程序：$FilePath（$($_.Exception.Message)）" -Component 'Installer'
            }
            try {
                $process.WaitForExit(30000) | Out-Null
            }
            catch {
                Write-GrlLog -Level '警告' -Message "等待超时安装程序退出失败：$FilePath（$($_.Exception.Message)）" -Component 'Installer'
            }
            $processName = Split-Path -Leaf $FilePath
            throw "安装程序超时（$TimeoutSeconds 秒）：$processName"
        }

        $exitCode = -1
        if ($null -ne $process.ExitCode) {
            $exitCode = [int]$process.ExitCode
        }
        if ($exitCode -ne 1618 -or $attempt -eq $MaximumAttempts) {
            return $exitCode
        }
        Write-GrlMessage -Message "另一个安装程序正在运行，15 秒后重试（$attempt/$MaximumAttempts）。" -Level '警告' -Component 'Installer'
        Start-Sleep -Seconds 15
    }
    return 1618
}

function Assert-GrlInnerInstaller {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [object]$Installer,
        [Parameter(Mandatory = $true)]
        [object]$Package
    )

    $expectedHash = ([string]$Installer.innerSha256).ToUpperInvariant()
    if ($expectedHash.Length -ne 64) {
        throw '内部安装器缺少 SHA-256。'
    }
    $actualHash = Get-GrlFileSha256 -Path $Path
    if ($actualHash -ne $expectedHash) {
        throw "内部安装器 SHA-256 不匹配：$Path"
    }
    $publisher = [string]$Installer.innerPublisherContains
    if ([string]::IsNullOrWhiteSpace($publisher)) {
        $publisher = [string]$Package.signature.publisherContains
    }
    if ([string]::IsNullOrWhiteSpace($publisher)) {
        throw '内部安装器未配置签名发布者。'
    }
    Assert-GrlPublisher -Path $Path -PublisherContains $publisher | Out-Null
}

function Invoke-GrlPackageInstaller {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Component,
        [Parameter(Mandatory = $true)]
        [object]$PackagePlan
    )

    $package = $PackagePlan.Definition
    $installer = $Component.installer
    $arguments = @()
    foreach ($argument in @($installer.arguments)) {
        $arguments += [string]$argument
    }

    switch ($installer.type) {
        'Exe' {
            return Invoke-GrlProcessWithRetry -FilePath $PackagePlan.Path -Arguments $arguments
        }
        'Msi' {
            $msiArguments = @('/i', ('"{0}"' -f $PackagePlan.Path)) + $arguments
            return Invoke-GrlProcessWithRetry -FilePath (Join-Path $env:windir 'System32\msiexec.exe') -Arguments $msiArguments
        }
        'SelfExtractingBundle' {
            $extractPath = New-GrlTempDirectory -Purpose ("extract-" + $Component.id)
            try {
                $extractArguments = @()
                foreach ($argument in @($installer.extractArguments)) {
                    $extractArguments += ([string]$argument).Replace('{ExtractPath}', $extractPath)
                }
                $extractCode = Invoke-GrlProcessWithRetry -FilePath $PackagePlan.Path -Arguments $extractArguments -MaximumAttempts 1
                if ($extractCode -notin @(0, 1638)) {
                    throw "自解压失败，退出码：$extractCode"
                }
                $innerPath = Join-Path $extractPath $installer.innerFile
                Assert-GrlChildPath -ParentPath $extractPath -ChildPath $innerPath
                Assert-GrlInnerInstaller -Path $innerPath -Installer $installer -Package $package
                return Invoke-GrlProcessWithRetry -FilePath $innerPath -Arguments $arguments
            }
            finally {
                Remove-GrlTempDirectory -Path $extractPath
            }
        }
        'ArchiveBundle' {
            $extractPath = New-GrlTempDirectory -Purpose ("archive-" + $Component.id)
            try {
                Expand-GrlSafeArchive -ArchivePath $PackagePlan.Path -DestinationPath $extractPath
                $innerPath = Join-Path $extractPath $installer.innerFile
                Assert-GrlChildPath -ParentPath $extractPath -ChildPath $innerPath
                Assert-GrlInnerInstaller -Path $innerPath -Installer $installer -Package $package
                return Invoke-GrlProcessWithRetry -FilePath $innerPath -Arguments $arguments
            }
            finally {
                Remove-GrlTempDirectory -Path $extractPath
            }
        }
        default {
            throw "不支持直接执行安装类型：$($installer.type)"
        }
    }
}

function Invoke-GrlWindowsFeatureInstaller {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Component,
        [Parameter(Mandatory = $true)]
        [bool]$AllowNetwork,
        [string]$FeatureSource
    )

    $allowedFeatures = @('NetFx3', 'DirectPlay')
    $featureName = [string]$Component.installer.featureName
    if ($allowedFeatures -notcontains $featureName) {
        throw "不允许启用未授权的 Windows 功能：$featureName（允许：$($allowedFeatures -join '、')）"
    }

    $parameters = @{
        Online = $true
        FeatureName = $featureName
        All = $true
        NoRestart = $true
        ErrorAction = 'Stop'
    }
    if (-not $AllowNetwork) {
        $parameters.LimitAccess = $true
        if (-not [string]::IsNullOrWhiteSpace($FeatureSource)) {
            $parameters.Source = $FeatureSource
        }
    }
    try {
        $result = Enable-WindowsOptionalFeature @parameters
        if ($result.RestartNeeded) {
            return 3010
        }
        return 0
    }
    catch {
        throw "启用 Windows 功能 $featureName 失败：$($_.Exception.Message)"
    }
}

function Get-GrlInstalledExitCategory {
    param(
        [int]$ExitCode
    )
    if ($ExitCode -in @(0, 1638)) {
        return 'Succeeded'
    }
    if ($ExitCode -in @(3010, 1641)) {
        return 'RestartRequired'
    }
    return 'Failed'
}

function Start-GrlInstallationPlan {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Plan
    )

    if ($Plan.PreviewOnly) {
        foreach ($entry in $Plan.Entries) {
            if ($entry.Skip) {
                Write-GrlMessage -Message ((Get-GrlText -Key 'install.skipComponent') -f (Get-GrlComponentName -Component $entry.Component)) -Level '信息' -Component 'Installer'
                continue
            }
            if ($entry.Packages.Count -eq 0) {
                Write-GrlMessage -Message ((Get-GrlText -Key 'install.planFeature') -f (Get-GrlComponentName -Component $entry.Component)) -Level '信息' -Component 'Installer'
                continue
            }
            foreach ($packagePlan in @($entry.Packages)) {
                if ($packagePlan.Skip) {
                    Write-GrlMessage -Message ((Get-GrlText -Key 'install.skipPackage') -f $packagePlan.Definition.fileName) -Level '信息' -Component 'Installer'
                    continue
                }
                Write-GrlMessage -Message ((Get-GrlText -Key 'install.planPackage') -f (Get-GrlComponentName -Component $entry.Component), $packagePlan.Definition.fileName) -Level '信息' -Component 'Installer'
            }
        }
        return [pscustomobject]@{
            ExitCode = 0
            Items = @()
            SummaryText = Get-GrlText -Key 'install.previewComplete'
        }
    }

    if (-not (Test-GrlAdministrator)) {
        throw [System.UnauthorizedAccessException]::new((Get-GrlText -Key 'install.adminRequired'))
    }
    if (Test-GrlPendingReboot) {
        throw [System.InvalidOperationException]::new((Get-GrlText -Key 'install.rebootRequired'))
    }

    $items = @()
    $totalEntries = @($Plan.Entries).Count
    $entryIndex = 0
    Write-GrlProgress -Activity (Get-GrlText -Key 'progress.installing') -Status ('0/{0}' -f $totalEntries) -Percent 0
    foreach ($entry in $Plan.Entries) {
        $entryIndex++
        $componentName = Get-GrlComponentName -Component $entry.Component
        $startPercent = 0
        $endPercent = 0
        if ($totalEntries -gt 0) {
            $startPercent = [int][Math]::Floor(($entryIndex - 1) * 100 / $totalEntries)
            $endPercent = [int][Math]::Floor($entryIndex * 100 / $totalEntries)
        }
        $stepStatus = (Get-GrlText -Key 'progress.component') -f $entryIndex, $totalEntries

        if ($entry.Skip) {
            Write-GrlProgress -Activity $componentName -Status ('{0} · {1}' -f $stepStatus, (Get-GrlText -Key 'install.installedSkipped')) -Percent $endPercent -Complete
            $items += [pscustomobject]@{
                ComponentId = $entry.Component.id
                DisplayName = $componentName
                Status = 'Skipped'
                ExitCode = 0
                Message = Get-GrlText -Key 'install.installedSkipped'
                DurationSeconds = 0
            }
            continue
        }

        $startedAt = Get-Date
        Write-GrlProgress -Activity $componentName -Status $stepStatus -Percent $startPercent -Complete
        Write-GrlMessage -Message ((Get-GrlText -Key 'install.installing') -f $componentName) -Level '信息' -Component 'Installer'
        try {
            $status = $null
            $exitCode = 0
            $message = $null
            if ($entry.Component.installer.type -eq 'WindowsFeature') {
                $exitCode = Invoke-GrlWindowsFeatureInstaller -Component $entry.Component -AllowNetwork $Plan.AllowNetwork -FeatureSource $entry.FeatureSource
                $status = Get-GrlInstalledExitCategory -ExitCode $exitCode
            }
            else {
                $failures = @()
                $hadRestart = $false
                $installablePackages = @($entry.Packages | Where-Object { -not $_.Skip })
                $packageTotal = $installablePackages.Count
                $packageIndex = 0
                foreach ($packagePlan in @($entry.Packages)) {
                    if ($packagePlan.Skip) {
                        continue
                    }
                    $packageIndex++
                    $packageName = [string]$packagePlan.Definition.fileName
                    Write-GrlMessage -Message ('  ' + ((Get-GrlText -Key 'progress.package') -f $packageIndex, $packageTotal, $packageName)) -Level '信息' -Component 'Installer'
                    try {
                        $packageExitCode = Invoke-GrlPackageInstaller -Component $entry.Component -PackagePlan $packagePlan
                    }
                    catch {
                        $failures += [pscustomobject]@{
                            FileName = $packageName
                            ExitCode = -1
                            Message = $_.Exception.Message
                        }
                        Write-GrlMessage -Message ("{0}: {1}" -f $packageName, $_.Exception.Message) -Level '错误' -Component 'Installer'
                        continue
                    }
                    $packageCategory = Get-GrlInstalledExitCategory -ExitCode $packageExitCode
                    if ($packageCategory -eq 'RestartRequired') {
                        $hadRestart = $true
                        continue
                    }
                    if ($packageCategory -eq 'Failed') {
                        $failures += [pscustomobject]@{
                            FileName = $packageName
                            ExitCode = $packageExitCode
                            Message = "安装程序退出码：$packageExitCode"
                        }
                        Write-GrlMessage -Message ("{0}: 安装程序退出码 {1}" -f $packageName, $packageExitCode) -Level '错误' -Component 'Installer'
                    }
                }

                if ($failures.Count -gt 0) {
                    $detailParts = @($failures | ForEach-Object {
                        if ($_.ExitCode -ge 0) {
                            '{0}（退出码 {1}）' -f $_.FileName, $_.ExitCode
                        }
                        else {
                            '{0}（未获得退出码）' -f $_.FileName
                        }
                    })
                    $status = 'Failed'
                    if ($failures[0].ExitCode -ge 0) {
                        $exitCode = [int]$failures[0].ExitCode
                    }
                    else {
                        $exitCode = -1
                    }
                    $message = '{0} 个安装包失败：{1}' -f $failures.Count, ($detailParts -join '、')
                }
                elseif ($hadRestart) {
                    $status = 'RestartRequired'
                    $exitCode = 3010
                }
                else {
                    $status = 'Succeeded'
                    $exitCode = 0
                }
            }

            if ([string]::IsNullOrWhiteSpace($message)) {
                $skippedPackageCount = @($entry.Packages | Where-Object { $_.Skip }).Count
                if ($status -eq 'RestartRequired') {
                    $message = Get-GrlText -Key 'install.completedRestart'
                }
                elseif ($skippedPackageCount -gt 0) {
                    $message = (Get-GrlText -Key 'install.completedSkipped') -f $skippedPackageCount
                }
                else {
                    $message = Get-GrlText -Key 'install.completed'
                }
            }

            $items += [pscustomobject]@{
                ComponentId = $entry.Component.id
                DisplayName = $componentName
                Status = $status
                ExitCode = $exitCode
                Message = $message
                DurationSeconds = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
            }
            $level = '成功'
            if ($status -eq 'Failed') {
                $level = '错误'
            }
            Write-GrlMessage -Message ("{0}: {1}" -f $componentName, $message) -Level $level -Component 'Installer'

            $statusLabel = switch ($status) {
                'Succeeded' { Get-GrlText -Key 'install.succeeded' }
                'RestartRequired' { Get-GrlText -Key 'install.restartRequired' }
                'Failed' { Get-GrlText -Key 'install.failed' }
                default { [string]$status }
            }
            Write-GrlProgress -Activity $componentName -Status ('{0} · {1}' -f $statusLabel, $message) -Percent $endPercent -Complete
        }
        catch {
            $items += [pscustomobject]@{
                ComponentId = $entry.Component.id
                DisplayName = Get-GrlComponentName -Component $entry.Component
                Status = 'Failed'
                ExitCode = -1
                Message = $_.Exception.Message
                DurationSeconds = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
            }
            Write-GrlMessage -Message ("{0}: {1}" -f (Get-GrlComponentName -Component $entry.Component), $_.Exception.Message) -Level '错误' -Component 'Installer'
            Write-GrlProgress -Activity $componentName -Status ('{0} · {1}' -f (Get-GrlText -Key 'install.failed'), $_.Exception.Message) -Percent $endPercent -Complete
        }
        finally {
            Clear-GrlDetectionCache
        }
    }

    $failed = @($items | Where-Object { $_.Status -eq 'Failed' })
    $restart = @($items | Where-Object { $_.Status -eq 'RestartRequired' })
    $exitCode = 0
    if ($failed.Count -gt 0) {
        $featureOnly = $failed.Count -eq 1 -and $failed[0].ComponentId -in @('dotnet35', 'directplay') -and $failed[0].Message -match '功能'
        $exitCode = if ($featureOnly) { 60 } else { 40 }
    }
    elseif ($restart.Count -gt 0) {
        $exitCode = 10
    }

    Write-GrlProgress -Activity (Get-GrlText -Key 'progress.installing') -Status (Get-GrlText -Key 'install.summaryComplete') -Percent 100 -Complete

    return [pscustomobject]@{
        ExitCode = $exitCode
        Items = @($items)
        SummaryText = if ($failed.Count -gt 0) { (Get-GrlText -Key 'install.summaryPartial') -f $failed.Count } elseif ($restart.Count -gt 0) { Get-GrlText -Key 'install.summaryRestart' } else { Get-GrlText -Key 'install.summaryComplete' }
    }
}

function Write-GrlInstallationResult {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items,
        [Parameter(Mandatory = $true)]
        [object[]]$States,
        [int]$ExitCode = 0
    )

    $restartIds = @($Items | Where-Object { $_.Status -eq 'RestartRequired' } | ForEach-Object { [string]$_.ComponentId })
    $failedIds = @($Items | Where-Object { $_.Status -eq 'Failed' } | ForEach-Object { [string]$_.ComponentId })
    $installed = @($States | Where-Object { $_.State -eq 'Installed' })
    $notInstalled = @($States | Where-Object { $_.State -ne 'Installed' -and $restartIds -notcontains [string]$_.Id })

    $consoleWidth = [Math]::Min(78, (Get-GrlConsoleWidth))
    Write-Host ''
    Write-Host ('=' * $consoleWidth) -ForegroundColor Cyan
    Write-Host (Get-GrlText -Key 'result.title') -ForegroundColor Cyan
    Write-Host ('-' * $consoleWidth) -ForegroundColor DarkGray
    Write-Host ((Get-GrlText -Key 'result.summary') -f $States.Count, $installed.Count, $restartIds.Count, $notInstalled.Count, $failedIds.Count)

    if ($notInstalled.Count -gt 0) {
        Write-Host (Get-GrlText -Key 'result.notInstalledTitle') -ForegroundColor Yellow
        foreach ($state in $notInstalled) {
            Write-Host ((Get-GrlText -Key 'result.item') -f $state.DisplayName, $state.Summary) -ForegroundColor Yellow
        }
    }
    else {
        Write-Host (Get-GrlText -Key 'result.allInstalled') -ForegroundColor Green
    }

    if ($restartIds.Count -gt 0) {
        Write-Host (Get-GrlText -Key 'result.restartHint') -ForegroundColor Yellow
    }
    if ($failedIds.Count -gt 0) {
        Write-Host (Get-GrlText -Key 'result.failureHint') -ForegroundColor Red
    }
    Write-Host ('=' * $consoleWidth) -ForegroundColor Cyan

    $logMessage = (Get-GrlText -Key 'result.summary') -f $States.Count, $installed.Count, $restartIds.Count, $notInstalled.Count, $failedIds.Count
    Write-GrlLog -Level '信息' -Message ("安装结果：$logMessage") -Component 'Installer'

    return [pscustomobject]@{
        Installed = @($installed)
        NotInstalled = @($notInstalled)
        Restart = @($restartIds)
        Failed = @($failedIds)
        ExitCode = $ExitCode
    }
}

function Write-GrlInstallationSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items
    )

    $consoleWidth = Get-GrlConsoleWidth
    $nameWidth = 34
    $statusWidth = 12
    $gap = 2
    $messageWidth = [Math]::Max(12, $consoleWidth - $nameWidth - $statusWidth - ($gap * 2))
    Write-Host ''
    $header = (Format-GrlDisplayCell -Value (Get-GrlText -Key 'install.summaryComponent') -Width $nameWidth) + (' ' * $gap) +
        (Format-GrlDisplayCell -Value (Get-GrlText -Key 'install.summaryResult') -Width $statusWidth) + (' ' * $gap) +
        (Format-GrlDisplayCell -Value (Get-GrlText -Key 'install.summaryMessage') -Width $messageWidth)
    Write-Host $header -ForegroundColor Cyan
    Write-Host ('-' * $consoleWidth) -ForegroundColor DarkGray
    $colors = @{ Skipped = 'DarkGray'; Succeeded = 'Green'; RestartRequired = 'Yellow'; Failed = 'Red' }
    $labels = @{
        Skipped = Get-GrlText -Key 'install.skipped'
        Succeeded = Get-GrlText -Key 'install.succeeded'
        RestartRequired = Get-GrlText -Key 'install.restartRequired'
        Failed = Get-GrlText -Key 'install.failed'
    }
    foreach ($item in $Items) {
        Write-Host (Format-GrlDisplayCell -Value $item.DisplayName -Width $nameWidth) -NoNewline
        Write-Host (' ' * $gap) -NoNewline
        Write-Host (Format-GrlDisplayCell -Value $labels[$item.Status] -Width $statusWidth) -ForegroundColor $colors[$item.Status] -NoNewline
        Write-Host (' ' * $gap) -NoNewline
        Write-Host (Format-GrlDisplayCell -Value $item.Message -Width $messageWidth)
    }
}

Export-ModuleMember -Function Get-GrlPackageDirectory, Resolve-GrlFeatureSource, Test-GrlPackageAlreadyInstalled, Assert-GrlFreeSpace, New-GrlInstallationPlan, Invoke-GrlProcessWithRetry, Assert-GrlInnerInstaller, Invoke-GrlPackageInstaller, Invoke-GrlWindowsFeatureInstaller, Get-GrlInstalledExitCategory, Start-GrlInstallationPlan, Write-GrlInstallationSummary, Write-GrlInstallationResult
