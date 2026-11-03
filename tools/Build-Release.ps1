[CmdletBinding()]
param(
    [ValidateSet('Development', 'Production')]
    [string]$Mode = 'Development',
    [string]$RootPath,
    [string]$CertificateThumbprint,
    [string]$TimestampServer = 'http://timestamp.digicert.com',
    [string]$OutputDirectory,
    [switch]$SkipArchive
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $RootPath = Split-Path $PSScriptRoot -Parent
}
Import-Module -Name (Join-Path $RootPath 'src\GameRuntimeLibrary.psm1') -Force

function Get-GrlRuntimeRelativeFiles {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $files = @(
        'Start-GameRuntimeLibrary.ps1',
        'GameRuntimeLibrary.cmd',
        'README.md',
        'THIRD-PARTY-NOTICES.md',
        'CHANGELOG.md',
        'docs\SECURITY.md',
        'docs\TROUBLESHOOTING.md',
        'config\catalog.json',
        'config\profiles.json',
        'config\dll-map.json',
        'config\ui-text.json',
        'tools\Bootstrap-GameRuntimeLibrary.ps1'
    )
    $files += Get-ChildItem -LiteralPath (Join-Path $Root 'src') -Filter '*.psm1' -File | ForEach-Object { $_.FullName.Substring($Root.Length + 1) }
    foreach ($platform in @('Windows 11 x64', 'Windows 10 x64', 'Windows 10 x86')) {
        $files += Join-Path $platform 'Start-GameRuntimeLibrary.ps1'
        $files += Join-Path $platform 'GameRuntimeLibrary.cmd'
        $files += Join-Path $platform 'packages\README.md'
    }
    return @($files | Select-Object -Unique)
}

function Set-GrlReleaseChannel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$ReleaseKind
    )
    $path = Join-Path $Root 'Start-GameRuntimeLibrary.ps1'
    $content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    $pattern = "(?m)^[$]GameRuntimeReleaseChannel = '(Development|Production)'(?=\r?\n|\z)"
    if ($content -notmatch $pattern) {
        throw '未找到发布通道标记。'
    }
    $replacement = '$GameRuntimeReleaseChannel = ' + [char]39 + $ReleaseKind + [char]39
    $content = [regex]::Replace($content, $pattern, $replacement)
    [System.IO.File]::WriteAllText($path, $content, (New-Object System.Text.UTF8Encoding($true)))
}

function Get-GrlSigningCertificate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Thumbprint
    )
    $normalized = ($Thumbprint -replace '[^a-fA-F0-9]', '').ToUpperInvariant()
    $stores = @('Cert:\CurrentUser\My', 'Cert:\LocalMachine\My')
    foreach ($store in $stores) {
        $certificate = Get-ChildItem -Path $store | Where-Object {
            $_.Thumbprint -eq $normalized -and
            $_.HasPrivateKey -and
            ($_.EnhancedKeyUsageList.ObjectId.Value -contains '1.3.6.1.5.5.7.3.3')
        } | Select-Object -First 1
        if ($null -ne $certificate) {
            return $certificate
        }
    }
    throw "未找到带私钥和 Code Signing EKU 的证书：$Thumbprint"
}

function Set-GrlScriptSignatures {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [object]$Certificate,
        [Parameter(Mandatory = $true)]
        [string]$TimestampServer
    )
    $scripts = Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object {
        $_.Extension -in @('.ps1', '.psm1') -and $_.FullName -notmatch '[\\/]dist[\\/]'
    }
    foreach ($script in $scripts) {
        $signature = Set-AuthenticodeSignature -LiteralPath $script.FullName -Certificate $Certificate -HashAlgorithm SHA256 -TimestampServer $TimestampServer
        if ($signature.Status -ne 'Valid') {
            throw "签名失败：$($script.FullName)，状态 $($signature.Status)"
        }
        Write-Host "已签名：$($script.FullName.Substring($Root.Length + 1))"
    }
}

function New-GrlReleaseLockFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,
        [Parameter(Mandatory = $true)]
        [string]$ReleaseKind,
        [string]$Thumbprint
    )
    $entries = [ordered]@{}
    foreach ($relative in Get-GrlRuntimeRelativeFiles -Root $Root) {
        $path = Join-Path $Root $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "发布文件缺失：$relative"
        }
        $entries[$relative] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine('# 此文件由 tools\Build-Release.ps1 生成，请勿手工编辑。')
    [void]$builder.AppendLine('$GameRuntimeReleaseLock = [ordered]@{')
    [void]$builder.AppendLine("    SchemaVersion = 1")
    [void]$builder.AppendLine("    ReleaseKind = '$ReleaseKind'")
    [void]$builder.AppendLine("    GeneratedAt = '$(Get-Date -Format o)'")
    [void]$builder.AppendLine("    CertificateThumbprint = '$($Thumbprint.ToUpperInvariant())'")
    [void]$builder.AppendLine('    Files = [ordered]@{')
    foreach ($item in $entries.GetEnumerator()) {
        $escapedPath = $item.Key.Replace("'", "''")
        [void]$builder.AppendLine("        '$escapedPath' = '$($item.Value)'")
    }
    [void]$builder.AppendLine('    }')
    [void]$builder.AppendLine('}')
    $lockPath = Join-Path $Root 'config\release-lock.ps1'
    [System.IO.File]::WriteAllText($lockPath, $builder.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    return $entries
}

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $RootPath 'dist'
}
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$certificate = $null
if ($Mode -eq 'Production') {
    if ([string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
        throw '正式构建必须指定 -CertificateThumbprint。'
    }
    $certificate = Get-GrlSigningCertificate -Thumbprint $CertificateThumbprint
}

Set-GrlReleaseChannel -Root $RootPath -ReleaseKind $Mode
if ($Mode -eq 'Production') {
    Set-GrlScriptSignatures -Root $RootPath -Certificate $certificate -TimestampServer $TimestampServer
}

$thumbprint = if ($null -eq $certificate) { '' } else { $certificate.Thumbprint }
$entries = New-GrlReleaseLockFile -Root $RootPath -ReleaseKind $Mode -Thumbprint $thumbprint

if ($Mode -eq 'Production') {
    $lockPath = Join-Path $RootPath 'config\release-lock.ps1'
    $signature = Set-AuthenticodeSignature -LiteralPath $lockPath -Certificate $certificate -HashAlgorithm SHA256 -TimestampServer $TimestampServer
    if ($signature.Status -ne 'Valid') {
        throw "发布清单签名失败：$($signature.Status)"
    }
}

Test-GrlReleaseIntegrity -RootPath $RootPath -RequireProduction:($Mode -eq 'Production') | Out-Null
Write-Host "发布清单已生成，共固定 $($entries.Count) 个文件，模式：$Mode" -ForegroundColor Green

if (-not $SkipArchive) {
    $stagingRoot = New-GrlTempDirectory -Purpose 'source-release'
    try {
        Copy-GrlReleaseFiles -RootPath $RootPath -DestinationRoot $stagingRoot
        Test-GrlReleaseIntegrity -RootPath $stagingRoot -RequireProduction:($Mode -eq 'Production') | Out-Null
        $safeMode = $Mode.ToLowerInvariant()
        $zipPath = Join-Path $OutputDirectory "GameRuntimeLibrary-$safeMode-$(Get-Date -Format 'yyyyMMdd-HHmmss').zip"
        $partPath = $zipPath + '.tmp.zip'
        Compress-Archive -Path (Join-Path $stagingRoot '*') -DestinationPath $partPath -CompressionLevel Optimal -Force
        Move-Item -LiteralPath $partPath -Destination $zipPath
        Write-Host "运行时发布包：$zipPath" -ForegroundColor Green
    }
    finally {
        Remove-GrlTempDirectory -Path $stagingRoot
    }
}
