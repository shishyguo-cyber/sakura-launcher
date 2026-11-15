# 来源与第三方说明

Sakura 的启动动画创意受到 [dragon-codex-boot](https://github.com/yushua0808-cpu/dragon-codex-boot) 启发。当前公开实现采用独立的进程监听、播放状态机与动画包规格；项目中保留查重辅助脚本，用于定位可能的重合，不将其统计量作为原创性或授权证明。

参考项目的原始 MIT 许可与署名另存于[许可附件](docs/licenses/dragon-codex-boot-MIT.txt)，以保留来源信息。

Sakura 是独立的社区项目，与 OpenAI 无隶属或背书关系。ChatGPT、Codex 是 OpenAI 的商标；文档和默认设置提到它们只是为了说明兼容的目标应用，不使用其标志。应用列表里显示的图标由系统按用户本机已安装的应用提供，不随 Sakura 分发。

自有代码许可见 [LICENSE](LICENSE)。内置几何示例媒体的许可见 [demo-pack/NOTICE.md](launcher-macos/demo-pack/NOTICE.md)。

Mac 端使用 Apple 系统框架，Windows 端使用 .NET / WPF 与 Windows 系统接口；这些框架、SDK 和运行时分别适用其提供方的许可。本源码仓库不重新许可这些组件，也不附带 SDK、FFmpeg、Remotion、浏览器或模型。

示例再生成工具可以调用开发者本机提供的 FFmpeg。FFmpeg 的许可不由 Sakura 的 MIT 许可证替代；若分发包含运行时或第三方二进制的安装包，发布者应另外审查对应许可并附必要声明。

用户导入的媒体不会自动获得 MIT 或 CC0 许可。内置同人动画「雷电将军 · 花园」（`launcher-macos/featured-pack/`）单独适用其 NOTICE 中的条款：仅供个人非商业使用，不适用 MIT 或 CC0，权利方要求时会立即下架。模型、参考图和私人制作记录不包含在此公开快照中。素材与发布附件规则见[媒体政策](docs/MEDIA.md)。
