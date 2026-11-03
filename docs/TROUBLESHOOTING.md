# 故障排查

按退出码组织。先看安装结束时的退出码，再到对应小节查现象。

所有命令都按 Windows PowerShell 5.1 给出；路径含空格时用引号包住。日志位置见文末。

## 退出码 0：成功

组件已安装或本次安装完成，无需处理。

如果状态看起来仍然不对，先确认检查的是同一个平台配置：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-GameRuntimeLibrary.ps1" -Action Status
```

## 退出码 10：安装完成，需要重启

**原因**：某个安装包返回 `3010`（成功，但需要重启）或 `1641`（成功，安装程序已发起重启），或者检测到系统存在挂起的文件重命名操作。

**处理**：

1. 重启 Windows，让挂起的文件替换完成。
2. 重启后重新检查状态：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-GameRuntimeLibrary.ps1" -Action Status
```

3. 如果重启后仍报同样的组件缺失，再执行一次修复：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-GameRuntimeLibrary.ps1" -Action RepairMissing
```

安装器不会自行重启系统，避免打断使用者正在进行的其它工作。

## 退出码 20：下载、哈希、签名或文件大小校验失败

**原因**：下载被中断、代理改写了响应、文件不完整，或者内容与目录记录不一致。断点续传与自动重试都失败后才会以该退出码结束。

**处理**：

1. 确认可以访问厂商官方域名（`download.microsoft.com`、`aka.ms`、`download.nvidia.com`、`openal.org` 等），企业代理不要把二进制文件替换为提示页。
2. 清理临时目录后重试：

```powershell
Remove-Item -LiteralPath (Join-Path $env:TEMP 'CodexProjectArtifacts\GameRuntimeLibrary') -Recurse -Force -ErrorAction SilentlyContinue
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-GameRuntimeLibrary.ps1" -Action InstallOnline
```

3. 仍然失败时查看日志中记录的「预期哈希 / 实际哈希」，确认是否使用了被改写过的镜像或缓存代理。
4. 离线环境请重新制作离线包，不要手工替换 `packages` 下的文件。

## 退出码 30：平台不兼容

**原因**：系统是 Windows 11 ARM64、非 Windows 10/11，或版本低于 Build 10240，无法自动匹配受支持的平台配置。

**处理**：

1. 在受支持的 Windows 10/11 x64 或 Windows 10 x86 上运行。
2. 确认当前系统版本：

```powershell
powershell.exe -NoProfile -Command '[Environment]::OSVersion.Version; $env:PROCESSOR_ARCHITECTURE'
```

3. 只有在明确知道后果（例如在 ARM64 上通过模拟层安装 x64 运行库）时，才显式跳过检查：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-GameRuntimeLibrary.ps1" -Action InstallOnline -AllowUnsupportedOS
```

跳过检查不会让不兼容的安装包变得可用，安装结果可能仍然失败。

## 退出码 40：部分组件失败

安装会逐包记录结果：单个包失败不会中止同组件的其它包，最后统一汇总为 `40`。

### 现象：安装程序返回 1618（另一个安装程序正在运行）

**原因**：Windows Installer 同一时刻只允许一个安装会话，常见于 Windows Update、其它 MSI 安装或上一次失败的安装残留。

**处理**：

1. 等待 Windows Update 或正在运行的安装结束。
2. 确认没有残留的安装进程：

```powershell
Get-Process | Where-Object { $_.ProcessName -match 'msiexec|setup|install' } | Select-Object ProcessName, Id
```

3. 必要时重启后再运行；安装器本身会对 `1618` 做有限次重试。

### 现象：安装程序返回 1638（已安装更新的版本）

**原因**：系统里已有同产品更高版本。该返回码被视为「已安装」，不算失败。

**处理**：无需处理。若同一组件仍显示缺失，用修复动作重装：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-GameRuntimeLibrary.ps1" -Action RepairMissing -ComponentId <组件ID>
```

### 现象：安装程序返回 3010 / 1641

**原因**：安装成功但需要重启。该类结果不会让组件计为失败，最终退出码会变成 `10`。

**处理**：重启后重新检查状态，见「退出码 10」。

### 现象：只有某一个架构的包失败

**原因**：VC++ 等组件按 x86 / x64 分包安装，其中一个包失败不会影响另一个。

**处理**：在日志中定位失败的包 ID，然后单独修复该组件。修复动作会重装该组件在当前平台适用的全部包，而不是只补失败的单个包：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-GameRuntimeLibrary.ps1" -Action RepairMissing -ComponentId vcredist2015-2022
```

## 退出码 50：发布清单、签名、离线清单或文件完整性失败

### 现象：离线清单校验失败

**原因**：离线包在拷贝或解压过程中损坏；`packages` 或 `feature-payloads` 下的文件被替换；清单与文件不是同一次生成。

**处理**：

1. 重新从原始介质拷贝 ZIP，解压到新目录，不要在旧目录上覆盖解压。
2. 确认解压工具没有改动文件名大小写或编码。
3. 仍然失败就重新制作离线包：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-GameRuntimeLibrary.ps1" -Action PrepareOffline
```

不要手工编辑 `offline-manifest.json` 来「修复」校验，这会让后续安装失去完整性保证。

### 现象：发布清单校验失败

**原因**：`config` 下的文件、模块或入口脚本与 `config\release-lock.ps1` 记录的哈希不一致，常见于手工修改配置、只更新了部分文件，或使用了未重新构建的开发副本。

**处理**：

1. 确认没有手工改过 `config\catalog.json`、`config\ui-text.json`、`src` 下的模块。
2. 从同一版本完整重新获取文件，不要逐个替换。
3. 开发阶段需要重新生成发布锁时，使用开发构建（会重写 `config\release-lock.ps1`）：

```powershell
.\tools\Build-Release.ps1 -Mode Development
```

### 现象：正式版签名无效

**原因**：文件被替换、签名证书与清单指纹不一致，或文件在签名后被修改。

**处理**：重新获取正式发布包；不要对正式包内的脚本做任何修改，包括换行符与编码转换。

## 退出码 60：前置条件缺失

### 现象：UAC 被拒绝或提权失败

**原因**：在「用户账户控制」提示中点击了「否」，或当前账户不属于管理员组。

**处理**：

1. 重新运行，并在 UAC 提示中选择「是」。
2. 确认账户在管理员组：

```powershell
powershell.exe -NoProfile -Command "whoami /groups | findstr /i administrators"
```

3. 也可以用管理员身份打开 PowerShell 后直接运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-GameRuntimeLibrary.ps1" -Action InstallOnline
```

### 现象：提示系统存在挂起的重启

**原因**：上一次安装、Windows Update 或组件服务留下了待完成的文件替换操作。

**处理**：先重启 Windows 再运行。重启后仍提示时，检查注册表中的挂起标记：

```powershell
Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
```

不要手工删除这些键来绕过检查，挂起的文件替换会在之后产生更难排查的故障。

### 现象：DISM 找不到源（安装 .NET Framework 3.5 或 DirectPlay 失败）

**原因**：系统未启用该功能，本地组件存储中没有对应载荷，又没有提供与当前系统版本匹配的安装源。

**处理**：

1. 挂载与目标系统版本、语言一致的 Windows ISO，找到其中的 `sources\sxs` 目录。
2. 用 `-FeatureSource` 指向该目录：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-GameRuntimeLibrary.ps1" -Action InstallOffline -FeatureSource "E:\sources\sxs"
```

3. 也可以先手工验证源是否可用：

```powershell
DISM.exe /Online /Get-FeatureInfo /FeatureName:NetFx3
```

4. 如果系统版本与 ISO 不匹配，DISM 会拒绝安装；此时需要换用对应版本的安装源，或让 Windows Update 提供载荷。

## 其它常见现象

### GitHub 更新失败 / 未安装 Git

**原因**：网络无法访问 GitHub、仓库有未提交修改、`origin` 与配置不一致、更新无法快进，或本机没有 Git。

**处理**：

1. 只运行当前目录，跳过更新：

```powershell
.\GameRuntimeLibrary.cmd -NoUpdate
```

2. 需要更新时确认 Git 是否可用：

```powershell
git --version
```

没有 Git 时启动器会回退到下载仓库 ZIP；若 ZIP 域名不可达，会继续通过 GitHub API 与 `raw.githubusercontent.com` 获取文件。三者都不可达时只能手动更新。
3. 仓库有本地修改时，先提交或另存修改，再重新运行更新；启动器不会强制覆盖本地修改。

### 语言配置损坏

**原因**：`%LOCALAPPDATA%\GameRuntimeLibrary\ui-settings.json` 被手工编辑成非法 JSON，或写入了不支持的语言代码。

**处理**：

1. 删除该文件，下次启动会重新显示语言选择：

```powershell
Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'GameRuntimeLibrary\ui-settings.json') -Force -ErrorAction SilentlyContinue
```

2. 也可以用参数直接指定语言，运行时会重新写入配置：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-GameRuntimeLibrary.ps1" -Language zh-CN
```

3. 如果提示 `config\ui-text.json` 不存在或格式无效，说明程序文件不完整，需要重新获取完整目录。

### 日志位置与收集方式

- 目录：`%ProgramData%\GameRuntimeLibrary\Logs`
- 文件名：`GameRuntimeLibrary-<yyyyMMdd-HHmmss>.log`
- 只保留最近 30 份，更早的日志会被自动清理。
- `-WhatIf` 不写日志；需要日志时去掉该参数。

查看最近一份日志：

```powershell
Get-ChildItem -LiteralPath (Join-Path $env:ProgramData 'GameRuntimeLibrary\Logs') -Filter '*.log' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 |
    Get-Content -Tail 80
```

反馈问题时请附上日志中的失败行与当时的退出码，并说明系统版本、目标平台配置与是否使用离线包。
