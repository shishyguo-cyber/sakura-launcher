# 启动包格式（schemaVersion 1）

启动包是一个文件夹，放着启动动画和它的说明。启动器只读包里的文件，不需要改程序配置。

```text
my-pack/
├─ manifest.json      必需
├─ NOTICE.md          必需：权利、许可与声明
├─ intro.mp4          可选：收到启动事件后立刻播放
├─ loop.mp4           可选：ChatGPT 还没准备好时无缝循环
├─ outro.mp4          分段包必需：贴到 ChatGPT 窗口上播放，结尾淡出
└─ cover.png          可选：动画库里显示的封面
```

只有一段视频时，用 `video` 代替以上三段：启动器等 ChatGPT 窗口出现后，贴着窗口播放并在结尾淡出。

## manifest.json

```json
{
  "schemaVersion": 1,
  "id": "demo-garden",
  "name": "花园 · 示例",
  "segments": { "intro": "intro.mp4", "loop": "loop.mp4", "outro": "outro.mp4" },
  "handoffAt": 1.2,
  "fadeDuration": 0.4,
  "volume": 0.8,
  "maxWaitSeconds": 10,
  "loopExit": "cycleEnd",
  "notice": "NOTICE.md"
}
```

| 字段 | 必需 | 说明 |
|---|---|---|
| `schemaVersion` | 是 | 目前只能是 `1` |
| `id` | 是 | 小写字母、数字、连字符，最长 64 个字符；安装后即文件夹名，同 id 再导入会替换 |
| `name` | 是 | 菜单里显示的名字 |
| `segments` | 是 | 键只能是 `intro`、`loop`、`outro`、`video`；值是包内文件名（不能含 `/`、不能以 `.` 开头），扩展名 mp4、m4v 或 mov |
| `handoffAt` | 否 | 最后一段（`outro` 或 `video`）中开始淡出的秒数；默认“结尾减淡出时长”；超出时自动收紧，保证淡出能播完 |
| `fadeDuration` | 否 | 淡出秒数，0.1–2，默认 0.4。用户跳过时固定 0.3 秒 |
| `volume` | 否 | 0–1，默认 1 |
| `maxWaitSeconds` | 否 | 等 ChatGPT 窗口的最长秒数，1–60，默认 10；超时后就地淡出 |
| `loopExit` | 否 | `cycleEnd`（默认，播完当前这一圈再进 outro）或 `immediate`（窗口一就绪就切） |
| `notice` | 否 | 说明文件名，默认 `NOTICE.md` |
| `videoFit` | 否 | 贴到目标窗口时的显示方式：`auto`（默认，比例接近时铺满，否则完整显示并模糊补边）、`fill`（铺满裁边）、`fit`（完整显示），见 VIDEO-FIT.md |
| `cover` | 否 | 封面图片文件名，`png`、`jpg` 或 `jpeg`，文件名规则同视频；建议 16:9。省略时动画库显示第一段视频的首帧 |

不认识的顶层字段会被忽略，便于以后扩展；不认识的片段名会被拒绝。

允许的片段组合：`video`；`outro`；`intro + outro`；`loop + outro`；`intro + loop + outro`。

## 播放流程

1. ChatGPT 新进程启动：分段包立刻在鼠标所在屏幕居中显示并播 `intro`（没有 intro 就直接播 `loop`）。
2. `intro` 播完时窗口还没出现：有 `loop` 就循环，没有就停在最后一帧。
3. 窗口出现：播放器立即（约 0.45 秒动画）移动、缩放到窗口位置并按 `videoFit` 适配，正在播的 `intro` 或 `loop` 在窗口上继续；`intro` 播完、或 `loop` 按 `loopExit` 退出后播 `outro`。
4. 到 `handoffAt` 开始淡出，画面和声音一起渐弱，露出真实窗口，焦点交还 ChatGPT。
5. 跳过（Esc、Command+.、点击画面任意处）随时可用；ChatGPT 退出、在出窗口前被隐藏，或用户切到别的应用会立即关闭。动画出现后的头 1.5 秒内，其他应用短暂激活（Spotlight、Raycast、访达交接）不算切走。
6. 贴到窗口后（无论在哪一段），ChatGPT 窗口如果又移动或改变大小（常见于恢复上次的位置），动画会跟着平滑移过去，直到开始淡出。

以下启动不播放动画：ChatGPT 以隐藏方式启动；启动器在登录时启动（或开机 3 分钟内启动）后的 45 秒内，ChatGPT 随登录一起打开。

## 导入规则

- 导入前完整检查：描述文件、每个文件存在且非空、每段视频能解码且有画面、`NOTICE.md` 存在。
- 写了 `cover` 时，封面必须存在、非空、不超过 8 MB 且能解码为图片，否则整包导入失败。
- 只复制描述文件、引用到的视频、封面和说明文件，包里其他东西不会被带进去。
- 检查或复制失败时，已安装的同 id 包保持原样。
- 安装位置：`~/Library/Application Support/GardenBoot/Packs/<id>/`（Windows：`%LOCALAPPDATA%\GardenBoot\Packs\<id>\`）。
- 在动画库中移除的包移到废纸篓/回收站；随程序附带的示例包不能移除。个人参数、方案与收藏保留，重新导入同 id 包后继续生效。

## 制作建议

- 三段的画幅、帧率、色调保持一致；`loop` 首尾帧应能无缝衔接，单圈建议 1–3 秒，太长会拖慢交接。
- `outro` 的最后画面尽量接近 ChatGPT 窗口的配色与布局，淡出会更自然。
- 默认自动适配：窗口比例与视频接近时铺满（最多裁 12%），差得多时完整显示并用模糊画面补边；重要内容仍建议放在中间。
- `NOTICE.md` 写清楚素材权利与许可。使用第三方角色或标志时，说明来源、非官方、非商用，并且不要把包放进以 MIT 发布的代码仓库。
