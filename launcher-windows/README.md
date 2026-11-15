# Sakura · Windows

原生 .NET 10 / WPF 托盘应用，当前面向 Windows 11。功能与产品边界见[项目首页](../README.md)。

## 本地构建与测试

安装 .NET 10 SDK（含 Windows Desktop targeting pack），在仓库根目录运行 PowerShell：

```powershell
dotnet build launcher-windows/GardenBoot.slnx -c Release
dotnet run --project launcher-windows/GardenBoot.Core.Tests -c Release
```

输出位于 `launcher-windows/GardenBoot.App/bin/Release/net10.0-windows/`。运行 `Sakura.exe` 时需保留同目录的依赖及 `demo-pack`，不要只搬走 EXE。普通构建还需要目标机器安装 .NET 10 Windows Desktop Runtime；自包含发布方案见[开发指南](../docs/DEVELOPMENT.md)。

## 使用

手动启动或再次双击打开设置，登录自启保持安静。图标位于通知区域，可能折叠在隐藏图标中，也可从托盘打开“调节启动体验…”。导入动画并在“应用”页选择目标。启动时已运行的目标不会补播，之后冷启动才触发。Esc 或点击动画可跳过，退出由托盘菜单控制。

“概览”按已保存设置解释每个应用的自动播放状态，三步引导可以收起或重新查看。没有可用动画包时仍可进入设置导入恢复。

每个应用可指定动画或跟随全局轮换，最多配置 20 个目标；同一时间只播放一个。动画库、播放频率、音量和方案入口见设置窗口。预览读取草稿；主动保存后参数才用于之后的自动播放。

## 安装与卸载

开发包目前没有安装器或代码签名。长期使用时把整个发布目录放到稳定位置，再主动开启“开机自动运行”。它只写当前用户的 Run 配置；移动程序后需要重新设置。

卸载前关闭自动运行、退出 Sakura，再移除应用目录。用户数据位于 `%LOCALAPPDATA%/GardenBoot/`，备份需要保留的动画后可按需删除。不要求管理员权限来管理当前用户的偏好。

## 桌面检查

`GardenBoot.UiChecks` 与 `GardenBoot.GuiFixture` 是独立的界面检查工具，应在已登录桌面、隔离测试目录中运行。`scripts/check-gui.ps1` 只操作自己创建的受控测试进程；不会代替用户重启真实 Codex。实际冷启动、多屏、热键和声音验收见[验证说明](../docs/VERIFICATION.md)。

[包格式](../launcher-spec/PACK-FORMAT.md) · [设置规格](../launcher-spec/EXPERIENCE-SETTINGS.md) · [多目标规格](../launcher-spec/TARGETS.md) · [隐私](../docs/PRIVACY.md)
