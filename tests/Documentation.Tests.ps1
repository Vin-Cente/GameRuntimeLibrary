$script:Root = Split-Path $PSScriptRoot -Parent

function Get-DocumentationTextKey {
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
            $childMap = Get-DocumentationTextKey -Node $value -Prefix $key
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

Describe '文档与配置' {
    It '包含必需的项目文件' {
        $required = @(
            'docs\SECURITY.md',
            'docs\TROUBLESHOOTING.md',
            'CHANGELOG.md',
            '.github\workflows\ci.yml',
            'PSScriptAnalyzerSettings.psd1',
            'tools\Test-Quality.ps1'
        )
        foreach ($relative in $required) {
            $exists = Test-Path -LiteralPath (Join-Path $script:Root $relative) -PathType Leaf
            $exists | Should Be $true
        }
    }

    It 'README 包含必需小节' {
        $readme = Get-Content -LiteralPath (Join-Path $script:Root 'README.md') -Raw -Encoding UTF8
        foreach ($title in @('安全与信任', '日志与诊断', '故障排查', '开发与测试')) {
            $readme | Should Match ([regex]::Escape('## ' + $title))
        }
    }

    It 'README 不含孤立的列表符号' {
        $lines = @(Get-Content -LiteralPath (Join-Path $script:Root 'README.md') -Encoding UTF8)
        $isolated = @($lines | Where-Object { $_.Trim() -eq '-' })
        $isolated.Count | Should Be 0
    }

    It 'README 中的相对链接均指向存在的文件' {
        $readme = Get-Content -LiteralPath (Join-Path $script:Root 'README.md') -Raw -Encoding UTF8
        $missing = @()
        foreach ($match in [regex]::Matches($readme, '\]\(([^)]+)\)')) {
            $target = $match.Groups[1].Value.Trim()
            if ($target -match '^(?i)(https?:|mailto:|#)') {
                continue
            }
            $target = $target.Split('#')[0].Trim()
            if ($target.Length -eq 0 -or $target -notmatch '\.(md|markdown|ps1|psm1|json|ya?ml|cmd|txt)$') {
                continue
            }
            $candidate = Join-Path $script:Root ($target -replace '/', '\')
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                $missing += $target
            }
        }
        ($missing -join '; ') | Should Be ''
    }

    It '中英文界面文本键集合一致' {
        $catalog = Get-Content -LiteralPath (Join-Path $script:Root 'config\ui-text.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $chinese = Get-DocumentationTextKey -Node $catalog.text.'zh-CN'
        $english = Get-DocumentationTextKey -Node $catalog.text.'en-US'

        $chinese.Count | Should BeGreaterThan 100
        $english.Count | Should Be $chinese.Count

        $missingInEnglish = @($chinese.Keys | Where-Object { -not $english.ContainsKey($_) } | Sort-Object)
        $missingInChinese = @($english.Keys | Where-Object { -not $chinese.ContainsKey($_) } | Sort-Object)
        ($missingInEnglish -join '; ') | Should Be ''
        ($missingInChinese -join '; ') | Should Be ''
    }

    It '源码使用的界面文本键全部存在' {
        $catalog = Get-Content -LiteralPath (Join-Path $script:Root 'config\ui-text.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $chinese = Get-DocumentationTextKey -Node $catalog.text.'zh-CN'

        $keys = New-Object System.Collections.Generic.List[string]
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $script:Root 'src') -Filter '*.psm1' -File)) {
            $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
            foreach ($match in [regex]::Matches($content, "Get-GrlText\s+-Key\s+['""]([^'""]+)['""]")) {
                [void]$keys.Add($match.Groups[1].Value)
            }
        }

        $missing = @($keys | Sort-Object -Unique | Where-Object { -not $chinese.ContainsKey($_) })
        ($missing -join '; ') | Should Be ''
    }

    It 'DLL 清单覆盖全部组件' {
        $catalog = Get-Content -LiteralPath (Join-Path $script:Root 'config\catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $dllMap = Get-Content -LiteralPath (Join-Path $script:Root 'config\dll-map.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $mappedIds = @($dllMap.items | ForEach-Object { $_.componentId })
        $missing = @($catalog.components | Where-Object { $mappedIds -notcontains $_.id } | ForEach-Object { $_.id })
        ($missing -join '; ') | Should Be ''
    }
}
