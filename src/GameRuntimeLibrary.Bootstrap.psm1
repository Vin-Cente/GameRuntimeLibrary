$ErrorActionPreference = 'Stop'

function ConvertFrom-GrlGitHubRepositoryUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Url
    )

    $value = $Url.Trim()
    $owner = $null
    $repository = $null

    $httpsMatch = [regex]::Match($value, '^https://github\.com/(?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+?)(?:\.git)?/?$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($httpsMatch.Success) {
        $owner = $httpsMatch.Groups['owner'].Value
        $repository = $httpsMatch.Groups['repo'].Value
    }

    if ($null -eq $owner) {
        $sshMatch = [regex]::Match($value, '^git@github\.com:(?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+?)(?:\.git)?$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($sshMatch.Success) {
            $owner = $sshMatch.Groups['owner'].Value
            $repository = $sshMatch.Groups['repo'].Value
        }
    }

    if ($null -eq $owner -or $owner -in @('.', '..') -or $repository -in @('.', '..')) {
        throw '请输入有效的 GitHub 仓库地址，例如 https://github.com/owner/repo.git。'
    }

    return [pscustomobject]@{
        Owner = $owner
        Repository = $repository
        Slug = "$owner/$repository"
        CloneUrl = "https://github.com/$owner/$repository.git"
        WebUrl = "https://github.com/$owner/$repository"
    }
}

function Assert-GrlGitHubBranch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Branch
    )

    if ($Branch -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $Branch.Contains('..') -or $Branch.EndsWith('/')) {
        throw "GitHub 分支名称无效：$Branch"
    }
    return $Branch
}

function Get-GrlGitHubArchiveUrl {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Repository,
        [Parameter(Mandatory = $true)]
        [string]$Branch
    )

    Assert-GrlGitHubBranch -Branch $Branch | Out-Null
    return "$($Repository.WebUrl)/archive/refs/heads/$Branch.zip"
}

function Get-GrlBootstrapDefaultInstallRoot {
    return Join-Path $env:LOCALAPPDATA 'GameRuntimeLibrary\app'
}

function Get-GrlBootstrapReleaseKind {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot
    )

    $lockPath = Join-Path $InstallRoot 'config\release-lock.ps1'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        return 'Unknown'
    }
    try {
        # 只做文本匹配，不执行清单内容，避免在验签前运行安装目录中的代码。
        $content = [System.IO.File]::ReadAllText($lockPath, [System.Text.Encoding]::UTF8)
    }
    catch {
        return 'Unknown'
    }
    $match = [regex]::Match($content, "(?m)^\s*ReleaseKind\s*=\s*'([^']+)'")
    if (-not $match.Success) {
        return 'Unknown'
    }
    return $match.Groups[1].Value
}

function Read-GrlBootstrapSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath
    )

    if (-not (Test-Path -LiteralPath $SettingsPath -PathType Leaf)) {
        return [pscustomobject]@{
            RepositoryUrl = ''
            Branch = 'main'
            InstallRoot = (Get-GrlBootstrapDefaultInstallRoot)
        }
    }

    try {
        $settings = Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw "启动器配置文件损坏：$SettingsPath"
    }

    if ([string]::IsNullOrWhiteSpace([string]$settings.Branch)) {
        $settings | Add-Member -NotePropertyName Branch -NotePropertyValue 'main' -Force
    }
    if ([string]::IsNullOrWhiteSpace([string]$settings.InstallRoot)) {
        $settings | Add-Member -NotePropertyName InstallRoot -NotePropertyValue (Get-GrlBootstrapDefaultInstallRoot) -Force
    }
    if ($null -eq $settings.PSObject.Properties['RepositoryUrl']) {
        $settings | Add-Member -NotePropertyName RepositoryUrl -NotePropertyValue '' -Force
    }
    return $settings
}

function Save-GrlBootstrapSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SettingsPath,
        [Parameter(Mandatory = $true)]
        [string]$RepositoryUrl,
        [Parameter(Mandatory = $true)]
        [string]$Branch,
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot
    )

    $directory = Split-Path -Parent $SettingsPath
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $settings = [ordered]@{
        schemaVersion = 1
        repositoryUrl = $RepositoryUrl
        branch = $Branch
        installRoot = $InstallRoot
        updatedAt = (Get-Date).ToString('o')
    }
    $json = $settings | ConvertTo-Json -Depth 4
    [System.IO.File]::WriteAllText($SettingsPath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Resolve-GrlBootstrapRepository {
    param(
        [string]$RepositoryUrl,
        [string]$SettingsRepositoryUrl,
        [string]$LocalRepositoryUrl,
        [switch]$Interactive
    )

    $candidate = $RepositoryUrl
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = $LocalRepositoryUrl
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = $env:GAMERUNTIME_GITHUB_REPOSITORY
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        $candidate = $SettingsRepositoryUrl
    }
    if ([string]::IsNullOrWhiteSpace($candidate) -and $Interactive) {
        $candidate = Read-Host '请输入 GitHub 仓库地址（例如 https://github.com/owner/repo.git）'
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        throw '尚未配置 GitHub 仓库。请通过 -RepositoryUrl 指定，或直接运行 GameRuntimeLibrary.cmd 完成首次配置。'
    }
    return ConvertFrom-GrlGitHubRepositoryUrl -Url $candidate
}

function Get-GrlGitExecutable {
    $command = Get-Command git.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $command) {
        return $command.Source
    }
    return $null
}

function Get-GrlLocalGitHubOrigin {
    param(
        [string]$GitPath,
        [Parameter(Mandatory = $true)]
        [string]$LocalRoot
    )

    if ([string]::IsNullOrWhiteSpace($GitPath) -or -not (Test-Path -LiteralPath (Join-Path $LocalRoot '.git') -PathType Container)) {
        return $null
    }
    $result = Invoke-GrlGitCommand -GitPath $GitPath -Arguments @('-C', $LocalRoot, 'remote', 'get-url', 'origin') -AllowFailure
    if ($result.ExitCode -ne 0 -or $result.Output.Count -eq 0) {
        return $null
    }
    try {
        $repository = ConvertFrom-GrlGitHubRepositoryUrl -Url ([string]$result.Output[0]).Trim()
        return $repository.CloneUrl
    }
    catch {
        return $null
    }
}

function Invoke-GrlGitCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitPath,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $GitPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Git 命令失败（$exitCode）：$($output -join [Environment]::NewLine)"
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output)
    }
}

function Update-GrlGitCheckout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$GitPath,
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,
        [Parameter(Mandatory = $true)]
        [object]$Repository,
        [Parameter(Mandatory = $true)]
        [string]$Branch
    )

    Assert-GrlGitHubBranch -Branch $Branch | Out-Null
    $gitDirectory = Join-Path $InstallRoot '.git'
    if (-not (Test-Path -LiteralPath $gitDirectory -PathType Container)) {
        if (Test-Path -LiteralPath $InstallRoot -PathType Container) {
            $contents = @(Get-ChildItem -LiteralPath $InstallRoot -Force)
            if ($contents.Count -gt 0) {
                return $false
            }
        }
        $parent = Split-Path -Parent $InstallRoot
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Write-Host "正在克隆 GitHub 仓库：$($Repository.CloneUrl)" -ForegroundColor Cyan
        Invoke-GrlGitCommand -GitPath $GitPath -Arguments @('clone', '--branch', $Branch, '--depth', '1', $Repository.CloneUrl, $InstallRoot) | Out-Null
        return $true
    }

    $originResult = Invoke-GrlGitCommand -GitPath $GitPath -Arguments @('-C', $InstallRoot, 'remote', 'get-url', 'origin') -AllowFailure
    if ($originResult.ExitCode -ne 0) {
        throw "目录不是有效的受管 Git 仓库，缺少 origin：$InstallRoot"
    }
    $origin = ([string]$originResult.Output[0]).Trim()
    $normalizedOrigin = ConvertFrom-GrlGitHubRepositoryUrl -Url $origin
    if ($normalizedOrigin.CloneUrl -ne $Repository.CloneUrl) {
        throw "本地仓库 origin 与配置地址不一致：$origin"
    }

    $status = Invoke-GrlGitCommand -GitPath $GitPath -Arguments @('-C', $InstallRoot, 'status', '--porcelain')
    if ($status.Output.Count -gt 0) {
        throw "本地仓库存在未提交修改，已停止自动更新：$InstallRoot"
    }

    $currentBranchResult = Invoke-GrlGitCommand -GitPath $GitPath -Arguments @('-C', $InstallRoot, 'symbolic-ref', '--quiet', '--short', 'HEAD') -AllowFailure
    $currentBranch = if ($currentBranchResult.ExitCode -eq 0) { ([string]$currentBranchResult.Output[0]).Trim() } else { $null }
    Invoke-GrlGitCommand -GitPath $GitPath -Arguments @('-C', $InstallRoot, 'fetch', '--prune', 'origin', $Branch) | Out-Null
    if ($currentBranch -ne $Branch) {
        $branchCheck = Invoke-GrlGitCommand -GitPath $GitPath -Arguments @('-C', $InstallRoot, 'show-ref', '--verify', '--quiet', "refs/heads/$Branch") -AllowFailure
        if ($branchCheck.ExitCode -eq 0) {
            Invoke-GrlGitCommand -GitPath $GitPath -Arguments @('-C', $InstallRoot, 'switch', $Branch) | Out-Null
        }
        else {
            Invoke-GrlGitCommand -GitPath $GitPath -Arguments @('-C', $InstallRoot, 'switch', '--create', $Branch, '--track', "origin/$Branch") | Out-Null
        }
    }
    Invoke-GrlGitCommand -GitPath $GitPath -Arguments @('-C', $InstallRoot, 'pull', '--ff-only', 'origin', $Branch) | Out-Null
    return $true
}

function Invoke-GrlGitHubWebRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $allowedHosts = @('github.com', 'codeload.github.com', 'api.github.com', 'raw.githubusercontent.com')
    $currentUri = [uri]$Url
    for ($redirect = 0; $redirect -le 8; $redirect++) {
        if ($currentUri.Scheme -ne 'https' -or $currentUri.Host -notin $allowedHosts -or -not [string]::IsNullOrWhiteSpace($currentUri.UserInfo)) {
            throw "GitHub 下载地址不安全：$($currentUri.AbsoluteUri)"
        }
        $request = [Net.HttpWebRequest]::Create($currentUri)
        $request.AllowAutoRedirect = $false
        $request.UserAgent = 'GameRuntimeLibrary-Bootstrap/1.0'
        $request.Timeout = 30000
        $request.ReadWriteTimeout = 300000
        try {
            $response = [Net.HttpWebResponse]$request.GetResponse()
        }
        catch [Net.WebException] {
            if ($null -ne $_.Exception.Response) {
                $_.Exception.Response.Dispose()
            }
            throw
        }
        $statusCode = [int]$response.StatusCode
        if ($statusCode -in @(301, 302, 303, 307, 308)) {
            $location = $response.Headers['Location']
            $response.Dispose()
            if ([string]::IsNullOrWhiteSpace($location)) {
                throw 'GitHub 重定向响应缺少 Location。'
            }
            $currentUri = [uri]::new($currentUri, $location)
            continue
        }
        if ($statusCode -ne 200) {
            $response.Dispose()
            throw "GitHub 下载失败，HTTP 状态码：$statusCode"
        }
        try {
            $source = $response.GetResponseStream()
            $destination = [System.IO.File]::Create($DestinationPath)
            try {
                $source.CopyTo($destination)
            }
            finally {
                $destination.Dispose()
                $source.Dispose()
            }
        }
        finally {
            $response.Dispose()
        }
        return $currentUri.AbsoluteUri
    }
    throw 'GitHub 下载重定向次数过多。'
}

function Invoke-GrlGitHubApiJson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $uri = [uri]$Url
    if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'api.github.com' -or -not [string]::IsNullOrWhiteSpace($uri.UserInfo)) {
        throw "GitHub API 地址不安全：$Url"
    }
    $request = [Net.HttpWebRequest]::Create($uri)
    $request.AllowAutoRedirect = $false
    $request.UserAgent = 'GameRuntimeLibrary-Bootstrap/1.0'
    $request.Accept = 'application/vnd.github+json'
    $request.Timeout = 30000
    $request.ReadWriteTimeout = 30000
    $response = $null
    $reader = $null
    try {
        $response = [Net.HttpWebResponse]$request.GetResponse()
        $stream = $response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $json = $reader.ReadToEnd()
        return $json | ConvertFrom-Json
    }
    catch [Net.WebException] {
        if ($null -ne $_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
            $_.Exception.Response.Dispose()
            throw "GitHub API 请求失败，HTTP 状态码：$status"
        }
        throw
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
        if ($null -ne $response) {
            $response.Dispose()
        }
    }
}

function Update-GrlGitHubTreeCheckout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,
        [Parameter(Mandatory = $true)]
        [object]$Repository,
        [Parameter(Mandatory = $true)]
        [string]$Branch,
        [string]$RequiredEntry = 'Start-GameRuntimeLibrary.ps1'
    )

    Assert-GrlGitHubBranch -Branch $Branch | Out-Null
    $encodedBranch = [uri]::EscapeDataString($Branch)
    $treeUrl = "https://api.github.com/repos/$($Repository.Owner)/$($Repository.Repository)/git/trees/${encodedBranch}?recursive=1"
    Write-Host "GitHub ZIP 不可用，正在通过 GitHub API 获取文件树。" -ForegroundColor Yellow
    $tree = Invoke-GrlGitHubApiJson -Url $treeUrl
    if ($tree.truncated) {
        throw 'GitHub 文件树超过 API 限制，请安装 Git 后重试。'
    }
    if ($null -eq $tree.tree -or $tree.tree.Count -eq 0) {
        throw 'GitHub API 未返回仓库文件。'
    }
    if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    }
    $root = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    foreach ($item in $tree.tree) {
        if ($item.type -eq 'tree') {
            $directory = [System.IO.Path]::GetFullPath((Join-Path $InstallRoot $item.path))
            if (-not $directory.Equals($root, [System.StringComparison]::OrdinalIgnoreCase) -and -not $directory.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "GitHub 文件树包含不安全目录：$($item.path)"
            }
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            continue
        }
        if ($item.type -ne 'blob') {
            continue
        }
        if ($item.mode -eq '120000') {
            throw "不允许下载符号链接：$($item.path)"
        }
        $target = [System.IO.Path]::GetFullPath((Join-Path $InstallRoot $item.path))
        if (-not $target.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "GitHub 文件树包含不安全路径：$($item.path)"
        }
        $parent = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        $pathParts = @($item.path.Split('/') | ForEach-Object { [uri]::EscapeDataString($_) })
        $rawUrl = "https://raw.githubusercontent.com/$($Repository.Owner)/$($Repository.Repository)/$Branch/$($pathParts -join '/')"
        Invoke-GrlGitHubWebRequest -Url $rawUrl -DestinationPath $target | Out-Null
    }
    if (-not (Test-Path -LiteralPath (Join-Path $InstallRoot $RequiredEntry) -PathType Leaf)) {
        throw 'GitHub API 更新完成，但未找到 GameRuntimeLibrary 入口。'
    }
}

function Assert-GrlArchiveSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchivePath,
        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $root = [System.IO.Path]::GetFullPath($DestinationPath).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        foreach ($entry in $archive.Entries) {
            $target = [System.IO.Path]::GetFullPath((Join-Path $DestinationPath $entry.FullName))
            $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
            if (-not $target.Equals($root, [System.StringComparison]::OrdinalIgnoreCase) -and -not $target.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "GitHub ZIP 包含不安全路径：$($entry.FullName)"
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Update-GrlArchiveCheckout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,
        [Parameter(Mandatory = $true)]
        [object]$Repository,
        [Parameter(Mandatory = $true)]
        [string]$Branch,
        [string]$RequiredEntry = 'Start-GameRuntimeLibrary.ps1'
    )

    $archiveUrl = Get-GrlGitHubArchiveUrl -Repository $Repository -Branch $Branch
    $temporaryRoot = Join-Path $env:TEMP ("GameRuntimeLibrary-bootstrap-" + [guid]::NewGuid().ToString('N'))
    $archivePath = Join-Path $temporaryRoot 'repository.zip'
    $extractRoot = Join-Path $temporaryRoot 'repository'
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    try {
        Write-Host "未检测到 Git，正在从 GitHub 下载：$archiveUrl" -ForegroundColor Cyan
        try {
            Invoke-GrlGitHubWebRequest -Url $archiveUrl -DestinationPath $archivePath | Out-Null
        }
        catch {
            Write-Warning "GitHub ZIP 下载失败：$($_.Exception.Message)"
            Update-GrlGitHubTreeCheckout -InstallRoot $InstallRoot -Repository $Repository -Branch $Branch -RequiredEntry $RequiredEntry
            return
        }
        $bytes = [System.IO.File]::ReadAllBytes($archivePath)
        if ($bytes.Length -lt 4 -or $bytes[0] -ne 0x50 -or $bytes[1] -ne 0x4B) {
            throw 'GitHub 返回的文件不是有效 ZIP。'
        }
        Assert-GrlArchiveSafe -ArchivePath $archivePath -DestinationPath $extractRoot
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot -Force
        $roots = @(Get-ChildItem -LiteralPath $extractRoot -Directory)
        if ($roots.Count -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $roots[0].FullName $RequiredEntry) -PathType Leaf)) {
            throw 'GitHub ZIP 目录结构无效，未找到 GameRuntimeLibrary 入口。'
        }
        if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
        }
        Copy-Item -Path (Join-Path $roots[0].FullName '*') -Destination $InstallRoot -Recurse -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryRoot) {
            $resolvedTemp = [System.IO.Path]::GetFullPath($temporaryRoot)
            $resolvedBase = [System.IO.Path]::GetFullPath($env:TEMP)
            if ($resolvedTemp.StartsWith($resolvedBase, [System.StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
            }
        }
    }
}

function Update-GrlRuntimeRepository {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,
        [Parameter(Mandatory = $true)]
        [object]$Repository,
        [Parameter(Mandatory = $true)]
        [string]$Branch
    )

    Assert-GrlGitHubBranch -Branch $Branch | Out-Null
    $gitPath = Get-GrlGitExecutable
    if (-not [string]::IsNullOrWhiteSpace($gitPath)) {
        $updated = Update-GrlGitCheckout -GitPath $gitPath -InstallRoot $InstallRoot -Repository $Repository -Branch $Branch
        if ($updated) {
            return [pscustomobject]@{ Method = 'Git'; InstallRoot = $InstallRoot }
        }
        Write-Warning '目标目录不是 Git 工作区，将改用 GitHub ZIP 更新。'
    }
    Update-GrlArchiveCheckout -InstallRoot $InstallRoot -Repository $Repository -Branch $Branch
    return [pscustomobject]@{ Method = 'GitHubZip'; InstallRoot = $InstallRoot }
}

function Start-GrlBootstrapMenu {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,
        [string]$Language = 'Auto'
    )

    $entry = Join-Path $InstallRoot 'Start-GameRuntimeLibrary.ps1'
    if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
        throw "菜单入口不存在：$entry"
    }

    $executionPolicy = 'Bypass'
    if ((Get-GrlBootstrapReleaseKind -InstallRoot $InstallRoot) -eq 'Production') {
        $lockPath = Join-Path $InstallRoot 'config\release-lock.ps1'
        $entrySignature = Get-AuthenticodeSignature -LiteralPath $entry
        $lockSignature = Get-AuthenticodeSignature -LiteralPath $lockPath
        if ($entrySignature.Status -ne 'Valid') {
            throw "正式版入口签名无效：$($entrySignature.Status)。请重新获取完整发布包。"
        }
        if ($lockSignature.Status -ne 'Valid') {
            throw "正式版发布清单签名无效：$($lockSignature.Status)。请重新获取完整发布包。"
        }
        if ($null -eq $entrySignature.SignerCertificate -or $null -eq $lockSignature.SignerCertificate) {
            throw '正式版签名证书信息缺失。请重新获取完整发布包。'
        }
        if ($entrySignature.SignerCertificate.Thumbprint -ne $lockSignature.SignerCertificate.Thumbprint) {
            throw '正式版入口与发布清单的签名证书不一致。请重新获取完整发布包。'
        }
        $executionPolicy = 'AllSigned'
    }

    $quotedEntry = '"' + $entry + '"'
    $arguments = @('-NoLogo', '-NoProfile', '-NoExit', '-ExecutionPolicy', $executionPolicy, '-File', $quotedEntry, '-Language', $Language)
    return Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -WorkingDirectory $InstallRoot -WindowStyle Normal -PassThru
}

Export-ModuleMember -Function ConvertFrom-GrlGitHubRepositoryUrl, Assert-GrlGitHubBranch, Get-GrlGitHubArchiveUrl, Get-GrlBootstrapDefaultInstallRoot, Get-GrlBootstrapReleaseKind, Read-GrlBootstrapSettings, Save-GrlBootstrapSettings, Resolve-GrlBootstrapRepository, Get-GrlGitExecutable, Get-GrlLocalGitHubOrigin, Invoke-GrlGitCommand, Update-GrlGitCheckout, Invoke-GrlGitHubWebRequest, Invoke-GrlGitHubApiJson, Update-GrlGitHubTreeCheckout, Assert-GrlArchiveSafe, Update-GrlArchiveCheckout, Update-GrlRuntimeRepository, Start-GrlBootstrapMenu
