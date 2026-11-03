[CmdletBinding()]
param(
    [string]$RootPath,
    [string]$TestName,
    [switch]$ParseOnly
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $RootPath = Split-Path $PSScriptRoot -Parent
}

$parseFailures = @()
$files = Get-ChildItem -LiteralPath $RootPath -Recurse -File | Where-Object {
    $_.Extension -in @('.ps1', '.psm1') -and
    $_.FullName -notmatch '[\\/](dist|\.git|\.workbuddy)[\\/]'
}
foreach ($file in $files) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    foreach ($parseError in $parseErrors) {
        $parseFailures += [pscustomobject]@{
            File = $file.FullName
            Line = $parseError.Extent.StartLineNumber
            Message = $parseError.Message
        }
    }
}
if ($parseFailures.Count -gt 0) {
    $parseFailures | Format-Table -Wrap -AutoSize
    exit 1
}
Write-Host "语法检查通过：$($files.Count) 个 PowerShell 文件" -ForegroundColor Green
if ($ParseOnly) {
    exit 0
}

if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Host 'Pester 3.x 断言依赖 Windows PowerShell 5.1，请改用 powershell.exe 运行本脚本。' -ForegroundColor Yellow
    exit 1
}

$pesterModule = Get-Module -ListAvailable Pester |
    Where-Object { $_.Version.Major -eq 3 } |
    Sort-Object -Property Version -Descending |
    Select-Object -First 1
if ($null -eq $pesterModule) {
    throw '未找到 Pester 3.x。请安装：Install-Module Pester -RequiredVersion 3.4.0 -Scope CurrentUser -Force'
}
Import-Module -Name $pesterModule.Path -Force

$testFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File | Sort-Object Name | ForEach-Object { $_.FullName })
if ($testFiles.Count -eq 0) {
    throw "未找到测试文件：$PSScriptRoot"
}

$invokeParameters = @{
    Script = $testFiles
    PassThru = $true
}
if (-not [string]::IsNullOrWhiteSpace($TestName)) {
    $invokeParameters['TestName'] = $TestName
}
$result = Invoke-Pester @invokeParameters
if ($result.FailedCount -gt 0) {
    exit 1
}
exit 0
