# 第三方软件说明

GameRuntimeLibrary 本身不包含任何厂商安装程序。安装包只在运行 `InstallOnline` 或 `PrepareOffline` 时从下列官方发布者地址下载。

| 组件 | 发布者 | 官方页面 |
| --- | --- | --- |
| Visual C++ Redistributable | Microsoft | https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist |
| .NET Framework | Microsoft | https://dotnet.microsoft.com/download/dotnet-framework |
| DirectX End-User Runtimes | Microsoft | https://www.microsoft.com/download/details.aspx?id=8109 |
| XNA Framework | Microsoft | https://www.microsoft.com/download/details.aspx?id=20914 |
| Visual J# | Microsoft | https://www.microsoft.com/download/details.aspx?id=4712 |
| OpenAL | Creative Labs / OpenAL | https://openal.org/downloads/ |
| NVIDIA PhysX | NVIDIA | https://www.nvidia.com/en-us/drivers/physx/physx-9-21-0713-driver/ |

各安装程序保留原始版权、许可和技术支持条款。离线打包仅用于在自有设备之间部署。若向第三方公开分发包含厂商安装包的离线 ZIP，请先独立确认每个厂商当前的再分发许可。

项目不提供 Microsoft、NVIDIA、Creative Labs 或 OpenAL 的替代授权，也不声称这些厂商对本项目提供背书。

本项目不修改厂商安装程序的任何内容：下载后仅做域名、文件大小、SHA-256 与 Authenticode 发布者校验，校验通过即按厂商安装程序的静默参数执行。校验只用于确认文件完整性，不构成对这些软件的再分发许可。完整的信任模型与已知限制见 `docs\SECURITY.md`。
