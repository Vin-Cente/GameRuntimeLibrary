$ErrorActionPreference = 'Stop'

$script:UiCatalog = $null
$script:UiLanguage = 'zh-CN'

function Get-GrlUiSettingsPath {
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) {
        $base = Join-Path $HOME 'AppData\Local'
    }
    return Join-Path (Join-Path $base 'GameRuntimeLibrary') 'ui-settings.json'
}

function Initialize-GrlLocalization {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    $path = Join-Path $RootPath 'config\ui-text.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw '界面语言配置 config\ui-text.json 不存在。'
    }
    $catalog = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($catalog.schemaVersion -ne 1 -or $null -eq $catalog.languages -or $catalog.languages.Count -eq 0) {
        throw '界面语言配置格式无效。'
    }
    $script:UiCatalog = $catalog
    if (-not (Test-GrlLanguageCode -Language $script:UiLanguage)) {
        $script:UiLanguage = [string]$catalog.defaultLanguage
    }
}

function Test-GrlLanguageCode {
    param(
        [string]$Language
    )
    if ($null -eq $script:UiCatalog -or [string]::IsNullOrWhiteSpace($Language)) {
        return $false
    }
    return @($script:UiCatalog.languages | Where-Object { $_.code -eq $Language }).Count -gt 0
}

function Get-GrlLanguages {
    if ($null -eq $script:UiCatalog) {
        return @()
    }
    return @($script:UiCatalog.languages)
}

function Get-GrlCurrentLanguage {
    return $script:UiLanguage
}

function Set-GrlLanguage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Language
    )
    if (-not (Test-GrlLanguageCode -Language $Language)) {
        throw "不支持的语言：$Language"
    }
    $script:UiLanguage = $Language
}

function Get-GrlText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [string]$Fallback = ''
    )
    if ($null -eq $script:UiCatalog) {
        if ($Fallback) { return $Fallback }
        return $Key
    }
    $node = $script:UiCatalog.text.PSObject.Properties[$script:UiLanguage].Value
    foreach ($segment in $Key.Split('.')) {
        if ($null -eq $node) {
            break
        }
        $property = $node.PSObject.Properties[$segment]
        if ($null -eq $property) {
            $node = $null
            break
        }
        $node = $property.Value
    }
    if ($null -eq $node -or $node -is [pscustomobject]) {
        if ($Fallback) { return $Fallback }
        return $Key
    }
    return [string]$node
}

function Get-GrlComponentName {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Component
    )
    return Get-GrlText -Key ("components." + [string]$Component.id) -Fallback ([string]$Component.displayName)
}

function Read-GrlLanguagePreference {
    param(
        [string]$SettingsPath = (Get-GrlUiSettingsPath)
    )
    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        return $null
    }
    try {
        $settings = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $language = [string]$settings.language
        if (Test-GrlLanguageCode -Language $language) {
            return $language
        }
    }
    catch {
        Write-Warning "Unable to read language preference: $SettingsPath"
    }
    return $null
}

function Save-GrlLanguagePreference {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Language,
        [string]$SettingsPath = (Get-GrlUiSettingsPath)
    )
    if (-not (Test-GrlLanguageCode -Language $Language)) {
        throw "不支持的语言：$Language"
    }
    $directory = Split-Path -Parent $SettingsPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $settings = [ordered]@{
        schemaVersion = 1
        language = $Language
        updatedAt = (Get-Date).ToString('o')
    }
    $json = $settings | ConvertTo-Json -Depth 3
    $temporary = $SettingsPath + '.tmp'
    [System.IO.File]::WriteAllText($temporary, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $SettingsPath -Force
}

function Show-GrlLanguageSelector {
    param(
        [string]$SettingsPath = (Get-GrlUiSettingsPath)
    )
    if ($null -eq $script:UiCatalog) {
        throw '界面语言尚未初始化。'
    }

    while ($true) {
        Clear-Host
        Write-Host '============================================================' -ForegroundColor Cyan
        Write-Host '                    GameRuntimeLibrary' -ForegroundColor Cyan
        Write-Host '============================================================' -ForegroundColor Cyan
        Write-Host ''
        Write-Host (Get-GrlText -Key 'languageSelector.title' -Fallback '选择界面语言') -ForegroundColor Yellow
        Write-Host (Get-GrlText -Key 'languageSelector.subtitle' -Fallback 'Choose interface language') -ForegroundColor Yellow
        Write-Host ''
        $languages = @(Get-GrlLanguages)
        for ($index = 0; $index -lt $languages.Count; $index++) {
            Write-Host ("{0}. {1}" -f ($index + 1), $languages[$index].displayName)
        }
        Write-Host '0. 退出 / Exit'
        Write-Host ''
        $choice = Read-Host (Get-GrlText -Key 'languageSelector.prompt' -Fallback '请选择 / Select')
        if ($choice -eq '0') {
            return $null
        }
        if ($choice -match '^\d+$') {
            $number = [int]$choice
            if ($number -ge 1 -and $number -le $languages.Count) {
                $selected = [string]$languages[$number - 1].code
                Set-GrlLanguage -Language $selected
                Save-GrlLanguagePreference -Language $selected -SettingsPath $SettingsPath
                return $selected
            }
        }
        Write-Host (Get-GrlText -Key 'languageSelector.invalid' -Fallback '请输入有效序号。 / Enter a valid number.') -ForegroundColor Red
        Start-Sleep -Milliseconds 700
    }
}

function Resolve-GrlLanguage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath,
        [string]$RequestedLanguage = 'Auto',
        [switch]$Interactive,
        [string]$SettingsPath = (Get-GrlUiSettingsPath)
    )
    Initialize-GrlLocalization -RootPath $RootPath

    if ($RequestedLanguage -ne 'Auto') {
        Set-GrlLanguage -Language $RequestedLanguage
        Save-GrlLanguagePreference -Language $RequestedLanguage -SettingsPath $SettingsPath
        return $RequestedLanguage
    }

    $saved = Read-GrlLanguagePreference -SettingsPath $SettingsPath
    if (-not [string]::IsNullOrWhiteSpace($saved)) {
        Set-GrlLanguage -Language $saved
        return $saved
    }

    if ($Interactive) {
        return Show-GrlLanguageSelector -SettingsPath $SettingsPath
    }

    $defaultLanguage = [string]$script:UiCatalog.defaultLanguage
    Set-GrlLanguage -Language $defaultLanguage
    return $defaultLanguage
}

function Switch-GrlLanguage {
    param(
        [string]$SettingsPath = (Get-GrlUiSettingsPath)
    )
    $selected = Show-GrlLanguageSelector -SettingsPath $SettingsPath
    if ($null -ne $selected) {
        Write-Host (Get-GrlText -Key 'languageSelector.changed') -ForegroundColor Green
        Start-Sleep -Milliseconds 500
    }
    return $selected
}

Export-ModuleMember -Function Get-GrlUiSettingsPath, Initialize-GrlLocalization, Test-GrlLanguageCode, Get-GrlLanguages, Get-GrlCurrentLanguage, Set-GrlLanguage, Get-GrlText, Get-GrlComponentName, Read-GrlLanguagePreference, Save-GrlLanguagePreference, Show-GrlLanguageSelector, Resolve-GrlLanguage, Switch-GrlLanguage
