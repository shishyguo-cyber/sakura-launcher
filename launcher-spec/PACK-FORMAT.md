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
| `textOverlay` | 否 | 字符串 `"greeting"` 启用系统绘制的问候文字。省略、`null`、不认识的值或其他类型时只播放视频。 |
| `cover` | 否 | 封面图片文件名，`png`、`jpg` 或 `jpeg`，文件名规则同视频；建议 16:9。省略时动画库显示第一段视频的首帧 |

不认识的顶层字段会被忽略，便于以后扩展；不认识的片段名会被拒绝。

允许的片段组合：`video`；`outro`；`intro + outro`；`loop + outro`；`intro + loop + outro`。

## 问候文字

`"textOverlay": "greeting"` 让 Sakura 绘制问候文字。Windows 目前只为内置 Welcome 包绘制；其他带此字段的包在 Windows 上照常只播放视频。macOS 用系统字体绘制一行动态问候。普通问候包保留各自的视频，光照和英文问候文字绘制于视频上方。

内置包「Welcome · 彩虹手写」（`sakura-greeting`）不播放视频：黑底上用一根彩虹霓虹线写出 `welcome` 加用户在设置里填的称呼（称呼为空时只写 `welcome`）。笔画取自手写字形的骨架（macOS 用系统 Bradley Hand；Windows 优先用随 Office 安装的 Bradley Hand ITC，没有时用系统自带的 Segoe Script），任意称呼都能书写；中文按笔画书写；含 emoji 的称呼在 macOS 改用下面的光扫问候、在 Windows 改为彩虹文字淡入。书写约 1.6–2.8 秒（随字数），约 3.3 秒后贴合已就绪的目标窗口并淡出。

两种问候在慢启动时都保留画面，直到窗口就绪或等待超时。系统开启减少动态效果时跳过位移：彩虹手写整句直接淡入，光扫问候使用静态光照和柔和淡入淡出。纯视频包沿用原有的减少动态效果设置。

光扫问候（普通问候包，以及含 emoji 的称呼）：

清晨使用金光薄雾，午后使用暖白日光，黄昏使用琥珀至紫罗兰光，深夜使用带星点的冷月光。时段以本地 05:00、12:00、18:00 和 23:00 为分界。

播放开始时按本机时间选用英文问候语。所有系统语言均使用下表文案。

| 本机时间（含起点，至下一时段前） | 问候语 |
|---|---|
| 05:00–12:00 | Good morning |
| 12:00–18:00 | Good afternoon |
| 18:00–23:00 | Good evening |
| 23:00–次日 05:00 | Good evening |

深夜沿用 “Good evening”。“Good night” 通常用于道别。

称呼从本机 Sakura 的体验设置读取。输入去掉首尾空白后可留空，或填写单行 1–20 个扩展字素簇，支持中英文和复合 emoji。空值只显示问候语。有称呼时用逗号加空格连接，例如 “Good morning, 小樱🌸”。较宽的文字缩小字号，保持单行完整显示。包内没有自定义文案或个人数据。

格式仍为 schemaVersion 1。旧版 macOS 和当前 Windows 播放视频背景，忽略该字段。当前 macOS 只识别 `"greeting"`。字段不影响片段组合、媒体校验或导入。

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
- `NOTICE.md` 写清楚素材权利与许可。使用第三方角色或标志时，说明来源、非官方、非商用，并且不要把包放进以 MIT 发布的代码仓库；唯一例外是项目所有者确认权利后内置的精选动画（见下文“内置动画”和 docs/MEDIA.md），它仍单独适用自己的 NOTICE。

## 内置动画

程序将随附的包安装到动画库：

- `demo-garden`（`launcher-macos/demo-pack/`，CC0 几何示例）：每次启动都确保存在；当前选择不可用时的回退；不能移除。
- 精选动画（`launcher-macos/featured-pack/`，目前为 `raiden-garden`）：每个用户只安装一次，记录在本机偏好（macOS `featuredInstalled`，Windows `settings.json` 的 `FeaturedInstalled`）。用户移除后不再自动装回。首次成功安装后，仅在用户还没有当前选择时设为当前动画，日志 `featured-made-current id=<id>`；新安装默认：两端都使用内置「Welcome · 彩虹手写」（`sakura-greeting`，日志 `default-made-current id=sakura-greeting`，此后精选包只加入动画库、不再设为当前），所选动画缺失时也回退到它。已有选择（包括几何示例或个人包）的用户升级保持原选择；已安装过精选但尚未写入当前选择的用户也不会因升级被重新设为精选。精选缺失或安装失败时仍使用几何示例回退，不能为了恢复默认值清空已安装标记。
- `sakura-greeting`（macOS `launcher-macos/greeting-pack/`，CC0 问候背景）：附带的无声兼容视频共 2.10 秒，旧读端按普通片段播放。每次启动确保包可用，不能移除，安装时不写当前动画选择。Windows 本次只支持读包及视频回退，尚未内置问候包。
- 独立测试目录（`--test-root`）默认不安装精选动画，`--test-featured` 时才安装，保持受控检查的默认选择为几何示例。

