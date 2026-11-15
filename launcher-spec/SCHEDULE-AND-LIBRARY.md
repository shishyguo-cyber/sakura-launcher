# 播放频率与动画库（P-003）

两端语义一致；平台只负责取时间、时区偏移、随机数和界面。共享用例：`conformance/schedule.json`、`conformance/library.json`，以及 `experience.json`、`manifest.json` 中的新增用例。

## 1. 数据落点

| 内容 | 文件 | 性质 |
|---|---|---|
| 播放频率、新的一天起点、轮换方式、收藏 | `experience.json`（schemaVersion 2，见 EXPERIENCE-SETTINGS.md） | 用户偏好，经设置窗口草稿保存 |
| 上次自动播放时间、上次播放的包、临时暂停截止时间 | `playback-state.json` | 运行状态，菜单/播放即时写入 |
| 当前包、无限期暂停、减少动态效果覆盖 | 原有存储（macOS UserDefaults / Windows `settings.json`） | 不变 |

`playback-state.json` 与 `experience.json` 同目录（测试根目录下同理）：

```json
{ "schemaVersion": 1, "lastAutoPlayAt": 1794643200.5, "lastPackId": "demo-garden", "snoozeUntil": null }
```

- 时间均为 Unix 秒（可带小数），必须有限且 ≥ 0；`lastPackId` 遵循包 id 规则；三个字段可为 null 或省略。
- 文件缺失、损坏、版本不认识或字段非法：按空状态处理并写日志 `playback-state-reset`，下次写入时覆盖。它是可再生状态，不做恢复副本。
- 写入用原子替换。预览、`--logic-only` 和诊断不写此文件。

## 2. 播放频率

偏好（experience.json `playback`）：

- `frequency`：`everyLaunch`（默认，现有行为）或 `firstOfDay`。
- `dayStartHour`：整数 0–23，默认 4，即凌晨 4 点前仍算前一天。

判断顺序（自动播放时）：原有 `shouldAutoPlay`（无限期暂停、减少动态效果）→ 原有登录/隐藏启动过滤 → **本节 `ScheduleDecision`** → 选包（第 3 节）→ 播放。前两步不变。

`decide(frequency, dayStartHour, state, now, nowOffset, lastOffset)` 返回 `play`、`snoozed` 或 `playedToday`：

1. `snoozeUntil` 非 null 且 `now < snoozeUntil` → `snoozed`（与频率无关）。
2. `frequency == everyLaunch` → `play`。
3. `lastAutoPlayAt` 为 null → `play`。
4. `lastAutoPlayAt > now + 300`（系统时钟被调回）→ `play`。
5. `dayKey(now, nowOffset) != dayKey(lastAutoPlayAt, lastOffset)` → `play`，否则 `playedToday`。

`dayKey(t, offset) = floor((t + offset − dayStartHour × 3600) / 86400)`；`offset` 是该时刻本地时区相对 UTC 的秒数，由平台按各自时刻分别取（macOS `TimeZone.current.secondsFromGMT(for:)`，Windows `TimeZoneInfo.Local.GetUtcOffset`），因此跨时区、夏令时按当时本地日期判断。

`nextDayStart(now, nowOffset, dayStartHour)`：`k = floor((now + nowOffset − h×3600)/86400)`，返回 `(k+1)×86400 + h×3600 − nowOffset`。用于“暂停到明天”；跨夏令时切换可能偏差一小时，可接受。

记录：自动播放的叠加层实际出现时，写 `lastAutoPlayAt = now`、`lastPackId = 本次包 id`。用户随后跳过或切走仍算已播放。被跳过的启动写日志 `playback-skipped reason=snoozed` / `reason=played-today`，并照常结束本次会话。

菜单（两端同名）：

- `暂停 1 小时`：`snoozeUntil = now + 3600`。
- `暂停到明天 N:00`：`snoozeUntil = nextDayStart(...)`，N 为 `dayStartHour`。
- 暂停中状态行显示 `自动播放已暂停到 HH:mm`，并出现 `恢复自动播放`（清空 `snoozeUntil`）。已过期的截止时间视同 null，界面不显示。
- 原有“暂停自动播放”（无限期）保留，优先显示其状态。

## 3. 动画库与轮换

偏好（experience.json `library`）：

- `rotation`：`fixed`（默认，播放当前包）、`shuffleAll`（所有可用包随机）、`shuffleFavorites`（收藏中可用的包随机）。
- `favorites`：包 id 数组，id 规则同包格式，不得重复，最多 200 个；包暂时不存在时保留。

`choose(rotation, favorites, available, active, lastPackId, random)`：

- `available`：当前可播放的已安装包 id，按 id 的序数（逐字节）升序；有问题的包不在其中。
- `active`：原有 `resolveActive` 的结果（可能为 null）。
- `random`：平台提供 `[0, 1)` 的随机数；测试可传 1.0 等边界值，实现按 `min(floor(random × n), n − 1)` 取下标。

1. `fixed` → `active`。
2. `shuffleAll` → 候选为 `available`；`shuffleFavorites` → 候选为 `available` 中在 `favorites` 里的项（保持 `available` 顺序）。
3. 候选为空 → `active`。
4. 候选多于 1 个且含 `lastPackId` → 去掉它，避免连续两次同一包。
5. 返回 `候选[min(floor(random × n), n − 1)]`。

预览始终播放用户正在看的那个包，不经过轮换，也不写状态。日志 `pack-chosen id=<id> rotation=<rotation>`。

## 4. 封面

启动包可选字段 `cover`（见 PACK-FORMAT.md）：包内图片文件名，扩展名 `png`、`jpg` 或 `jpeg`，文件名规则同视频（不含 `/`、不以 `.` 开头）。导入时：存在、非空、不超过 8 MB、能解码为图片，否则整包导入失败并说明原因；成功则随包复制。

未提供封面：界面显示第一段视频的首帧缩略图（平台在 2 秒内取不到时显示带包名的占位卡片）。缩略图只缓存在系统缓存目录，以包 id 与视频修改时间为键，不写入包目录。示例包附带原创 `cover.png`；已安装的示例包副本没有封面而程序附带的版本有封面时，启动时用附带版本刷新一次（个人偏好不受影响）。

## 5. 设置窗口

沿用 P-002 的单一设置窗口与草稿：新增 **动画库** 和 **播放** 两个分区，避免两个窗口各自保存同一文件互相覆盖。

- 动画库：每个包一张卡片——封面、名称、状态（可播放 / 问题原因）、收藏星标、`设为当前`、`预览`、`移除…`；顶部 `导入…` 与轮换方式。
- 播放：频率单选；选“每天首次”时显示“新的一天从 N 点开始”和“今天已于 HH:mm 播放 / 今天尚未播放”；按钮 `下次启动照常播放`（清空 `lastAutoPlayAt`）。
- **草稿内**（需点保存）：收藏、轮换方式、频率、新的一天起点，以及 P-002 的全部参数。
- **立即生效**（不进草稿）：导入、移除、设为当前、预览、下次启动照常播放。界面在这些按钮旁不显示“未保存”标记。
- 立即操作不会丢失草稿，因此不触发保存提示；从托盘/菜单切换当前包或导入包时，设置窗口就地刷新而不关闭。关闭窗口和退出程序仍按 P-002 规则提示保存。
- 在动画库点选另一张卡片即切换正在调节的包，其他包的未保存修改仍留在草稿中；“预览”按钮预览该卡片对应的包。
- 移除：确认对话框写明包名且说明会移到废纸篓/回收站；移到废纸篓（macOS `FileManager.trashItem`，Windows `Microsoft.VisualBasic.FileIO.FileSystem.DeleteDirectory(..., SendToRecycleBin)`，均为系统自带）。个人参数、方案、收藏保留。随程序附带的示例包不可移除（按钮禁用并提示原因）。移除当前包后按原有 `resolveActive` 回退。

## 6. 验收要点

- 两端共享用例全部通过；旧用例不回退。
- v1 设置文件升级后原参数、方案不变；旧程序遇到 v2 文件拒绝写回。
- 隔离测试根目录中实测：每天首次（同日第二次启动不播、改变状态文件时间后再播）、暂停 1 小时与恢复、三种轮换、收藏、封面与首帧缩略图、移除到废纸篓/回收站、示例包不可移除。
- 不重启用户的 ChatGPT、不启用登录项、不切换旧服务、不下载依赖。
