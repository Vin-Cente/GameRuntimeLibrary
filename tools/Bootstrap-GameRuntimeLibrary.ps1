[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$RepositoryUrl,
    [string]$Branch,
    [string]$InstallRoot,
    [ValidateSet('Auto', 'zh-CN', 'en-US')]
    [string]$Language = 'Auto',
    [switch]$NoUpdate,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$localRoot = Split-Path $PSScriptRoot -Parent
$settingsPath = Join-Path $env:LOCALAPPDATA 'GameRuntimeLibrary\bootstrap.json'

try {
    Import-Module -Name (Join-Path $localRoot 'src\GameRuntimeLibrary.Bootstrap.psm1') -Force

    if ($NoUpdate) {
        $targetRoot = $localRoot
        Write-Host "使用当前本地目录：$targetRoot" -ForegroundColor DarkGray
    }
    else {
        $settings = Read-GrlBootstrapSettings -SettingsPath $settingsPath
        $gitPath = Get-GrlGitExecutable
        $localRepositoryUrl = Get-GrlLocalGitHubOrigin -GitPath $gitPath -LocalRoot $localRoot
        $repository = Resolve-GrlBootstrapRepository -RepositoryUrl $RepositoryUrl -SettingsRepositoryUrl $settings.RepositoryUrl -LocalRepositoryUrl $localRepositoryUrl -Interactive:(-not $NoLaunch)
        $effectiveBranch = if ([string]::IsNullOrWhiteSpace($Branch)) { [string]$settings.Branch } else { $Branch }
        Assert-GrlGitHubBranch -Branch $effectiveBranch | Out-Null
        $targetRoot = if ([string]::IsNullOrWhiteSpace($InstallRoot)) { [string]$settings.InstallRoot } else { $InstallRoot }
        $targetRoot = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($targetRoot))
        if ([string]::IsNullOrWhiteSpace($targetRoot)) {
            throw '安装目录无效。'
        }

        $result = Update-GrlRuntimeRepository -InstallRoot $targetRoot -Repository $repository -Branch $effectiveBranch
        Save-GrlBootstrapSettings -SettingsPath $settingsPath -RepositoryUrl $repository.CloneUrl -Branch $effectiveBranch -InstallRoot $targetRoot
        Write-Host "GitHub 仓库已更新：$($repository.CloneUrl)" -ForegroundColor Green
        Write-Host "安装目录：$($result.InstallRoot)" -ForegroundColor Green
        Write-Host "更新方式：$($result.Method)" -ForegroundColor DarkGray
    }

    if (-not $NoLaunch) {
        Start-GrlBootstrapMenu -InstallRoot $targetRoot -Language $Language | Out-Null
        Write-Host '已打开运行库安装菜单。' -ForegroundColor Green
    }
    exit 0
}
catch {
    Write-Host "启动器失败：$($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
