[CmdletBinding()]
param(
    [string]$RootPath,
    [string[]]$PackageId,
    [switch]$RefreshFixedHashes
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $RootPath = Split-Path $PSScriptRoot -Parent
}
Import-Module -Name (Join-Path $RootPath 'src\GameRuntimeLibrary.psm1') -Force

$catalogPath = Join-Path $RootPath 'config\catalog.json'
$catalog = Import-GrlCatalog -RootPath $RootPath
$packages = @()
foreach ($component in $catalog.components) {
    foreach ($package in @($component.packages)) {
        if ($null -eq $PackageId -or $PackageId.Count -eq 0 -or $package.id -in $PackageId) {
            $packages += $package
        }
    }
}
if ($packages.Count -eq 0) {
    throw '没有匹配的安装包。'
}

$temporaryRoot = New-GrlTempDirectory -Purpose 'catalog-verify'
$results = @()
try {
    foreach ($package in $packages) {
        $probe = $package | Select-Object *
        if ($RefreshFixedHashes -and $package.hashPolicy -eq 'Fixed') {
            $probe.hashPolicy = 'SignedLatest'
            $probe.sha256 = ''
            $probe.size = $null
            $probe.minimumBytes = 1
            $probe.maximumBytes = 2147483648
        }
        $state = Invoke-GrlSafeDownload -Package $probe -DestinationDirectory $temporaryRoot -AllowedDomains $catalog.officialDomains -AllowNetwork
        $results += $state
        Write-Host "通过：$($package.id) $($state.Sha256)" -ForegroundColor Green
    }

    if ($RefreshFixedHashes) {
        foreach ($result in $results) {
            foreach ($component in $catalog.components) {
                foreach ($package in @($component.packages)) {
                    if ($package.id -eq $result.PackageId -and $package.hashPolicy -eq 'Fixed') {
                        $package.sha256 = $result.Sha256
                        $package.size = $result.Size
                    }
                }
            }
        }
        $catalog.generatedAt = (Get-Date).ToString('o')
        $json = $catalog | ConvertTo-Json -Depth 12
        [System.IO.File]::WriteAllText($catalogPath, $json, (New-Object System.Text.UTF8Encoding($false)))
        Write-Host '固定哈希已更新。请审查差异后再构建发布包。' -ForegroundColor Yellow
    }

    $results | Select-Object PackageId, Size, Sha256, HashPolicy, SignatureStatus, SignerSubject | Format-Table -Wrap -AutoSize
}
finally {
    Remove-GrlTempDirectory -Path $temporaryRoot
}
