$ErrorActionPreference = 'Stop'

function Get-GrlDownloadedPackageState {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Package,
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw (New-GrlException -Message "安装包不存在：$Path" -ExitCode 20 -Category 'Download')
    }
    $file = Get-Item -LiteralPath $Path
    if ($null -ne $Package.size -and $file.Length -ne [long]$Package.size) {
        throw (New-GrlException -Message "文件大小不匹配：$($Package.id)，预期 $($Package.size)，实际 $($file.Length)。" -ExitCode 20 -Category 'Integrity')
    }
    if ($null -ne $Package.minimumBytes -and $file.Length -lt [long]$Package.minimumBytes) {
        throw (New-GrlException -Message "文件大小低于安全下限：$($Package.id)" -ExitCode 20 -Category 'Integrity')
    }
    if ($null -ne $Package.maximumBytes -and $file.Length -gt [long]$Package.maximumBytes) {
        throw (New-GrlException -Message "文件大小超过安全上限：$($Package.id)" -ExitCode 20 -Category 'Integrity')
    }

    $hash = Get-GrlFileSha256 -Path $Path
    if ($Package.hashPolicy -eq 'Fixed') {
        $expected = ([string]$Package.sha256).ToUpperInvariant()
        if ($hash -ne $expected) {
            throw (New-GrlException -Message "SHA-256 不匹配：$($Package.id)，预期 $expected，实际 $hash。" -ExitCode 20 -Category 'Integrity')
        }
    }

    $signatureState = $null
    if ($Package.signature.required) {
        $signatureState = Assert-GrlPublisher -Path $Path -PublisherContains $Package.signature.publisherContains
    }

    return [pscustomobject]@{
        PackageId = $Package.id
        Path = $Path
        Size = [long]$file.Length
        Sha256 = $hash
        HashPolicy = [string]$Package.hashPolicy
        SignatureStatus = if ($null -eq $signatureState) { 'NotRequired' } else { $signatureState.Status }
        SignerSubject = if ($null -eq $signatureState) { '' } else { $signatureState.Subject }
        VerifiedAt = (Get-Date).ToString('o')
    }
}

function Get-GrlContentRangeStart {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$ContentRange
    )

    if ([string]::IsNullOrWhiteSpace($ContentRange)) {
        return $null
    }
    $match = [regex]::Match($ContentRange, '^\s*bytes\s+(\d+)-(\d+)/(\d+|\*)\s*$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        return $null
    }
    $start = 0L
    if (-not [long]::TryParse($match.Groups[1].Value, [ref]$start)) {
        return $null
    }
    return $start
}

function Resolve-GrlDownloadResponse {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [Parameter(Mandatory = $true)]
        [string[]]$AllowedDomains,
        [long]$RangeStart = 0
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $currentUri = [uri]$Url
    for ($redirectCount = 0; $redirectCount -le 10; $redirectCount++) {
        if (-not (Test-GrlOfficialUrl -Url $currentUri.AbsoluteUri -AllowedDomains $AllowedDomains)) {
            throw (New-GrlException -Message "检测到非官方下载地址：$($currentUri.AbsoluteUri)" -ExitCode 20 -Category 'Download')
        }
        $request = [Net.HttpWebRequest]::Create($currentUri)
        $request.AllowAutoRedirect = $false
        $request.UserAgent = 'GameRuntimeLibrary/1.0 WindowsPowerShell'
        $request.Timeout = 30000
        $request.ReadWriteTimeout = 300000
        $request.Accept = 'application/octet-stream'
        if ($RangeStart -gt 0) {
            $request.AddRange($RangeStart)
        }

        try {
            $response = [Net.HttpWebResponse]$request.GetResponse()
        }
        catch [Net.WebException] {
            if ($null -ne $_.Exception.Response) {
                $errorResponse = [Net.HttpWebResponse]$_.Exception.Response
                $statusCode = [int]$errorResponse.StatusCode
                if ($statusCode -eq 416) {
                    $errorResponse.Dispose()
                    return [pscustomobject]@{ StatusCode = 416; Response = $null; FinalUri = $currentUri }
                }
                $errorResponse.Dispose()
            }
            throw (New-GrlException -Message "下载请求失败：$($currentUri.AbsoluteUri)，$($_.Exception.Message)" -ExitCode 20 -Category 'Download')
        }

        $statusCode = [int]$response.StatusCode
        if ($statusCode -in @(301, 302, 303, 307, 308)) {
            $location = $response.Headers['Location']
            $response.Dispose()
            if ([string]::IsNullOrWhiteSpace($location)) {
                throw (New-GrlException -Message "重定向响应缺少 Location：$($currentUri.AbsoluteUri)" -ExitCode 20 -Category 'Download')
            }
            $currentUri = [uri]::new($currentUri, $location)
            continue
        }
        if ($statusCode -ne 200 -and $statusCode -ne 206) {
            $response.Dispose()
            throw (New-GrlException -Message "下载请求失败，HTTP 状态码：$statusCode" -ExitCode 20 -Category 'Download')
        }
        return [pscustomobject]@{
            StatusCode = $statusCode
            Response = $response
            FinalUri = $currentUri
        }
    }
    throw (New-GrlException -Message '下载重定向次数超过 10 次。' -ExitCode 20 -Category 'Download')
}

function Invoke-GrlNetworkDownload {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        [Parameter(Mandatory = $true)]
        [string[]]$AllowedDomains,
        [switch]$Restart,
        [long]$MaximumBytes = 4294967296,
        [string]$DisplayName = '',
        [long]$ExpectedTotalBytes = 0
    )

    $displayName = $DisplayName
    if ([string]::IsNullOrWhiteSpace($displayName)) {
        $displayName = Split-Path -Leaf $DestinationPath
    }
    $activity = '{0} {1}' -f (Get-GrlText -Key 'progress.download'), $displayName
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastProgressAt = -1000L
    Write-GrlProgress -Activity $activity -Status (Get-GrlText -Key 'progress.preparing') -Percent -1

    $partPath = $DestinationPath + '.part'
    if ($Restart -and (Test-Path -LiteralPath $partPath)) {
        Remove-Item -LiteralPath $partPath -Force
    }

    $existingBytes = 0L
    if (Test-Path -LiteralPath $partPath -PathType Leaf) {
        $existingBytes = [long](Get-Item -LiteralPath $partPath).Length
    }

    try {
        $downloadState = Resolve-GrlDownloadResponse -Url $Url -AllowedDomains $AllowedDomains -RangeStart $existingBytes
    }
    catch {
        Write-GrlProgress -Activity $activity -Status (Get-GrlText -Key 'progress.failed') -Complete
        throw
    }
    if ($downloadState.StatusCode -eq 416) {
        if ($Restart) {
            Write-GrlProgress -Activity $activity -Status (Get-GrlText -Key 'progress.failed') -Complete
            throw (New-GrlException -Message "服务器拒绝了下载范围请求：$Url" -ExitCode 20 -Category 'Download')
        }
        Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
        Write-GrlProgress -Activity $activity -Status (Get-GrlText -Key 'progress.restarting') -Complete
        return Invoke-GrlNetworkDownload -Url $Url -DestinationPath $DestinationPath -AllowedDomains $AllowedDomains -Restart -MaximumBytes $MaximumBytes -DisplayName $DisplayName -ExpectedTotalBytes $ExpectedTotalBytes
    }

    $append = $false
    if ($downloadState.StatusCode -eq 206 -and $existingBytes -gt 0) {
        $rangeStart = Get-GrlContentRangeStart -ContentRange ([string]$downloadState.Response.Headers['Content-Range'])
        if ($null -ne $rangeStart -and [long]$rangeStart -eq $existingBytes) {
            $append = $true
        }
        else {
            Write-GrlLog -Level '警告' -Message "断点续传区间不匹配，丢弃部分文件后重新下载：$Url" -Component 'Download'
            Write-GrlProgress -Activity $activity -Status (Get-GrlText -Key 'progress.restarting') -Complete
            $downloadState.Response.Dispose()
            Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
            $existingBytes = 0L
            try {
                $downloadState = Resolve-GrlDownloadResponse -Url $Url -AllowedDomains $AllowedDomains -RangeStart 0
            }
            catch {
                Write-GrlProgress -Activity $activity -Status (Get-GrlText -Key 'progress.failed') -Complete
                throw
            }
            if ($downloadState.StatusCode -eq 416) {
                if ($null -ne $downloadState.Response) {
                    $downloadState.Response.Dispose()
                }
                Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
                Write-GrlProgress -Activity $activity -Status (Get-GrlText -Key 'progress.failed') -Complete
                throw (New-GrlException -Message "服务器拒绝了重试下载请求：$Url" -ExitCode 20 -Category 'Download')
            }
            if ($downloadState.StatusCode -eq 206) {
                $retryRangeStart = Get-GrlContentRangeStart -ContentRange ([string]$downloadState.Response.Headers['Content-Range'])
                if ($null -eq $retryRangeStart -or [long]$retryRangeStart -ne 0L) {
                    $downloadState.Response.Dispose()
                    Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
                    Write-GrlProgress -Activity $activity -Status (Get-GrlText -Key 'progress.failed') -Complete
                    throw (New-GrlException -Message "断点续传区间校验失败，服务器返回了错误的区间起点：$Url" -ExitCode 20 -Category 'Download')
                }
            }
        }
    }

    $totalBytes = [long]$ExpectedTotalBytes
    $contentLength = [long]$downloadState.Response.ContentLength
    if ($contentLength -gt 0) {
        if ($append) {
            $totalBytes = $existingBytes + $contentLength
        }
        elseif ($totalBytes -le 0) {
            $totalBytes = $contentLength
        }
    }

    $bufferSize = 81920
    $fileMode = [System.IO.FileMode]::Create
    if ($append) {
        $fileMode = [System.IO.FileMode]::Append
    }
    $fileStream = $null
    $networkStream = $null
    $writtenBytes = 0L
    if ($append) {
        $writtenBytes = $existingBytes
    }
    try {
        $networkStream = $downloadState.Response.GetResponseStream()
        $fileStream = New-Object System.IO.FileStream($partPath, $fileMode, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $buffer = New-Object byte[] $bufferSize
        while ($true) {
            $read = $networkStream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) {
                break
            }
            $writtenBytes += $read
            if ($writtenBytes -gt $MaximumBytes) {
                throw (New-GrlException -Message "下载内容超过允许的最大尺寸：$Url，上限 $MaximumBytes 字节。" -ExitCode 20 -Category 'Download')
            }
            $fileStream.Write($buffer, 0, $read)

            $now = $stopwatch.ElapsedMilliseconds
            if (($now - $lastProgressAt) -ge 250) {
                $percent = -1
                if ($totalBytes -gt 0) {
                    $percent = [int][Math]::Floor($writtenBytes * 100 / $totalBytes)
                }
                $downloadedThisRun = $writtenBytes - $existingBytes
                $totalText = '?'
                if ($totalBytes -gt 0) {
                    $totalText = Format-GrlByteSize -Bytes $totalBytes
                }
                $statusText = '{0} / {1}' -f (Format-GrlByteSize -Bytes $writtenBytes), $totalText
                if ($stopwatch.Elapsed.TotalSeconds -ge 0.5) {
                    $bytesPerSecond = [long]($downloadedThisRun / $stopwatch.Elapsed.TotalSeconds)
                    $statusText = '{0}  {1}/s' -f $statusText, (Format-GrlByteSize -Bytes $bytesPerSecond)
                }
                Write-GrlProgress -Activity $activity -Status $statusText -Percent $percent
                $lastProgressAt = $now
            }
        }
        $fileStream.Flush()
    }
    catch {
        if ($null -ne $fileStream) {
            $fileStream.Dispose()
            $fileStream = $null
        }
        Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
        Write-GrlProgress -Activity $activity -Status (Get-GrlText -Key 'progress.failed') -Complete
        throw
    }
    finally {
        if ($null -ne $fileStream) {
            $fileStream.Dispose()
        }
        if ($null -ne $networkStream) {
            $networkStream.Dispose()
        }
        $downloadState.Response.Dispose()
    }

    if (Test-Path -LiteralPath $DestinationPath -PathType Leaf) {
        Remove-Item -LiteralPath $DestinationPath -Force
    }
    Move-Item -LiteralPath $partPath -Destination $DestinationPath
    $stopwatch.Stop()
    $doneStatus = '{0} {1} / {2}' -f (Get-GrlText -Key 'progress.done'), (Format-GrlByteSize -Bytes $writtenBytes), (Format-GrlDuration -Duration $stopwatch.Elapsed)
    Write-GrlProgress -Activity $activity -Status $doneStatus -Percent 100 -Complete
    return $downloadState.FinalUri.AbsoluteUri
}

function Invoke-GrlSafeDownload {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Package,
        [Parameter(Mandatory = $true)]
        [string]$DestinationDirectory,
        [Parameter(Mandatory = $true)]
        [string[]]$AllowedDomains,
        [switch]$AllowNetwork,
        [switch]$Force
    )

    if (-not (Test-Path -LiteralPath $DestinationDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    }
    $destination = Join-Path $DestinationDirectory $Package.fileName
    if ((Test-Path -LiteralPath $destination -PathType Leaf) -and -not $Force) {
        try {
            $existing = Get-GrlDownloadedPackageState -Package $Package -Path $destination
            Write-GrlMessage -Message "已通过校验：$($Package.fileName)" -Level '调试' -Component 'Download'
            return $existing
        }
        catch {
            Write-GrlMessage -Message "缓存文件校验失败，将重新下载：$($Package.fileName)" -Level '警告' -Component 'Download'
            Remove-Item -LiteralPath $destination -Force
        }
    }
    if (-not $AllowNetwork) {
        throw (New-GrlException -Message "离线模式缺少安装包：$($Package.fileName)" -ExitCode 20 -Category 'Download')
    }

    $maximumBytes = 4294967296L
    if ($null -ne $Package.maximumBytes) {
        $declaredMaximum = [long]$Package.maximumBytes
        if ($declaredMaximum -gt 0) {
            $maximumBytes = $declaredMaximum
        }
    }
    elseif ($null -ne $Package.size) {
        $expectedSize = [double]$Package.size
        if ($expectedSize -gt 0) {
            $maximumBytes = [long][math]::Ceiling($expectedSize * 1.05)
        }
    }

    $expectedTotalBytes = 0L
    if ($null -ne $Package.size) {
        $expectedTotalBytes = [long]$Package.size
    }

    $mutex = $null
    $acquired = $false
    try {
        try {
            $mutex = New-Object System.Threading.Mutex($false, 'Global\GameRuntimeLibrary.Download')
        }
        catch {
            $mutex = New-Object System.Threading.Mutex($false, 'Local\GameRuntimeLibrary.Download')
        }
        $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes(5))
        if (-not $acquired) {
            throw (New-GrlException -Message '等待下载锁超时。' -ExitCode 20 -Category 'Download')
        }

        Write-GrlLog -Level '信息' -Message "开始下载：$($Package.fileName)" -Component 'Download'
        $finalUrl = Invoke-GrlNetworkDownload -Url $Package.url -DestinationPath $destination -AllowedDomains $AllowedDomains -MaximumBytes $maximumBytes -DisplayName $Package.fileName -ExpectedTotalBytes $expectedTotalBytes
        try {
            $state = Get-GrlDownloadedPackageState -Package $Package -Path $destination
        }
        catch {
            Write-GrlMessage -Message "下载完成校验失败，删除后重新下载一次：$($Package.fileName)" -Level '警告' -Component 'Download'
            if (Test-Path -LiteralPath $destination -PathType Leaf) {
                Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
            }
            $finalUrl = Invoke-GrlNetworkDownload -Url $Package.url -DestinationPath $destination -AllowedDomains $AllowedDomains -Restart -MaximumBytes $maximumBytes -DisplayName $Package.fileName -ExpectedTotalBytes $expectedTotalBytes
            $state = Get-GrlDownloadedPackageState -Package $Package -Path $destination
        }
        $state | Add-Member -NotePropertyName FinalUrl -NotePropertyValue $finalUrl
        Write-GrlMessage -Message "校验通过：$($Package.fileName)，SHA-256 $($state.Sha256)" -Level '成功' -Component 'Download'
        return $state
    }
    finally {
        if ($acquired -and $null -ne $mutex) {
            $mutex.ReleaseMutex()
        }
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
    }
}

function Test-GrlArchiveEntryName {
    param(
        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }
    $value = [string]$Name
    foreach ($character in $value.ToCharArray()) {
        $code = [int]$character
        if ($code -lt 0x20 -or $code -eq 0x7F) {
            return $false
        }
    }
    if ($value.IndexOf(':') -ge 0) {
        return $false
    }
    if ($value.StartsWith('/') -or $value.StartsWith('\')) {
        return $false
    }
    if ($value -match '^[A-Za-z]:') {
        return $false
    }

    $candidate = $value
    if ($candidate.EndsWith('/') -or $candidate.EndsWith('\')) {
        $candidate = $candidate.TrimEnd([char[]]@('/', '\'))
    }
    if ($candidate.Length -eq 0) {
        return $false
    }
    if ($candidate.EndsWith('.') -or $candidate.EndsWith(' ')) {
        return $false
    }

    foreach ($segment in ($candidate -split '[\\/]')) {
        if ($segment.Length -eq 0) {
            return $false
        }
        if ($segment -eq '..') {
            return $false
        }
        if ($segment.EndsWith('.') -or $segment.EndsWith(' ')) {
            return $false
        }
    }
    return $true
}

function Expand-GrlSafeArchive {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath,
        [int]$MaximumEntries = 5000,
        [long]$MaximumTotalBytes = 2147483648
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Container)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        if ($archive.Entries.Count -gt $MaximumEntries) {
            throw (New-GrlException -Message "压缩包条目数超过限制（$MaximumEntries）：$ArchivePath" -ExitCode 20 -Category 'Integrity')
        }
        $totalBytes = 0L
        foreach ($entry in $archive.Entries) {
            if (-not (Test-GrlArchiveEntryName -Name $entry.FullName)) {
                throw (New-GrlException -Message "压缩包包含不安全的条目名称：$($entry.FullName)" -ExitCode 20 -Category 'Integrity')
            }
            $totalBytes += [long]$entry.Length
            if ($totalBytes -gt $MaximumTotalBytes) {
                throw (New-GrlException -Message "压缩包解压后总大小超过限制（$MaximumTotalBytes 字节）：$ArchivePath" -ExitCode 20 -Category 'Integrity')
            }

            $targetPath = $null
            try {
                $targetPath = [System.IO.Path]::GetFullPath((Join-Path $DestinationPath $entry.FullName))
                Assert-GrlChildPath -ParentPath $DestinationPath -ChildPath $targetPath
            }
            catch {
                throw (New-GrlException -Message "压缩包条目路径非法：$($entry.FullName)" -ExitCode 20 -Category 'Integrity')
            }

            if ([string]::IsNullOrEmpty($entry.Name)) {
                New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
                continue
            }
            $parent = Split-Path -Parent $targetPath
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
                New-Item -ItemType Directory -Path $parent -Force | Out-Null
            }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $targetPath, $true)
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Test-GrlArchiveTraversal {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            if (-not (Test-GrlArchiveEntryName -Name $entry.FullName)) {
                return $false
            }
            try {
                $targetPath = [System.IO.Path]::GetFullPath((Join-Path $DestinationPath $entry.FullName))
            }
            catch {
                return $false
            }
            if (-not (Test-GrlChildPath -ParentPath $DestinationPath -ChildPath $targetPath)) {
                return $false
            }
        }
    }
    finally {
        $archive.Dispose()
    }
    return $true
}

function Write-GrlPackageCacheManifest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,
        [Parameter(Mandatory = $true)]
        [object[]]$States
    )

    if ($States.Count -eq 0) {
        return
    }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }
    $manifest = [ordered]@{
        schemaVersion = 1
        generatedAt = (Get-Date).ToString('o')
        packages = @($States | ForEach-Object {
            [ordered]@{
                packageId = $_.PackageId
                fileName = Split-Path -Leaf $_.Path
                size = $_.Size
                sha256 = $_.Sha256
                hashPolicy = $_.HashPolicy
                signatureStatus = $_.SignatureStatus
                signerSubject = $_.SignerSubject
                verifiedAt = $_.VerifiedAt
            }
        })
    }
    $path = Join-Path $Directory 'package-manifest.json'
    $json = $manifest | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

Export-ModuleMember -Function Get-GrlDownloadedPackageState, Get-GrlContentRangeStart, Resolve-GrlDownloadResponse, Invoke-GrlNetworkDownload, Invoke-GrlSafeDownload, Expand-GrlSafeArchive, Test-GrlArchiveEntryName, Test-GrlArchiveTraversal, Write-GrlPackageCacheManifest
