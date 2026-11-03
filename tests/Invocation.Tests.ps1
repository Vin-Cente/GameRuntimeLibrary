$script:RootPath = Split-Path $PSScriptRoot -Parent
Import-Module -Name (Join-Path $script:RootPath 'src\GameRuntimeLibrary.psm1') -Force

function Get-GrlFunctionParameterMap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    $commonParameters = @(
        'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction',
        'ErrorVariable', 'WarningVariable', 'InformationVariable', 'OutVariable',
        'OutBuffer', 'PipelineVariable', 'WhatIf', 'Confirm'
    )
    $map = @{}
    $files = @(Get-ChildItem -LiteralPath (Join-Path $RootPath 'src') -Filter '*.psm1' -File)
    foreach ($file in $files) {
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        $functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
        foreach ($function in $functions) {
            $parameterSet = @{}
            foreach ($name in $commonParameters) {
                $parameterSet[$name] = $true
            }
            if ($null -ne $function.Body.ParamBlock) {
                foreach ($parameter in $function.Body.ParamBlock.Parameters) {
                    $parameterName = [string]$parameter.Name.VariablePath.UserPath
                    $parameterSet[$parameterName] = $true
                    foreach ($attribute in $parameter.Attributes) {
                        if ($attribute -is [System.Management.Automation.Language.AttributeAst] -and $attribute.TypeName.Name -eq 'Alias') {
                            foreach ($argument in $attribute.PositionalArguments) {
                                if ($argument -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                                    $parameterSet[[string]$argument.Value] = $true
                                }
                            }
                        }
                    }
                }
            }
            $map[[string]$function.Name] = $parameterSet
        }
    }
    return $map
}

Describe '跨模块命令调用' {
    It '调用 Grl 函数时只使用已声明的参数' {
        $parameterMap = Get-GrlFunctionParameterMap -RootPath $script:RootPath
        $problems = @()
        $files = @(Get-ChildItem -LiteralPath (Join-Path $script:RootPath 'src') -Filter '*.psm1' -File)
        foreach ($file in $files) {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            $commands = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true)
            foreach ($command in $commands) {
                $commandName = $command.GetCommandName()
                if ([string]::IsNullOrWhiteSpace($commandName)) {
                    continue
                }
                if (-not $parameterMap.ContainsKey($commandName)) {
                    continue
                }
                $parameterSet = $parameterMap[$commandName]
                foreach ($element in $command.CommandElements) {
                    if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                        continue
                    }
                    $parameterName = [string]$element.ParameterName
                    if (-not $parameterSet.ContainsKey($parameterName)) {
                        $problems += ('{0}:{1} {2} -{3}' -f $file.Name, $element.Extent.StartLineNumber, $commandName, $parameterName)
                    }
                }
            }
        }
        ($problems -join [Environment]::NewLine) | Should Be ''
    }
}
