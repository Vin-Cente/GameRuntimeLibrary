[CmdletBinding()]
param(
    [string]$RootPath,
    [switch]$SkipAnalyzer
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RootPath)) {
    $RootPath = Split-Path -Parent $PSScriptRoot
}
$RootPath = (Resolve-Path -LiteralPath $RootPath).ProviderPath

$script:Failures = New-Object System.Collections.ArrayList
$script:ExcludedPattern = '[\\/](dist|\.git|\.workbuddy)[\\/]'

function Add-Failure {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Category,
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    [void]$script:Failures.Add(('[{0}] {1}' -f $Category, $Message))
}

function Write-CheckResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [bool]$Passed,
        [string]$Detail = ''
    )
    if ($Passed) {
        Write-Host ('  [通过] {0} {1}' -f $Name, $Detail) -ForegroundColor Green
    }
    else {
        Write-Host ('  [失败] {0} {1}' -f $Name, $Detail) -ForegroundColor Red
    }
}

function Get-TargetScriptFile {
    return @(Get-ChildItem -LiteralPath $RootPath -Recurse -File | Where-Object {
            ($_.Extension -eq '.ps1' -or $_.Extension -eq '.psm1') -and
            $_.FullName -notmatch $script:ExcludedPattern
        })
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    return $Path.Substring($RootPath.Length).TrimStart('\', '/')
}

function Get-FlatTextMap {
    param(
        [object]$Node,
        [string]$Prefix = ''
    )
    $map = @{}
    if ($null -eq $Node) {
        return $map
    }
    foreach ($property in $Node.PSObject.Properties) {
        if ($Prefix.Length -gt 0) {
            $key = $Prefix + '.' + $property.Name
        }
        else {
            $key = $property.Name
        }
        $value = $property.Value
        if ($null -ne $value -and $value -is [System.Management.Automation.PSCustomObject]) {
            $childMap = Get-FlatTextMap -Node $value -Prefix $key
            foreach ($childKey in $childMap.Keys) {
                $map[$childKey] = $childMap[$childKey]
            }
        }
        else {
            $map[$key] = [string]$value
        }
    }
    return $map
}

function Test-ScriptSyntax {
    $files = @(Get-TargetScriptFile)
    $errorCount = 0
    foreach ($file in $files) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
        foreach ($parseError in $parseErrors) {
            $errorCount++
            Add-Failure -Category '语法' -Message ('{0}:{1} {2}' -f (Get-RelativePath -Path $file.FullName), $parseError.Extent.StartLineNumber, $parseError.Message)
        }
    }
    Write-CheckResult -Name '语法检查' -Passed ($errorCount -eq 0) -Detail ('扫描 {0} 个 PowerShell 文件' -f $files.Count)
}

function Test-UiTextCatalog {
    $path = Join-Path -Path $RootPath -ChildPath 'config\ui-text.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Add-Failure -Category '界面文本' -Message 'config\ui-text.json 不存在'
        Write-CheckResult -Name '界面文本键一致性' -Passed $false -Detail '缺少 config\ui-text.json'
        return
    }

    try {
        $catalog = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        Add-Failure -Category '界面文本' -Message ('config\ui-text.json 解析失败：{0}' -f $_.Exception.Message)
        Write-CheckResult -Name '界面文本键一致性' -Passed $false -Detail 'JSON 解析失败'
        return
    }

    $zhNode = $catalog.text.'zh-CN'
    $enNode = $catalog.text.'en-US'
    if ($null -eq $zhNode -or $null -eq $enNode) {
        Add-Failure -Category '界面文本' -Message '缺少 zh-CN 或 en-US 文本节点'
        Write-CheckResult -Name '界面文本键一致性' -Passed $false -Detail '缺少语言节点'
        return
    }

    $zh = Get-FlatTextMap -Node $zhNode
    $en = Get-FlatTextMap -Node $enNode
    $missingInEnglish = @($zh.Keys | Where-Object { -not $en.ContainsKey($_) } | Sort-Object)
    $missingInChinese = @($en.Keys | Where-Object { -not $zh.ContainsKey($_) } | Sort-Object)

    foreach ($key in $missingInEnglish) {
        Add-Failure -Category '界面文本' -Message ('en-US 缺少键：{0}' -f $key)
    }
    foreach ($key in $missingInChinese) {
        Add-Failure -Category '界面文本' -Message ('zh-CN 缺少键：{0}' -f $key)
    }
    if ($zh.Count -eq 0) {
        Add-Failure -Category '界面文本' -Message '界面文本为空'
    }

    $passed = ($missingInEnglish.Count -eq 0 -and $missingInChinese.Count -eq 0 -and $zh.Count -gt 0)
    Write-CheckResult -Name '界面文本键一致性' -Passed $passed -Detail ('zh-CN {0} 个键，en-US {1} 个键' -f $zh.Count, $en.Count)

    $script:UiTextKeys = $zh
}

function Get-SourceTextKey {
    $keys = New-Object System.Collections.Generic.List[string]
    $sourceDirectory = Join-Path -Path $RootPath -ChildPath 'src'
    if (-not (Test-Path -LiteralPath $sourceDirectory -PathType Container)) {
        return @()
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $sourceDirectory -Filter '*.psm1' -File)) {
        $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        foreach ($match in [regex]::Matches($content, "Get-GrlText\s+-Key\s+['""]([^'""]+)['""]")) {
            [void]$keys.Add($match.Groups[1].Value)
        }
    }
    return @($keys | Sort-Object -Unique)
}

function Test-SourceTextKeyCoverage {
    if ($null -eq $script:UiTextKeys -or $script:UiTextKeys.Count -eq 0) {
        Write-CheckResult -Name '源码文本键覆盖' -Passed $false -Detail '界面文本不可用，跳过覆盖检查'
        return
    }
    $keys = @(Get-SourceTextKey)
    $missing = @($keys | Where-Object { -not $script:UiTextKeys.ContainsKey($_) })
    foreach ($key in $missing) {
        Add-Failure -Category '源码文本键' -Message ('zh-CN 文本缺少源码使用的键：{0}' -f $key)
    }
    Write-CheckResult -Name '源码文本键覆盖' -Passed ($missing.Count -eq 0) -Detail ('源码使用 {0} 个键' -f $keys.Count)
}

function Test-ReadmeLink {
    $readmePath = Join-Path -Path $RootPath -ChildPath 'README.md'
    if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) {
        Add-Failure -Category 'README' -Message 'README.md 不存在'
        Write-CheckResult -Name 'README 本地链接' -Passed $false -Detail 'README.md 不存在'
        return
    }

    $content = Get-Content -LiteralPath $readmePath -Raw -Encoding UTF8
    $checked = 0
    $broken = 0
    foreach ($match in [regex]::Matches($content, '\]\(([^)]+)\)')) {
        $target = $match.Groups[1].Value.Trim()
        if ($target -match '^(?i)(https?:|mailto:|#)') {
            continue
        }
        $target = $target.Split('#')[0].Trim()
        if ($target.Length -eq 0) {
            continue
        }
        if ($target -notmatch '\.(md|markdown|ps1|psm1|json|ya?ml|cmd|txt)$') {
            continue
        }
        $checked++
        $candidate = Join-Path -Path $RootPath -ChildPath ($target -replace '/', '\')
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $broken++
            Add-Failure -Category 'README' -Message ('相对链接指向不存在的文件：{0}' -f $target)
        }
    }
    Write-CheckResult -Name 'README 本地链接' -Passed ($broken -eq 0) -Detail ('检查 {0} 个相对链接' -f $checked)
}

function Invoke-AnalyzerCheck {
    param(
        [switch]$SkipAnalyzer
    )
    if ($SkipAnalyzer) {
        Write-Host '  [跳过] PSScriptAnalyzer（已显式跳过）' -ForegroundColor Yellow
        return
    }

    $available = @(Get-Module -ListAvailable -Name PSScriptAnalyzer)
    if ($available.Count -eq 0) {
        Write-Host '  [跳过] 未安装 PSScriptAnalyzer，跳过静态规则检查（不视为失败）' -ForegroundColor Yellow
        Write-Host '         安装方式：Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -SkipPublisherCheck' -ForegroundColor DarkGray
        return
    }

    $settingsPath = Join-Path -Path $RootPath -ChildPath 'PSScriptAnalyzerSettings.psd1'
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        Add-Failure -Category '静态检查' -Message 'PSScriptAnalyzerSettings.psd1 不存在'
        Write-CheckResult -Name 'PSScriptAnalyzer' -Passed $false -Detail '缺少配置文件'
        return
    }

    try {
        Import-Module -Name PSScriptAnalyzer -Force -ErrorAction Stop
    }
    catch {
        Write-Host ('  [跳过] PSScriptAnalyzer 导入失败：{0}' -f $_.Exception.Message) -ForegroundColor Yellow
        return
    }

    $issues = @()
    # release-lock.ps1 由构建脚本生成，是供 dot-source 的数据文件；其中的变量在该文件内本就不会被读取。
    $analyzerFiles = @(Get-TargetScriptFile | Where-Object { $_.Name -ne 'release-lock.ps1' })
    foreach ($file in $analyzerFiles) {
        $fileIssues = @(Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settingsPath)
        foreach ($issue in $fileIssues) {
            if ($issue.Severity -eq 'Error' -or $issue.Severity -eq 'Warning') {
                $issues += $issue
            }
        }
    }

    foreach ($issue in $issues) {
        Add-Failure -Category '静态检查' -Message ('{0}:{1} [{2}] {3}' -f (Get-RelativePath -Path $issue.ScriptPath), $issue.Line, $issue.RuleName, $issue.Message)
    }
    Write-CheckResult -Name 'PSScriptAnalyzer' -Passed ($issues.Count -eq 0) -Detail ('发现 {0} 条 Error/Warning' -f $issues.Count)
}

Write-Host 'GameRuntimeLibrary 质量检查' -ForegroundColor Cyan
Write-Host ('项目根目录：{0}' -f $RootPath) -ForegroundColor DarkGray
Write-Host ''

$script:UiTextKeys = $null

Test-ScriptSyntax
Test-UiTextCatalog
Test-SourceTextKeyCoverage
Test-ReadmeLink
Invoke-AnalyzerCheck -SkipAnalyzer:$SkipAnalyzer

Write-Host ''
if ($script:Failures.Count -gt 0) {
    Write-Host ('检查未通过，共 {0} 项问题：' -f $script:Failures.Count) -ForegroundColor Red
    foreach ($failure in $script:Failures) {
        Write-Host ('  - {0}' -f $failure) -ForegroundColor Red
    }
    exit 1
}

Write-Host '全部检查通过。' -ForegroundColor Green
exit 0
