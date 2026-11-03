[CmdletBinding()]
param(
    [ValidateSet('Menu', 'InstallOnline', 'PrepareOffline', 'InstallOffline', 'Verify', 'Status', 'DllStatus', 'RepairMissing')]
    [string]$Action = 'Menu',
    [string[]]$ComponentId,
    [string]$OfflineRoot,
    [string]$FeatureSource,
    [switch]$AllowUnsupportedOS,
    [switch]$NonInteractive,
    [switch]$WhatIf,
    [ValidateSet('Auto', 'zh-CN', 'en-US')]
    [string]$Language = 'Auto'
)

$rootEntry = Join-Path (Split-Path $PSScriptRoot -Parent) 'Start-GameRuntimeLibrary.ps1'
& $rootEntry -Profile 'Windows10-x86' -Action $Action -ComponentId $ComponentId -OfflineRoot $OfflineRoot -FeatureSource $FeatureSource -Language $Language -AllowUnsupportedOS:$AllowUnsupportedOS -NonInteractive:$NonInteractive -WhatIf:$WhatIf
exit $LASTEXITCODE
