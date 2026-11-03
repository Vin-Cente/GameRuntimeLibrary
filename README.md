# GameRuntimeLibrary

GameRuntimeLibrary 是面向 Windows 10/11 的 PowerShell 游戏运行库安装工具。它只从 Microsoft、NVIDIA 和 OpenAL 官方地址下载安装包，先校验文件大小、SHA-256 和 Authenticode 发布者，再按统一顺序静默安装。

## 它能做什么 / 它不做什么

它可以：

- 自动识别 Windows 10/11 与 x86/x64 目标，按平台选择应当安装的运行库。
- 从微软、NVIDIA、OpenAL 官方地址下载安装包，逐项校验域名、尺寸、SHA-256 与 Authenticode 签名。
- 静默安装、跳过已完整安装的组件，下载与安装过程显示进度。
- 安装完成后响铃并弹窗提示，同时列出仍未安装的组件及检测原因。
- 生成可拷贝到离线机器的安装包，安装前整体校验离线清单。
- 以只读方式检查组件状态与安装包提供的 DLL / 程序集。

它不做什么：

- 不下载、不复制任何第三方站点的散装 DLL，也不向游戏目录写入文件。
- 不安装显卡驱动、Windows 更新、Java、Flash、.NET Core 或反作弊组件。
- 不自动重启 Windows，重启时机由使用者决定。
- 不支持 Windows 11 ARM64；Windows 11 也没有官方 x86 版本。
- 不替代厂商安装程序，不承诺修复与运行库无关的游戏崩溃。

## 平台

- `Windows 11 x64`：适用于 64 位 Windows 11，同时安装 x64 与 x86 运行库。
- `Windows 10 x64`：适用于 64 位 Windows 10，同时安装 x64 与 x86 运行库。
- `Windows 10 x86`：适用于 32 位 Windows 10，仅安装 x86 运行库。
- Windows 11 没有官方 x86 版本，因此本项目不提供该目标。
- 本项目不支持 Windows 11 ARM64，也不安装显卡驱动、Windows 更新、Java、Flash、.NET Core 或反作弊组件。

## 运行要求

- Windows 10 Build 10240 或更高版本，或 Windows 11。
- Windows PowerShell 5.1。
- 安装操作需要管理员权限；菜单会自动请求 UAC 提权。
- 在线下载需要能访问对应厂商官方站点。
- 离线功能组件通常需要与目标系统版本完全匹配的 Windows ISO 或 `sources\sxs` 目录。

## 双击启动

`Start-GameRuntimeLibrary.ps1` 是有效的 Windows PowerShell 脚本，但 Windows 对 `.ps1` 的默认双击行为通常是打开编辑器，而不是执行脚本。

请双击：

```text
GameRuntimeLibrary.cmd
```

如果启动器位于已克隆的 GitHub 仓库中，会自动使用该仓库的 `origin`。否则首次运行会要求输入 GitHub 仓库地址并保存到：

```text
%LOCALAPPDATA%\GameRuntimeLibrary\bootstrap.json
```

后续双击会先拉取 GitHub 最新版，再自动打开新的 Windows PowerShell 菜单窗口。更新目录默认为：

```text
%LOCALAPPDATA%\GameRuntimeLibrary\app
```

菜单窗口首次运行还会先显示界面语言选择，可选简体中文或 English。选择结果保存到：

```text
%LOCALAPPDATA%\GameRuntimeLibrary\ui-settings.json
```

之后启动会直接使用上次选择的语言，也可在主菜单第 9 项切换。

也可在命令提示符、PowerShell 或 Win+R 中执行：

```powershell
.\GameRuntimeLibrary.cmd
```

首次配置也可以直接传入仓库地址：

```powershell
.\GameRuntimeLibrary.cmd https://github.com/<账号>/<仓库>.git
```

已有 Git 时使用克隆和 `git pull --ff-only` 更新；没有 Git 时自动改为下载该分支的 GitHub ZIP，如果 ZIP 下载域名不可达则继续通过 GitHub API 和 `raw.githubusercontent.com` 获取文件。仓库有未提交修改、origin 地址不一致或更新无法快进时，启动器会停止更新，不会强制覆盖本地修改。

如果只想运行当前目录，不访问 GitHub：

```powershell
.\GameRuntimeLibrary.cmd -NoUpdate
```

## PowerShell 启动

直接通过 Windows PowerShell 运行本地脚本：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-GameRuntimeLibrary.ps1"
```

直接调用 GitHub 启动器并打开菜单：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\tools\Bootstrap-GameRuntimeLibrary.ps1" -RepositoryUrl "https://github.com/<账号>/<仓库>.git"
```

正式签名版在进入菜单时使用 `AllSigned`：

```powershell
powershell.exe -NoProfile -ExecutionPolicy AllSigned -File ".\Start-GameRuntimeLibrary.ps1"
```

每个平台目录也新增了本地 `.cmd` 入口，例如：

```text
Windows 10 x64\GameRuntimeLibrary.cmd
```

平台目录入口不执行 GitHub 更新，直接打开当前项目的菜单。

## 菜单

主菜单按功能分组：

```text
安装与维护
  1. 检查组件状态
  2. 一键安装 / 修复（推荐，已安装项自动跳过）
  3. 在线自定义安装
  4. 修复缺失组件

离线部署
  5. 制作离线安装包
  6. 从离线安装包安装

信息与设置
  7. 查看 DLL / 程序集状态
  8. 查看组件清单
  9. 切换界面语言 / Language
  0. 退出
```

在线全量安装会先读取当前状态。已经完整安装的组件会跳过；VC++ 等分架构组件会进一步按安装包判断，只补缺失的 x86 或 x64 包。安装结束只汇总需要重启的组件，不会自动重启 Windows。

在交互式控制台中，下载时会显示文件名、已下载/总大小、速度与百分比；安装时会显示组件序号和安装包序号。结束后会重新检测并打印「安装结果」区块，列出已安装、需重启、未安装、失败的数量，以及每个仍未安装组件的检测原因。交互式运行会响铃并弹出 15 秒自动关闭的提示框；设置环境变量 `GRL_NO_POPUP=1` 可只保留控制台提示，`-NonInteractive` 模式不弹窗。

安装过程按安装包逐个记录结果：某个包失败不会中止同一组件的其余包，最终以退出码 `40` 汇总失败项。「修复缺失组件」（菜单第 4 项）会重新安装所有未完整安装组件在当前平台适用的全部安装包，而不只是补缺失的单个文件。

「在线自定义安装」（菜单第 3 项）使用带复选框的组件列表：默认勾选推荐的核心组件；输入序号勾选，再次输入同一序号取消；`Q` 全选，`T` 恢复推荐，`N` 全不选，`0` 返回主菜单，直接回车确认。

## 命令行

统一入口支持以下参数：

```powershell
-Profile Auto|Windows11-x64|Windows10-x64|Windows10-x86
-Action Menu|InstallOnline|PrepareOffline|InstallOffline|Verify|Status|DllStatus|RepairMissing
-ComponentId <string[]>
-OfflineRoot <path>
-FeatureSource <path>
-Language Auto|zh-CN|en-US
-AllowUnsupportedOS
-NonInteractive
-WhatIf
```

示例：

```powershell
# 查看当前系统状态
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-GameRuntimeLibrary.ps1 -Action Status

# 以英文界面启动
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-GameRuntimeLibrary.ps1 -Language en-US

# 查看官方运行库提供的 DLL / 程序集清单
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-GameRuntimeLibrary.ps1 -Action DllStatus

# 在线安装全部兼容组件
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-GameRuntimeLibrary.ps1 -Action InstallOnline -NonInteractive

# 只安装 VC++ 2015-2022 与 DirectX
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-GameRuntimeLibrary.ps1 -Action InstallOnline -ComponentId vcredist2015-2022,directx9

# 预览在线安装计划，不下载也不修改系统
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-GameRuntimeLibrary.ps1 -Action InstallOnline -WhatIf
```

路径中包含空格时请用引号包住整个路径：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Start-GameRuntimeLibrary.ps1" -Action InstallOffline -OfflineRoot "D:\My Backup\GameRuntimeLibrary"
```

## 离线包

在线电脑执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-GameRuntimeLibrary.ps1 -Action PrepareOffline
```

工具会下载并校验该平台适用的全部组件，在 `dist` 下生成类似：

```text
GameRuntimeLibrary-Windows10-x64-offline-20261102-120000.zip
```

需要控制体积时可加 `-ComponentId` 只打包部分组件；离线清单会记录包含的组件，安装时自动跳过未包含的组件并给出提示。制作过程中会显示每个安装包的下载进度，完成后同样会响铃/弹窗并给出 ZIP 路径。

离线清单会记录每个安装包与功能载荷的 SHA-256；执行离线安装前会整体校验清单与文件，任何不一致都以退出码 `50` 停止，不会带着损坏的包继续安装。

将 ZIP 拷贝到离线电脑并解压，然后运行解压目录中的：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-GameRuntimeLibrary.ps1 -Action InstallOffline -NonInteractive
```

也可以从现有源目录为另一个已解压离线目录执行安装：

```powershell
.\Start-GameRuntimeLibrary.ps1 -Action InstallOffline -OfflineRoot "D:\GameRuntimeLibrary"
```

离线安装不会发起网络请求。若离线包没有包含 `.NET Framework 3.5` 或 DirectPlay 的功能载荷，工具会尝试本地系统缓存；失败后需要提供匹配 Windows 版本的 `sources\sxs`：

```powershell
.\Start-GameRuntimeLibrary.ps1 -Action InstallOffline -FeatureSource "E:\sources\sxs"
```

## 组件清单

默认全量组件：

- .NET Framework 3.5
- .NET Framework 4.8.1
- Microsoft Visual J# 2.0 x86
- Visual C++ 2005 SP1、2008 SP1、2010 SP1、2012 Update 4、2013 Update 5、2015-2022
- DirectX June 2010
- Microsoft XNA Framework 4.0
- OpenAL 1.1
- NVIDIA PhysX 9.21.0713
- DirectPlay 旧版组件

旧版和不可变安装包使用目录中的固定 SHA-256。VC++ 2015-2022 使用微软 `aka.ms` 最新官方链接，并验证文件大小范围、Microsoft Authenticode 签名和最终下载地址。

DLL 由对应厂商安装包统一部署，不从第三方网站下载散装 DLL，也不建议手工复制 DLL 到游戏目录。菜单中的 `DLL / 程序集状态` 展示各安装包提供的主要 DLL、程序集、组件安装状态，以及该文件是否能在标准系统目录（如 `System32`、`SysWOW64`）中找到；映射保存在 `config\dll-map.json`。

组件状态检测会同时参考组件级检测结果和安装包级检测结果：只要组件尚未完整安装（含缺少某个架构的包），就会被视为需要安装或修复。

## 安全与信任

每个安装包在安装前按固定顺序校验，任一步失败都会停止并返回 `20`：

1. 下载地址及其重定向目标必须属于 `config\catalog.json` 声明的官方域名，且必须为 HTTPS。
2. 文件大小必须与目录记录一致，或落在允许的上下限内。
3. SHA-256 必须与目录中的固定值一致；使用最新链接的包以大小范围加签名策略校验。
4. Authenticode 签名必须有效，发布者主体必须包含官方名称。
5. 通过后才交给安装程序静默执行。

下载支持断点续传：续传前会校验服务器返回的区间起点与本地已有长度一致，最终文件仍走完整校验；校验失败的文件会被清理并自动重新下载一次，避免半截文件反复失败。ZIP 解压会限制条目数与解压后总大小，并拒绝路径穿越和带冒号的文件名。

发布构建另有 `config\release-lock.ps1` 记录脚本与配置的 SHA-256；正式版还要求入口脚本、模块与发布清单具有同一代码签名证书。威胁模型、信任边界和已知限制见 [docs/SECURITY.md](docs/SECURITY.md)。

## 日志与诊断

- 日志目录：`%ProgramData%\GameRuntimeLibrary\Logs`，文件名形如 `GameRuntimeLibrary-20261102-120000.log`。
- 只保留最近 30 份日志，更早的日志会被自动清理。
- 控制台的警告与错误会同时写入日志，便于事后排查。
- `-WhatIf` 只打印计划：不下载、不安装、不写程序日志。
- 日志创建失败不会中断安装，只会在控制台提示。

没有管理员权限时日志目录可能不可写，此时以管理员身份重新运行即可获得完整日志。

## 退出码

- `0`：成功
- `10`：安装完成，需要重启 Windows
- `20`：下载、哈希、签名或文件大小校验失败
- `30`：平台不兼容（含 ARM64 与无法识别的系统）
- `40`：部分组件失败
- `50`：发布清单、签名、离线清单或文件完整性失败
- `60`：缺少管理员权限、系统存在挂起重启或功能组件源缺失

## 故障排查

| 现象 | 退出码 | 处理 |
| --- | --- | --- |
| 全部组件安装或已安装完成 | `0` | 无需处理 |
| 提示需要重启，安装本身完成 | `10` | 重启后重新检查状态 |
| 下载中断、哈希或签名不匹配 | `20` | 检查网络与代理，确认能访问厂商官方域名后重试 |
| ARM64 或无法识别的系统 | `30` | 换用受支持平台；仅在明确知晓后果时加 `-AllowUnsupportedOS` |
| 某个组件或安装包失败，其余继续 | `40` | 查看日志中的失败包；常见原因是 `1618`（另一安装程序在运行） |
| 离线清单或发布锁校验失败 | `50` | 重新生成或重新拷贝离线包，不要手工改 `config` 下的文件 |
| UAC 被拒绝、提示挂起重启、DISM 找不到源 | `60` | 允许提权、先重启，或提供 `-FeatureSource` 指向 `sources\sxs` |

按现象与退出码展开的完整处理步骤见 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)。

## 开发与测试

运行完整测试（先做语法检查，再执行 Pester 用例）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

只做语法检查，不加载 Pester：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1 -ParseOnly
```

运行静态质量检查（语法、界面文本键一致性、源码文本键覆盖、README 相对链接、PSScriptAnalyzer）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-Quality.ps1
```

- 检查全部通过时退出码为 `0`，任一检查失败为 `1`。
- 未安装 PSScriptAnalyzer 时该项会打印提示并跳过，不视为失败。
- PSScriptAnalyzer 使用仓库根目录的 `PSScriptAnalyzerSettings.psd1`；其中 `Write-Host`、单数名词、`ShouldProcess` 与位置参数等规则对命令行工具是有意排除的。
- 文档类用例在 `tests\Documentation.Tests.ps1`，校验文档存在性、README 小节、界面文本键一致性与 DLL 清单覆盖。

持续集成配置在 `.github\workflows\ci.yml`：在 `windows-latest` 上，Windows PowerShell 5.1 与 PowerShell 7 都会运行 `tools\Test-Quality.ps1`，而 Pester 用例固定只在 Windows PowerShell 5.1 下执行（Pester 3.4 的断言在 PowerShell 7 上不可靠）；推送与拉取请求都会触发。

测试临时文件写入 `%TEMP%\CodexProjectArtifacts\GameRuntimeLibrary`，不会写入项目缓存目录。

## 维护

校验组件官方下载地址和哈希：

```powershell
.\tools\Update-Catalog.ps1
```

明确更新固定哈希：

```powershell
.\tools\Update-Catalog.ps1 -RefreshFixedHashes
```

生成开发构建：

```powershell
.\tools\Build-Release.ps1 -Mode Development
```

生成正式签名构建：

```powershell
.\tools\Build-Release.ps1 -Mode Production -CertificateThumbprint "<代码签名证书指纹>"
```

生产构建要求本机证书库中存在带私钥和 Code Signing EKU 的公共 CA 代码签名证书，并使用 RFC 3161 时间戳。缺少有效证书时构建会失败。

修改文档、模块或配置后，发布锁会与实际文件哈希不一致，需要重新构建发布包；开发期可用 `-Mode Development` 重新生成 `config\release-lock.ps1`。

## 参与贡献

欢迎提交 Issue 和 Pull Request。报告问题时请附上 Windows 版本、PowerShell 版本、执行的菜单/命令、组件名称和日志片段；提交代码前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

本项目采用 [MIT 许可证](LICENSE)。

## 变更记录

版本历史与未发布变更见 [CHANGELOG.md](CHANGELOG.md)。
