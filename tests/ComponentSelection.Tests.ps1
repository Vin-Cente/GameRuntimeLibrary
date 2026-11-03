$script:RootPath = Split-Path $PSScriptRoot -Parent
Import-Module -Name (Join-Path $script:RootPath 'src\GameRuntimeLibrary.psm1') -Force

Describe '组件复选框选择' {
    InModuleScope GameRuntimeLibrary {
        It '输入序号勾选，再次输入同序号取消' {
            $components = @(
                [pscustomobject]@{ id = 'a' },
                [pscustomobject]@{ id = 'b' }
            )
            $selected = @{}

            $result = Update-GrlComponentSelection -InputText '1' -Components $components -Selected $selected
            $result.Confirm | Should Be $false
            $selected.ContainsKey('a') | Should Be $true
            $selected.Count | Should Be 1

            $result = Update-GrlComponentSelection -InputText '1' -Components $components -Selected $selected
            $selected.ContainsKey('a') | Should Be $false
            $selected.Count | Should Be 0
        }

        It '支持逗号分隔、Q 全选、T 推荐与 N 全不选' {
            $components = @(
                [pscustomobject]@{ id = 'a'; tier = 'Core' },
                [pscustomobject]@{ id = 'b'; tier = 'Legacy' },
                [pscustomobject]@{ id = 'c'; tier = 'Core' }
            )
            $selected = @{}

            Update-GrlComponentSelection -InputText '1,3' -Components $components -Selected $selected | Out-Null
            $selected.ContainsKey('a') | Should Be $true
            $selected.ContainsKey('b') | Should Be $false
            $selected.ContainsKey('c') | Should Be $true

            Update-GrlComponentSelection -InputText 'Q' -Components $components -Selected $selected | Out-Null
            $selected.Count | Should Be 3

            Update-GrlComponentSelection -InputText 'n' -Components $components -Selected $selected | Out-Null
            $selected.Count | Should Be 0

            Update-GrlComponentSelection -InputText 'T' -Components $components -Selected $selected | Out-Null
            $selected.Count | Should Be 2
            $selected.ContainsKey('a') | Should Be $true
            $selected.ContainsKey('b') | Should Be $false
            $selected.ContainsKey('c') | Should Be $true
        }

        It '推荐集只包含 Core 组件' {
            $components = @(
                [pscustomobject]@{ id = 'a'; tier = 'Core' },
                [pscustomobject]@{ id = 'b'; tier = 'Legacy' },
                [pscustomobject]@{ id = 'c'; tier = 'Core' }
            )
            $ids = @(Get-GrlRecommendedComponentIds -Components $components)
            $ids.Count | Should Be 2
            ($ids -contains 'a') | Should Be $true
            ($ids -contains 'b') | Should Be $false
            ($ids -contains 'c') | Should Be $true
        }

        It '0 返回，空输入确认' {
            $components = @([pscustomobject]@{ id = 'a' })
            $selected = @{}

            $cancel = Update-GrlComponentSelection -InputText '0' -Components $components -Selected $selected
            $cancel.Cancel | Should Be $true
            $cancel.Confirm | Should Be $false

            $confirm = Update-GrlComponentSelection -InputText '' -Components $components -Selected $selected
            $confirm.Confirm | Should Be $true
            $confirm.Cancel | Should Be $false
        }

        It '非法序号给出错误，合法项仍然生效' {
            $components = @(
                [pscustomobject]@{ id = 'a' },
                [pscustomobject]@{ id = 'b' }
            )
            $selected = @{}

            $result = Update-GrlComponentSelection -InputText '2,9,abc' -Components $components -Selected $selected
            $selected.ContainsKey('b') | Should Be $true
            $selected.Count | Should Be 1
            $result.Error | Should Match '9'
            $result.Error | Should Match 'abc'
        }
    }
}
