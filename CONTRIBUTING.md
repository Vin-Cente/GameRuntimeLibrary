# 参与贡献

感谢你愿意改进 GameRuntimeLibrary。无论是报告问题、补充文档还是提交代码，都请先阅读下面的约定。

## 报告问题

请优先使用仓库的 Issue 模板，至少提供：

- Windows 版本与 Build 号（例如 Windows 10 22H2 Build 19045.3803 x64）。
- PowerShell 版本（`$PSVersionTable.PSVersion`）。
- 执行的菜单项或命令，例如 `-Action InstallOnline -ComponentId dotnet35`。
- 涉及的组件名称与安装包文件名。
- 期望结果与实际结果。
- `%ProgramData%\GameRuntimeLibrary\Logs` 下最新日志的相关片段。

请先搜索已有 Issue，避免重复。不要粘贴包含个人路径、账号、序列号或未脱敏日志的内容。

## 提交代码

1. Fork 仓库并从 `main` 创建分支。
2. 保持 Windows PowerShell 5.1 兼容；不要引入仅 PowerShell 7 可用的语法。
3. 修改后至少运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-Quality.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-GameRuntimeLibrary.ps1 -Action Status -NonInteractive
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Start-GameRuntimeLibrary.ps1 -Action InstallOnline -WhatIf -NonInteractive
```

4. 如果修改了受发布锁保护的文件（`src`、`config` 下的 `catalog/profiles/dll-map/ui-text`、`README.md`、`CHANGELOG.md`、`docs`、`Start-GameRuntimeLibrary.ps1`、平台入口），必须重建发布锁：

```powershell
.\tools\Build-Release.ps1 -Mode Development
```

5. 更新 `CHANGELOG.md` 的 `Unreleased` 小节。
6. 提交 Pull Request，说明变更内容、验证命令和结果。

## 代码约定

- 文件使用 UTF-8 with BOM；代码中的引号使用 ASCII 直引号。
- 新增面向用户的文本必须同时补齐 `config\ui-text.json` 的中英文键。
- 涉及安装、下载、删除或系统修改的路径必须支持 `-WhatIf`，并在失败时返回稳定退出码。
- 不要提交安装包、日志、`dist` 构建产物或个人路径。
- 注释解释“为什么”，不要复述代码。

## 许可证

提交贡献即表示同意以本项目的 [MIT 许可证](LICENSE) 授权你的贡献。
