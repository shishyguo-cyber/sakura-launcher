# 开发指南

## 前提

Mac 端运行要求 macOS 13+；构建需要包含 Swift 的 Xcode/Command Line Tools。当前构建脚本使用 SwiftPM native build system；请先确认 `swift --version`，使用支持该命令的工具链。

Windows 端使用 Windows 11、.NET 10 SDK（含 Windows Desktop targeting pack）与 WPF。无需连接维护者的测试电脑。两端没有第三方包依赖；系统框架和 SDK 不随源码提供。开发辅助脚本使用 Python 3.10+ 标准库。

## macOS

```sh
bash launcher-macos/scripts/build.sh
swift test --disable-sandbox --build-system native --package-path launcher-macos
```

构建脚本默认将缓存与产物放在 `~/Library/Caches/GardenBoot/`，并在 `launcher-macos/build/Sakura.app` 创建入口。可对每次命令设置 `GARDENBOOT_WORK_ROOT` 使用独立缓存；不修改全局环境。完整本地集成检查（需要图形会话）为：

```sh
bash launcher-macos/scripts/verify.sh
python3 -m unittest discover -s launcher-macos/scripts/tests -v
```

GUI 不可用的退出状态应记录为未执行，不可写成桌面通过。检查输出会生成在 `launcher-macos/checks/`，不提交这些本机日志。

## Windows

在仓库根目录运行 PowerShell：

```powershell
dotnet build launcher-windows/GardenBoot.slnx -c Release
dotnet run --project launcher-windows/GardenBoot.Core.Tests -c Release
```

核心测试是自带控制台测试程序，应使用 `dotnet run`，不以一次空的 `dotnet test` 代替测试结果。WPF 界面检查需要已登录桌面会话；仅通过 SSH 编译不能证明托盘或播放器行为。

普通 `dotnet build` 仍依赖目标机器的 .NET 10 Windows Desktop Runtime。分发用脚本改为 **win-x64 自包含目录**，用户无需另装 .NET；保留整个目录及动画资源，不裁剪（WPF 不支持 trimming），不合并为单文件 EXE。

### 准备离线运行时包

1. 先确定要发布的 .NET 10 服务版本，使用包含所需 Windows Desktop targeting pack 和 win-x64 app-host pack 的 .NET 10 SDK；记录 `dotnet --info`。每次构建显式传 `-RuntimeVersion <10.0.patch>`，避免 SDK 更新后悄悄换包。
2. 在**仓库外**建立本机 NuGet 包源目录（例如构建工作区旁的 `nuget-offline`，不提交）。下载前确认该次连接（包括重定向/CDN）的实际出口不走 IPE；无法确认就停止。不要修改代理、认证或全局 NuGet 配置来完成下载。
3. 从 NuGet 的微软官方包页面选定相同版本的以下两个包，用 “Download package” 保存完整 `.nupkg` 到该目录：
   - [Microsoft.NETCore.App.Runtime.win-x64](https://www.nuget.org/packages/Microsoft.NETCore.App.Runtime.win-x64)
   - [Microsoft.WindowsDesktop.App.Runtime.win-x64](https://www.nuget.org/packages/Microsoft.WindowsDesktop.App.Runtime.win-x64)
4. 如果 SDK 安装的 app-host pack 服务版本与 `-RuntimeVersion` 不同，还需在此目录准备同版本 [Microsoft.NETCore.App.Host.win-x64](https://www.nuget.org/packages/Microsoft.NETCore.App.Host.win-x64)；脚本会先检查并提示缺包。不要为了省包而固定到过期服务版本。
5. SDK 也可能预下载无关的传递框架运行时包；当前 .NET SDK 10.0.401 还要求同版本 [Microsoft.AspNetCore.App.Runtime.win-x64](https://www.nuget.org/packages/Microsoft.AspNetCore.App.Runtime.win-x64)。它仅供构建还原，不会成为 Sakura 的运行依赖；缺包时按离线错误准备，禁止改成联网回退。
6. 文件名保留 `<包名>.<版本>.nupkg`（大小写不敏感），记录来源、实际线路、文件大小和 SHA-256；不要解压代替包文件。这些包不需要加入项目的 PackageReference。若 SDK 自带的 reference pack 不全，须另行准备匹配的 SDK，不能将离线失败改成联网重试。

从仓库根目录在 Windows PowerShell 运行（占位值先替换）：

```powershell
powershell -ExecutionPolicy Bypass -File launcher-windows\scripts\publish-release.ps1 -Output <全新发布目录> -RuntimeVersion <10.0.patch> -Offline -OfflineSource <仓库外的本机包目录>
```

脚本以此目录为唯一包源，禁用 NuGet 审计联网，使用发布目录旁的一次性空缓存，完整重建后无还原发布；缺包直接失败，不回退到网络。SDK 和源码已有的本地文件仍是构建前提。省略 `-Offline` 会正常联网还原，执行前也须确认实际出口。

脚本核对运行时文件与版本、清除 PDB 并扫描构建机路径，输出发布目录总字节。之后用 `scripts/package-release.py` 生成附件并扫描 ZIP。已安装 .NET 的开发机不能证明“无需运行时”，还须执行[干净 Windows 验收清单](ACCEPTANCE-WINDOWS.md)。

自包含运行时**不会**随目标机器的共享 .NET 更新得到安全补丁。维护者需跟随 [.NET 服务更新](https://learn.microsoft.com/en-us/dotnet/core/deploying/)更新 SDK/包与 `RuntimeVersion`，重新构建、验证和发布 Sakura；每次记录实际包含的运行时版本。代码签名与完整安装验收仍是独立事项。

## 示例媒体

仓库已包含小型 CC0 示例，普通构建不需要 FFmpeg。可选的再生成方式：

```sh
bash launcher-macos/demo-pack/generate.sh
```

脚本使用当前命令 PATH 中的 `ffmpeg`，也可仅对这次命令指定 `SAKURA_FFMPEG` 为本机二进制路径；不安装工具、不写全局 PATH，也不下载素材。

## 公开范围

```sh
python3 -m unittest discover -s scripts/tests -v
python3 scripts/check-public-tree.py
python3 scripts/export-public.py ../Sakura-public
```

目标目录必须不存在。导出仅复制 `public-files.txt` 中的文件，不复制 Git 元数据、历史、机器配置或未列出的内容；不会创建远端仓库或推送。导出目录可再运行 `python3 scripts/check-public-tree.py --strict` 验证没有额外文件。

CI 运行范围与桌面验收边界见[验证说明](VERIFICATION.md)。发版打包与公开仓库同步见[发版流程](RELEASING.md)。

## 界面预览

只渲染自身设置页面，不启动目标应用；可使用一个临时空目录隔离数据：

```sh
launcher-macos/build/Sakura.app/Contents/MacOS/GardenBoot --render-settings overview.png --page overview --appearance light --size 820x560 --test-root /tmp/Sakura-render
python3 launcher-macos/scripts/check-design-render.py
```

`--size` 仅用于离屏设置渲染，范围为宽 820–1600、高 560–1200；默认 960 × 640，PNG 以 2× 输出。该入口不连接运行状态，状态区明确显示“界面预览”。运行中的应用通过实际控制器展示已保存配置的状态。

![Sakura macOS 深色概览界面](images/overview-dark.png)

动画库界面：[浅色](images/settings-light.png) · [深色](images/settings-dark.png)。应用页（含“测试”结论示例）：[浅色](images/targets-light.png) · [深色](images/targets-dark.png)。应用页示例使用占位应用标识，因此显示通用图标，不出现其他公司的应用图标。

截图使用隔离数据和 CC0 示例，由应用自身的离屏渲染入口生成，未捕获私人桌面或应用内容。
