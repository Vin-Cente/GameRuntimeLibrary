[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Windows11-x64', 'Windows10-x64', 'Windows10-x86')]
    [Alias('Profile')]
    [string]$ProfileId = 'Auto',
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

$ErrorActionPreference = 'Stop'
$GameRuntimeReleaseChannel = 'Development'
$rootPath = $PSScriptRoot

function Assert-GameRuntimeBootstrapIntegrity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [Parameter(Mandatory = $true)]
        [string]$ReleaseChannel,
        [Parameter(Mandatory = $true)]
        [string]$EntryScriptPath
    )

    $lockPath = Join-Path $RootPath 'config\release-lock.ps1'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        throw '发布清单 config\release-lock.ps1 不存在。'
    }

    if ($ReleaseChannel -eq 'Production') {
        $entrySignature = Get-AuthenticodeSignature -LiteralPath $EntryScriptPath
        if ($entrySignature.Status -ne 'Valid') {
            throw "正式版入口签名无效：$($entrySignature.Status)。"
        }

        $lockSignature = Get-AuthenticodeSignature -LiteralPath $lockPath
        if ($lockSignature.Status -ne 'Valid') {
            throw "正式版发布清单签名无效：$($lockSignature.Status)。"
        }
    }

    $GameRuntimeReleaseLock = $null
    . $lockPath
    if ($null -eq $GameRuntimeReleaseLock) {
        throw '发布清单未定义 GameRuntimeReleaseLock。'
    }

    if ($ReleaseChannel -eq 'Production') {
        $expectedThumbprint = [string]$GameRuntimeReleaseLock.CertificateThumbprint
        if ([string]::IsNullOrWhiteSpace($expectedThumbprint)) {
            throw '正式版发布清单缺少证书指纹。'
        }
        $entrySignature = Get-AuthenticodeSignature -LiteralPath $EntryScriptPath
        if ($null -eq $entrySignature.SignerCertificate -or $entrySignature.SignerCertificate.Thumbprint -ne $expectedThumbprint) {
            throw '正式版入口证书指纹不匹配。'
        }
        $lockSignature = Get-AuthenticodeSignature -LiteralPath $lockPath
        if ($null -eq $lockSignature.SignerCertificate -or $lockSignature.SignerCertificate.Thumbprint -ne $expectedThumbprint) {
            throw '正式版发布清单证书指纹不匹配。'
        }
    }

    if ($GameRuntimeReleaseLock.ReleaseKind -eq 'Production' -and $ReleaseChannel -ne 'Production') {
        throw '入口发布通道与正式发布清单不一致。'
    }

    foreach ($item in $GameRuntimeReleaseLock.Files.GetEnumerator()) {
        $filePath = Join-Path $RootPath $item.Key
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "发布文件缺失：$($item.Key)。"
        }

        $actualHash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash
        if ($actualHash -ne $item.Value) {
            throw "发布文件校验失败：$($item.Key)。"
        }

        if ($ReleaseChannel -eq 'Production' -and $filePath -match '\.(ps1|psm1)$') {
            $signature = Get-AuthenticodeSignature -LiteralPath $filePath
            if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Thumbprint -ne $expectedThumbprint) {
                throw "正式版脚本签名无效：$($item.Key)，状态 $($signature.Status)。"
            }
        }
    }

    if ($ReleaseChannel -eq 'Development') {
        Write-Verbose 'Development build: use a public CA certificate before production distribution.'
    }
}

try {
    Assert-GameRuntimeBootstrapIntegrity -RootPath $rootPath -ReleaseChannel $GameRuntimeReleaseChannel -EntryScriptPath $PSCommandPath

    $modulePath = Join-Path $rootPath 'src\GameRuntimeLibrary.psm1'
    Import-Module -Name $modulePath -Force -Global

    $result = Invoke-GameRuntimeLibrary -RootPath $rootPath -ProfileId $ProfileId -Action $Action -ComponentId $ComponentId -OfflineRoot $OfflineRoot -FeatureSource $FeatureSource -Language $Language -AllowUnsupportedOS:$AllowUnsupportedOS -NonInteractive:$NonInteractive -WhatIf:$WhatIf -ReleaseChannel $GameRuntimeReleaseChannel -EntryScriptPath $PSCommandPath
    $exitCode = 0
    if ($null -ne $result) {
        $exitCode = [int]$result.ExitCode
    }
    exit $exitCode
}
catch {
    Write-Host "启动失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 50
}
