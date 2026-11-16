# 验证与已知限制

开发者预览版允许外部开发者检查和贡献，不代表所有系统、解码器或显示器组合均已通过验收。

## 自动检查

- `scripts/tests/`：公开导出的路径逃逸、符号链接、覆盖保护、缺失文件、披露模式与文档链接测试。
- `launcher-macos/Tests/GardenBootCoreTests/`：Swift Core 与共享一致性用例。
- `launcher-windows/GardenBoot.Core.Tests/`：控制台 Core 测试，与 Mac 读取同一套 `launcher-spec/conformance/`。
- `overview.json`：18 组播放状态优先级用例。原生设置检查覆盖已保存状态与草稿隔离、引导关闭/重开、预览不保存，以及 Windows 空动画库恢复。Mac 离屏检查覆盖七页、深浅外观和最小窗口。
- GitHub CI 配置包含公开范围检查、导出工具测试、Mac 测试和应用构建、Windows 解决方案构建与 Core 测试。配置文件存在不代表已在 GitHub 运行成功。

命令见[开发指南](DEVELOPMENT.md)。

## 发布前需要实际操作的场景

请分别执行可勾选的[macOS 用户验收清单](ACCEPTANCE-MACOS.md)与[Windows 用户验收清单](ACCEPTANCE-WINDOWS.md)，记录具体包校验值、系统、显示器、通过/失败/未执行项。Windows 清单包含未装 .NET 的干净 Windows 11 自包含启动步骤。

清单是待用户执行的要求，不是通过声明。Mac 离屏 PNG 只能检查界面布局；已装 .NET 的 Windows 开发机发布成功也不能替代无运行时验收。内部数据名迁移仅有[候选方案](DATA-NAME-MIGRATION.md)，尚未实现。

## 预览限制

- macOS 构建使用 ad-hoc 签名，没有 Developer ID 公证；普通用户分发尚需签名与干净机器验证。
- Windows 分发脚本已改为自包含目录（普通开发构建仍依赖 .NET 10 Windows Desktop Runtime）；自包含构建已在开发机发布验证；未装 .NET 的干净 Windows 11 启动待用户实测，代码签名与完整安装流程仍未验收。内置运行时的安全补丁需随 .NET 服务版本重新发布 Sakura。
- 界面目前以中文为主；macOS 13 最低版本与各 CPU/显示器组合不能仅靠一个 CI 镜像推定支持已验收。
- 预览版内部数据名仍是 GardenBoot；不应通过简单改名移动既有数据目录。

发布时应将针对具体提交、具体平台的实际结果写入 Release notes；本机开发日志不属于公开源码。
