$script:RootPath = Split-Path $PSScriptRoot -Parent
Import-Module -Name (Join-Path $script:RootPath 'src\GameRuntimeLibrary.psm1') -Force

function New-SecurityTestPackage {
    param(
        [string]$Id = 'pkg1',
        [string]$Url = 'https://download.microsoft.com/file.exe',
        [string]$FileName = 'file.exe'
    )

    return [pscustomobject]@{
        id = $Id
        architecture = 'any'
        url = $Url
        fileName = $FileName
        size = 1024
        sha256 = ('A' * 64)
        hashPolicy = 'Fixed'
        signature = [pscustomobject]@{
            required = $true
            publisherContains = 'Microsoft Corporation'
        }
    }
}

function New-SecurityTestCatalog {
    $component = [pscustomobject]@{
        id = 'comp1'
        tier = 'Core'
        order = 10
        applicability = [pscustomobject]@{ architectures = @('x86', 'x64') }
        installer = [pscustomobject]@{ type = 'Exe' }
        packages = @(New-SecurityTestPackage)
    }
    return [pscustomobject]@{
        schemaVersion = 1
        officialDomains = @('microsoft.com')
        components = @($component)
    }
}

function New-SecurityTestDirectory {
    $path = Join-Path $env:TEMP ('grl-security-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    return $path
}

function New-SecurityTestArchive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string[]]$Entries
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $stream = [System.IO.File]::Create($Path)
    $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($name in $Entries) {
            $entry = $archive.CreateEntry($name)
            $writer = New-Object System.IO.StreamWriter($entry.Open())
            try {
                $writer.Write('payload')
            }
            finally {
                $writer.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
        $stream.Dispose()
    }
}

Describe '结构化异常与退出码' {
    It '未包装的异常可以取回退出码与分类' {
        $exception = New-GrlException -Message '下载失败' -ExitCode 20 -Category 'Download'
        $exception.Data['GrlExitCode'] | Should Be 20
        $exception.Data['GrlCategory'] | Should Be 'Download'

        $record = New-Object System.Management.Automation.ErrorRecord($exception, 'GrlTest', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        (Get-GrlExceptionExitCode -ErrorRecord $record) | Should Be 20
    }

    It '异常被包装一层后仍能追溯退出码' {
        $inner = New-GrlException -Message '内层校验失败' -ExitCode 50 -Category 'Integrity'
        $middle = New-Object System.Exception('中层包装', $inner)
        $outer = New-Object System.Exception('外层包装', $middle)
        $record = New-Object System.Management.Automation.ErrorRecord($outer, 'GrlWrapped', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        (Get-GrlExceptionExitCode -ErrorRecord $record) | Should Be 50
    }

    It '默认退出码为 40' {
        $exception = New-GrlException -Message '普通失败'
        $record = New-Object System.Management.Automation.ErrorRecord($exception, 'GrlDefault', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        (Get-GrlExceptionExitCode -ErrorRecord $record) | Should Be 40
    }

    It '普通异常返回 null' {
        $plain = New-Object System.Exception('普通异常')
        $record = New-Object System.Management.Automation.ErrorRecord($plain, 'GrlPlain', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        (Get-GrlExceptionExitCode -ErrorRecord $record) | Should Be $null
    }
}

Describe '日志轮转' {
    It '只保留最新 30 个匹配日志并跳过无关文件' {
        $temp = New-SecurityTestDirectory
        try {
            for ($i = 0; $i -lt 35; $i++) {
                $path = Join-Path $temp ('GameRuntimeLibrary-{0:D3}.log' -f $i)
                [System.IO.File]::WriteAllText($path, 'log')
                $item = Get-Item -LiteralPath $path
                $item.LastWriteTime = (Get-Date).AddMinutes(-$i)
            }
            [System.IO.File]::WriteAllText((Join-Path $temp 'unrelated.txt'), 'keep')
            [System.IO.File]::WriteAllText((Join-Path $temp 'GameRuntimeLibrary-unrelated.txt'), 'keep')

            Remove-GrlOldLogFiles -Directory $temp -Keep 30

            @(Get-ChildItem -LiteralPath $temp -File -Filter 'GameRuntimeLibrary-*.log').Count | Should Be 30
            (Test-Path -LiteralPath (Join-Path $temp 'unrelated.txt')) | Should Be $true
            (Test-Path -LiteralPath (Join-Path $temp 'GameRuntimeLibrary-unrelated.txt')) | Should Be $true
        }
        finally {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It '目录不存在时直接返回' {
        $missing = Join-Path $env:TEMP ('grl-missing-' + [guid]::NewGuid().ToString('N'))
        { Remove-GrlOldLogFiles -Directory $missing -Keep 30 } | Should Not Throw
    }
}

Describe '组件目录安全校验' {
    It '最小合法目录可以通过校验' {
        $catalog = New-SecurityTestCatalog
        { Assert-GrlCatalog -Catalog $catalog } | Should Not Throw
    }

    It '拒绝非官方域名与非法域名格式' {
        $catalog = New-SecurityTestCatalog
        $catalog.components[0].packages[0].url = 'https://evil.example.com/file.exe'
        { Assert-GrlCatalog -Catalog $catalog } | Should Throw

        $wildcard = New-SecurityTestCatalog
        $wildcard.officialDomains = @('*')
        { Assert-GrlCatalog -Catalog $wildcard } | Should Throw

        $singleSegment = New-SecurityTestCatalog
        $singleSegment.officialDomains = @('com')
        { Assert-GrlCatalog -Catalog $singleSegment } | Should Throw
    }

    It '拒绝缺少 minimumBytes 的 SignedLatest 策略' {
        $catalog = New-SecurityTestCatalog
        $package = $catalog.components[0].packages[0]
        $package.hashPolicy = 'SignedLatest'
        $package | Add-Member -NotePropertyName maximumBytes -NotePropertyValue 2000000 -Force
        { Assert-GrlCatalog -Catalog $catalog } | Should Throw
    }

    It '拒绝带目录的 fileName' {
        $catalog = New-SecurityTestCatalog
        $catalog.components[0].packages[0].fileName = 'sub\file.exe'
        { Assert-GrlCatalog -Catalog $catalog } | Should Throw
    }

    It '拒绝带目录的 innerFile' {
        $catalog = New-SecurityTestCatalog
        $catalog.components[0].installer = [pscustomobject]@{
            type = 'SelfExtractingBundle'
            innerFile = 'sub\DXSETUP.exe'
            innerSha256 = ('B' * 64)
            innerPublisherContains = 'Microsoft Corporation'
        }
        { Assert-GrlCatalog -Catalog $catalog } | Should Throw
    }

    It '拒绝白名单外的 featureName' {
        $catalog = New-SecurityTestCatalog
        $catalog.components[0].installer = [pscustomobject]@{
            type = 'WindowsFeature'
            featureName = 'TelnetClient'
        }
        { Assert-GrlCatalog -Catalog $catalog } | Should Throw
    }

    It '拒绝重复的下载地址（忽略大小写）' {
        $catalog = New-SecurityTestCatalog
        $duplicate = New-SecurityTestPackage -Id 'pkg2' -Url 'https://DOWNLOAD.microsoft.com/file.exe' -FileName 'file2.exe'
        $catalog.components[0].packages = @($catalog.components[0].packages[0], $duplicate)
        { Assert-GrlCatalog -Catalog $catalog } | Should Throw
    }

    It '拒绝全零的 SHA-256' {
        $catalog = New-SecurityTestCatalog
        $catalog.components[0].packages[0].sha256 = ('0' * 64)
        { Assert-GrlCatalog -Catalog $catalog } | Should Throw
    }
}

Describe '压缩包条目名称校验' {
    It '拒绝非法条目名称' {
        (Test-GrlArchiveEntryName -Name 'C:\evil') | Should Be $false
        (Test-GrlArchiveEntryName -Name '../x') | Should Be $false
        (Test-GrlArchiveEntryName -Name 'a:b') | Should Be $false
        (Test-GrlArchiveEntryName -Name 'dir.') | Should Be $false
        (Test-GrlArchiveEntryName -Name '') | Should Be $false
        (Test-GrlArchiveEntryName -Name '/absolute/x') | Should Be $false
    }

    It '允许普通文件与目录条目' {
        (Test-GrlArchiveEntryName -Name 'normal.exe') | Should Be $true
        (Test-GrlArchiveEntryName -Name 'dir/') | Should Be $true
        (Test-GrlArchiveEntryName -Name 'sub\normal.exe') | Should Be $true
    }
}

Describe '安全解压' {
    It '拒绝路径穿越压缩包' {
        $temp = New-SecurityTestDirectory
        try {
            $archivePath = Join-Path $temp 'traversal.zip'
            New-SecurityTestArchive -Path $archivePath -Entries @('../escape.txt')
            $destination = Join-Path $temp 'out'
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            { Expand-GrlSafeArchive -ArchivePath $archivePath -DestinationPath $destination } | Should Throw
            (Test-Path -LiteralPath (Join-Path $temp 'escape.txt')) | Should Be $false
        }
        finally {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It '拒绝包含备用数据流冒号的条目' {
        $temp = New-SecurityTestDirectory
        try {
            $archivePath = Join-Path $temp 'ads.zip'
            New-SecurityTestArchive -Path $archivePath -Entries @('evil:stream.txt')
            $destination = Join-Path $temp 'out'
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            { Expand-GrlSafeArchive -ArchivePath $archivePath -DestinationPath $destination } | Should Throw
        }
        finally {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It '拒绝超过条目数上限的压缩包' {
        $temp = New-SecurityTestDirectory
        try {
            $archivePath = Join-Path $temp 'many.zip'
            New-SecurityTestArchive -Path $archivePath -Entries @('a.txt', 'b.txt')
            $destination = Join-Path $temp 'out'
            New-Item -ItemType Directory -Path $destination -Force | Out-Null
            { Expand-GrlSafeArchive -ArchivePath $archivePath -DestinationPath $destination -MaximumEntries 1 } | Should Throw
        }
        finally {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It '正常压缩包可以解压' {
        $temp = New-SecurityTestDirectory
        try {
            $archivePath = Join-Path $temp 'normal.zip'
            New-SecurityTestArchive -Path $archivePath -Entries @('dir/', 'dir/normal.exe')
            $destination = Join-Path $temp 'out'
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            Expand-GrlSafeArchive -ArchivePath $archivePath -DestinationPath $destination
            (Test-Path -LiteralPath (Join-Path $destination 'dir\normal.exe')) | Should Be $true
        }
        finally {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Content-Range 解析' {
    It '解析有效的区间起点' {
        (Get-GrlContentRangeStart -ContentRange 'bytes 100-199/200') | Should Be 100
    }

    It '无法解析时返回 null' {
        (Get-GrlContentRangeStart -ContentRange 'bytes */200') | Should Be $null
        (Get-GrlContentRangeStart -ContentRange '') | Should Be $null
        (Get-GrlContentRangeStart -ContentRange 'invalid') | Should Be $null
    }
}

Describe '真实项目目录回归' {
    It '新校验不误伤现有 catalog.json' {
        $catalog = Import-GrlCatalog -RootPath $script:RootPath
        $catalog.components.Count | Should BeGreaterThan 0
        $catalog.components.Count | Should Be 14
        @($catalog.officialDomains).Count | Should BeGreaterThan 0
    }
}
