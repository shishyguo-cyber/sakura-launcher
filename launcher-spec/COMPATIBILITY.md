# 真实应用适配与播放时机（P-011）

用户 2026-11-15 同意 Claude 的建议并要求执行：先确保“给任意应用加动画”在真实应用上可靠，并在不合适的时机自动不播。

## 1. 测试一下（每个目标应用）

“应用”页每行增加文字按钮 **测试**。点击后 Sakura 进入该应用的测试状态 30 秒，提示“请在 30 秒内打开 <名称>；如果它正在运行，请先完全退出”。测试期间：

- 只针对这个应用；忽略播放频率、临时暂停、安静时段和“正在播放”判断；**不记录**今日播放状态。
- 检测到冷启动时按正常流程播放该应用绑定的动画（让用户看到真实效果），并记录：开始时它是否已在运行、是否检测到冷启动、首个主窗口出现的秒数、动画结束原因。
- 测试结束（动画结束或 30 秒到期）后，在该行名称下方显示结论（`textSecondary` 12 号，成功用 `success`），并写日志 `compat-result target=<id> verdict=<…> window=<秒|none>`。结论保存在 `playback-state.json` 的 `targets.<id>.compat`（`verdict`、`windowSeconds`、`at`），重启后仍显示。

结论 `CompatibilityRules.verdict(runningAtStart, coldStart, windowSeconds, maxWait)`：

| verdict | 条件 | 行内文案 |
|---|---|---|
| `good` | 检测到冷启动，且主窗口在 `maxWait` 秒内出现 | 适配良好：打开后约 N 秒出现窗口 |
| `slowWindow` | 冷启动，主窗口出现但晚于 `maxWait` | 窗口出现较慢（约 N 秒），可调大“最长等待” |
| `noWindow` | 冷启动，30 秒内没找到主窗口 | 检测到启动，但没找到主窗口（可能只在托盘运行） |
| `alreadyRunning` | 开始时已在运行，期间没有冷启动 | 它一直在后台运行，打开时不会产生新进程；可开启“窗口重新出现时也播放” |
| `notOpened` | 开始时未运行，30 秒内没有冷启动 | 没有检测到它被打开 |

秒数保留一位小数；`maxWait` 用该应用实际生效的最长等待。

## 2. 窗口重新出现时也播放（每个目标，可选）

目标新增可选字段 `playOnReappear`（布尔，默认 false）。界面在该行展开的选项里显示开关“窗口重新出现时也播放”，`alreadyRunning` 结论旁给出“开启”快捷按钮。

`ReappearTracker` 只对开启此项、且进程已在运行的目标工作，按约 0.5 秒采样，每次输入 `(t, running, hidden, hasWindow, hasVisibleMain)`：

- `hidden`：应用被系统隐藏（macOS ⌘H）。隐藏期间视为“有窗口”，取消隐藏不触发。
- `hasWindow`：存在主窗口尺寸（≥ 400×300）的顶层窗口，**包括最小化的**。最小化后还原不触发。
- `hasVisibleMain`：存在可见、未最小化的主窗口。

规则：进程运行且 `!hidden && !hasWindow` 连续 ≥ 2 秒，记为“已收起”；之后首次出现 `hasVisibleMain` 时触发一次 `reappear`，并清除“已收起”。进程退出则重置。冷启动（新进程）仍走原流程，不由此触发。

`reappear` 进入正常判断（策略 → 安静时段 → 正在播放 → 播放频率 → 选包），记 `launch-detected target=<id> kind=reappear`，以窗口已就绪方式开始播放（直接在窗口上播最后一段并淡出），按应用记录今日播放。

## 3. 安静时段：全屏、演示时不播

`playback` 新增 `quietWhenFullscreen`（布尔，默认 true；界面“播放”页开关“全屏或演示时不播放”）。判断位置：原有策略与登录过滤之后、“正在播放”之前；跳过时记 `playback-skipped reason=quiet target=<id> detail=<…>`。

- Windows：`SHQueryUserNotificationState` 返回 `QUNS_BUSY`（全屏应用）、`QUNS_RUNNING_D3D_FULL_SCREEN`（全屏游戏）或 `QUNS_PRESENTATION_MODE`（演示模式）时视为安静；`detail` 为 `fullscreen`、`game`、`presentation`。
- macOS：当前前台应用（不是目标本身、也不是 Sakura）有一个覆盖整块屏幕的普通窗口时视为安静，`detail=fullscreen`。
- 系统“勿扰/专注”和屏幕共享目前两端都没有可靠的公开检测接口，**不承诺**；在说明中写明。

新增字段均为可选、缺省取默认值，schemaVersion 仍为 3（尚未公开发布，旧开发版保存时可能丢掉这些字段）。

## 4. 共享用例

`conformance/compatibility.json`：`verdict`（结论）、`reappear`（采样序列 → 期望触发的采样序号）、`quiet`（开关 × 系统状态 → 是否跳过）。
