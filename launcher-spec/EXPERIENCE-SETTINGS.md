# 个人体验设置（schemaVersion 2）

`experience.json` 与动画包独立保存。macOS 在 `~/Library/Application Support/GardenBoot/`，Windows 在 `%LOCALAPPDATA%\GardenBoot\`；测试使用自己的根目录。现有暂停、当前包、系统动画覆盖和登录项设置保持原存储方式。

```json
{
  "schemaVersion": 2,
  "masterVolume": 0.7,
  "muted": false,
  "packs": {
    "demo-garden": {
      "overrides": {
        "fadeDuration": 0.6,
        "maxWaitSeconds": 15,
        "loopExit": "cycleEnd",
        "launchCoverage": 0.6
      },
      "presets": [
        {
          "id": "7a96c110-d327-42f5-bcea-a28f297d465d",
          "name": "轻柔",
          "overrides": { "fadeDuration": 0.6, "launchCoverage": 0.6 }
        }
      ]
    }
  },
  "playback": { "frequency": "firstOfDay", "dayStartHour": 4 },
  "library": { "rotation": "shuffleFavorites", "favorites": ["demo-garden"] }
}
```

## 版本

- schemaVersion 2（P-003）新增必需的 `playback` 与 `library` 两节，规则见 [SCHEDULE-AND-LIBRARY.md](SCHEDULE-AND-LIBRARY.md)。
- 读到 schemaVersion 1：两节取默认值（`everyLaunch`、4 点、`fixed`、无收藏），其余字段原样保留；保存时写为 2。
- schemaVersion 3（P-009）新增必需的 `targets`（见 TARGETS.md）；读到 2 时补上本机默认目标 `default-codex`，保存写 3。
- schemaVersion 大于 3：拒绝写回（与下文“不支持的版本”规则相同）。只认识 1 的旧程序遇到 2 同样拒绝写回，不会丢失新字段。

## 合并与校验

schemaVersion 1 顶层四个字段必需，schemaVersion 2 另需 `playback`、`library`；包偏好内 `overrides` 和 `presets` 必需；方案内 `id`、`name` 和 `overrides` 必需。未知字段忽略，不支持的版本拒绝写回。

- 总音量 `masterVolume`：0–1，默认 1；`muted` 默认 false。播放音量 = 包默认音量 × 总音量，静音时为 0。
- 每包 `overrides`：所有成员可省略或为 null，表示继承包默认值；主动填写默认数值仍算覆盖。
- `fadeDuration`：0.1–2 秒；`handoffAt`：有限、非负秒数，省略时继承包交接点或自动结尾；依然按最终媒体时长收紧。
- `videoFit`：`auto`、`fill`、`fit` 或 null（继承包默认，再默认 `auto`），见 VIDEO-FIT.md。
- `maxWaitSeconds`：1–60；`loopExit`：严格为 `cycleEnd` 或 `immediate`；`launchCoverage`：0.4–0.9，省略为 0.72；`fullScreen`：可选布尔值，`true` 时该动画盖住整个屏幕（macOS 含菜单栏和程序坞，Windows 含任务栏）播放、在原处淡出、不贴到目标窗口，此时不使用 `launchCoverage`，`videoFit` 决定画面如何适配屏幕；省略或 `false` 为关闭，关闭时不写入。
- 覆盖比例仅影响开场，保持最大宽度 1120、屏幕可见区域和收尾停靠规则。
- 数值必须有限，拒绝错误类型、NaN、Infinity；JSON 不接受以字符串代替数字。
- 包键使用包格式的 id 规则。过往包的偏好保留，包暂时不存在时不删个人方案。
- 方案名称去除两端空白后为 1–40 个 Unicode 字形，不含控制字符；同一包内名称不可重复，规范等价 Unicode 名称视为相同。方案 id 非空、最长 64 字符且在包内唯一。

命名方案只复制当前包的覆盖参数。总音量和静音独立；应用方案不改变它们。恢复本包默认参数会清空覆盖并保留已存方案；全局音量恢复只重置总音量和静音。

## 草稿、保存与错误

参数窗口持有草稿。预览使用草稿的独立播放快照，不写文件、不改视频、不重启目标应用；自动播放只使用已保存设置。已有播放不在调节过程中跳转时间点。预览模拟约 3 秒后窗口就绪，并遵守当前等待上限；上限更短时提前淡出结束。

保存先校验，再原子替换文件，只有写盘成功后才更新程序内的已保存状态。加载损坏文件时使用默认体验并显示说明，保留原文件；用户主动保存新设置时先写入 `experience.recovery-<UUID>.json` 恢复副本。遇到不支持的版本时继续保留文件并拒绝写回。

未保存时关闭、切包、导入其他包或退出，提供保存、放弃和继续编辑的选择。失败预览会关闭叠加层并在设置窗口提示检查/重新导入，设置窗口仍可编辑。

共享 `conformance/experience.json` 覆盖合并、范围、静音、包隔离与 Unicode 方案；两端另有实际文件存储和方案快照用例。

Windows 核心和测试使用与 WPF 程序一致的正常 .NET 全球化模式，以支持 Unicode 名称比较；不额外安装包。有关运行模式与规范化行为参见 [Microsoft 全球化设置](https://learn.microsoft.com/en-us/dotnet/core/runtime-config/globalization)和 [String.Normalize](https://learn.microsoft.com/en-us/dotnet/api/system.string.normalize?view=net-10.0)。

## 称呼（macOS 与 Windows）

`experience.json` 可包含字符串字段 `greetingName`。缺省、空白或 `null` 表示只显示问候语。两端保存和读取时都去掉首尾空白，并按 [启动包格式](PACK-FORMAT.md)验证单行和长度。该字段随本机体验设置从版本 1 或 2 迁移到版本 3，无需提高设置 schemaVersion。称呼不读取系统用户名，不随包导出，也不跨设备同步。

问候语按本机时段固定使用英文。称呼支持中文和 emoji，显示时用逗号加空格连接，例如 “Good morning, 小樱🌸”。深夜沿用 “Good evening”。[问候时段表](PACK-FORMAT.md#问候文字)
