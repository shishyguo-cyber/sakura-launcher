# Sakura · 共享规格

macOS 版（`launcher-macos/`，Swift）与 Windows 版（`launcher-windows/`，C#）共用：

- `PACK-FORMAT.md`：启动包格式与播放流程。
- `EXPERIENCE-SETTINGS.md`：独立个人设置、方案、草稿预览与保存规则。
- `COMPATIBILITY.md`：测试一下（适配结论）、窗口重新出现时也播放、全屏/演示时不播。
- `PACK-FROM-VIDEO.md`：从一个本地视频创建单视频动画包（名称规则、权利确认、NOTICE 内容）。
- `RESOURCES.md`：空闲资源占用预算、测量方法与记录。
- `TARGETS.md`：多目标应用（每个应用单独选动画、识别进程、按应用记录状态、同一时间只播一个、已安装应用列表）。
- `DESIGN.md`：两端共用的界面设计规范（颜色、字体、布局、菜单措辞、图标、评审方式）。
- `LAUNCH-LATENCY.md`：开场在首帧前不露面、按段就绪、热备与首帧时间日志。
- `VIDEO-FIT.md`：动画贴到目标窗口时的显示方式（自动适配、铺满、完整显示＋模糊补边）。
- `SCHEDULE-AND-LIBRARY.md`：播放频率（每天首次、临时暂停）、动画库轮换、收藏与封面。
- `PLAYBACK-OVERVIEW.md`：按应用显示运行状态、原因优先级与非阻塞使用引导。
- `conformance/`：两端测试共同读取的用例。改动行为时先改这里，再让两端测试都通过。
  - `playback.json`：播放状态机，按顺序输入事件，逐步核对输出命令。
  - `manifest.json`：启动包描述的合法/非法用例，交接时间计算。
  - `geometry.json`：启动画面尺寸、缓动、跟随窗口判断；视频适配模式与内容矩形。
  - `policy.json`：登录/隐藏启动过滤、切走判断、自动播放开关。
  - `experience.json`：个人参数合并、静音、边界、包隔离与 Unicode 方案；v1→v2 升级与播放/动画库偏好校验。
  - `schedule.json`：播放频率判断（每天首次、新的一天起点、时区变化、时钟回拨、临时暂停）与“明天”的时间点。
  - `compatibility.json`：适配结论、重新出现判断、安静时段。
  - `video-pack.json`：从视频创建时的默认名称、扩展名、名称校验、包 id 与说明文本。
  - `targets.json`：Windows 进程匹配、按应用选包与回退、playback-state v1/v2 读取。
  - `library.json`：轮换选包（固定、全部随机、收藏随机、避免连续重复）。
  - `overview.json`：播放状态的优先级、原因与操作入口。

参考实现为 macOS 版 Core；`launcher-macos/Tests/GardenBootCoreTests/ConformanceTests.swift` 与 `launcher-windows/GardenBoot.Core.Tests` 运行同一批文件。
