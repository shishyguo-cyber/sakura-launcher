# 多目标应用（P-009）

用户 2026-11-15 要求：Sakura 不只给 ChatGPT/Codex 播启动动画，而是可以在 Sakura 里选择应用、给指定应用加启动动画。用户选定：**每个应用单独选动画**（或“跟随全局轮换”），每个应用可单独开关；添加方式为**从已安装应用列表选**。

## 1. 数据（experience.json schemaVersion 3）

新增必需的 `targets` 数组（最多 20 项），顺序即界面顺序：

```json
"targets": [
  { "id": "default-codex", "name": "ChatGPT", "enabled": true, "animation": null,
    "mac": { "bundleId": "com.openai.chat" },
    "windows": { "package": "OpenAI.Codex", "exe": "app\\ChatGPT.exe" } },
  { "id": "6f1c…", "name": "Google Chrome", "enabled": true, "animation": "night-garden",
    "windows": { "path": "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe" } }
]
```

- `id`：小写字母、数字、连字符，1–64，数组内唯一。新增时用 UUID（小写）。
- `name`：显示名，去首尾空白后 1–40 字形、无控制字符。
- `enabled`：布尔。
- `animation`：`null` 表示跟随全局（当前动画 + 轮换方式）；否则为包 id（规则同包格式）。包暂时不存在时保留，播放时按第 3 节回退。
- 平台身份：`mac` 只含 `bundleId`（非空、≤ 255）；`windows` 为二选一：`{ "package": 包名（如 OpenAI.Codex，不含版本和发布者后缀）, "exe": 可选，包内相对路径 }` 或 `{ "path": 绝对 exe 路径 }`。一项可以只有一个平台的身份；本机没有身份的项在本机忽略（界面不显示），保存时原样保留。
- 同一平台上身份不得重复（mac 比较 bundleId；windows 的 path 不区分大小写比较；package+exe 不区分大小写比较）。

升级：schemaVersion 2 读入时，`targets` = 一个默认项 `{ id: "default-codex", name: "ChatGPT", enabled: true, animation: null }`，加上本机身份（macOS：`/Applications/ChatGPT.app` 的 bundleId，取不到用 `com.openai.codex`；Windows：`package: "OpenAI.Codex", exe: "app\\ChatGPT.exe"`）。保存写 3。schemaVersion > 3 拒绝写回；只认识 2 的旧程序遇到 3 拒绝写回。

## 2. 识别目标进程

- macOS：`NSRunningApplication.bundleIdentifier` 等于某个已启用目标的 `bundleId`。
- Windows：进程映像路径匹配——`path` 目标为完整路径不区分大小写相等；`package` 目标为路径中包含 `\WindowsApps\<package>_` 的目录，且（若给了 `exe`）以 `\<exe>` 结尾（与此前 Codex 的规则等价）。
- 每个启用的目标各自维护会话（启动器启动时已运行的进程为基线，不补播）；目标从“无进程”到“有进程”即一次冷启动。

## 3. 选包与状态

冷启动时：原有策略（暂停/减少动态效果）→ 登录/隐藏启动过滤 → **该目标**的播放频率判断（`lastAutoPlayAt` 按目标分别记录）→ 选包：

1. `animation` 非 null 且该包可用 → 用它。
2. 否则按全局规则 `PackRotation.choose(rotation, favorites, available, active, lastPackId(该目标), random)`。
3. 指定的包不可用时记日志 `target-pack-missing target=<id> pack=<id>` 并走第 2 条。

**同一时间只播一个**：已有自动播放进行中（含预览）时，其他目标的冷启动记 `playback-skipped reason=busy target=<id>`，不打断当前动画。日志 `launch-detected target=<id> …`、`pack-chosen id=<pack> rotation=<…|target> target=<id>`。

`playback-state.json` schemaVersion 2：`{ "schemaVersion": 2, "snoozeUntil": …, "targets": { "<目标 id>": { "lastAutoPlayAt": …, "lastPackId": … } } }`。读到 v1 时把其 `lastAutoPlayAt`/`lastPackId` 放到 `default-codex` 下；临时暂停仍为全局。

## 4. 已安装应用列表

- macOS：枚举 `/Applications`、`~/Applications`、`/System/Applications` 及其下一层子文件夹中的 `.app`；名称取本地化显示名，图标取系统图标，身份为 bundleId（没有 bundleId 的跳过）。
- Windows：枚举 `shell:AppsFolder`（开始菜单里的全部应用，含商店应用）；名称为显示名，图标取系统图标。商店/打包应用（AppUserModelID 形如 `包族名!应用`）身份为 `package` = 包族名中 `_` 之前的部分；桌面应用身份为快捷方式指向的 exe（`System.Link.TargetParsingPath`，或解析名本身是 exe 路径时直接使用；已知文件夹 GUID 前缀要展开）。取不到 exe 的项不显示。
- 列表按名称排序，可搜索（名称包含，不区分大小写）；已添加的项显示“已添加”且不可再加。Sakura 自己不出现在列表里。枚举在后台进行，首次打开显示“正在读取已安装的应用…”。

## 5. 界面（DESIGN.md v2 风格）

- 导航新增第二项 **应用**（图标：应用网格），位于“动画”之后。
- 页面：分组列表，每行 = 应用图标（24）+ 名称 + 右侧 `[跟随全局轮换 ▾ / 各动画名]` 下拉 + 启用开关 + 文字按钮“移除”（`danger`）。列表末行文字按钮“＋ 添加应用”打开选择窗口（搜索框 + 应用列表，单击“添加”）。一行说明：“同一时间只播放一个动画；正在播放时打开的其他应用不再播放。”
- 目标属于草稿：改动后“有未保存的修改”，保存后立即按新目标监听。
- 菜单状态行在有多个启用目标时显示“正在等待 N 个应用启动”。
- 测试参数 `--test-target`（macOS）/`--test-target-exe`（Windows）仍会用单个测试目标替换全部目标；未给这两个参数时使用设置中的目标。

## 6. 验收

- 共享用例 `conformance/targets.json`（校验、迁移、识别、选包、忙碌）与 `experience.json` v3 用例两端通过。
- 桌面实测：两个受控测试程序分别绑定不同动画，各自启动时播放各自的动画；一个播放中启动另一个时记 busy；禁用的目标不播放；已安装应用列表能列出、搜索、添加。
