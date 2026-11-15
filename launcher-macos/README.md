# Sakura · macOS

原生 Swift 菜单栏应用，运行最低 macOS 13。功能介绍与界面入口见[项目首页](../README.md)。

## 构建

在仓库根目录运行：

```sh
bash launcher-macos/scripts/build.sh
swift test --disable-sandbox --build-system native --package-path launcher-macos
```

构建入口为 `launcher-macos/build/Sakura.app`，默认链接到系统缓存中的产物。它是本地开发包，使用 ad-hoc 签名，不是经过 Developer ID 公证的正式安装包。工具链与缓存说明见[开发指南](../docs/DEVELOPMENT.md)。

## 使用

手动启动或再次双击应用会打开设置，登录自启保持安静；也可从菜单栏花朵图标打开“调节启动体验…”。在“动画”页导入包含 manifest.json、NOTICE.md 和视频的文件夹；在“应用”页添加已安装应用，并为它指定动画或跟随全局轮换。

Sakura 启动时已运行的目标只记录为基线；之后目标从没有进程变为有进程时触发。预览不需要重启真实目标。按 Esc、Command+. 或点击画面可以跳过；退出程序由菜单控制。

设置默认打开“概览”，按已保存设置解释每个应用的自动播放状态，并提供可收起和重新展开的三步引导。其他页面包括动画、应用、播放、声音与过渡、显示、我的方案。草稿预览不会保存参数；保存成功后用于下次播放。开机自动运行需要用户主动开启。

## 安装与卸载

若需要长期使用，先将构建的应用复制到稳定的用户应用目录，再从那里运行并设置自动运行；不要把缓存目录作为正式安装位置。对外分发应另外验证签名与首次启动流程。

卸载时先在 Sakura 菜单关闭开机自动运行，再退出并移除安装的应用。`~/Library/Application Support/GardenBoot/` 中的动画和设置可按需备份后删除；UserDefaults 和缓存需在确认范围后单独处理，不提供整目录盲删命令。

## 开发检查

```sh
bash launcher-macos/scripts/verify.sh
python3 -m unittest discover -s launcher-macos/scripts/tests -v
```

完整脚本需要图形会话，会生成被忽略的 checks 日志。真实目标、多屏、音频与安装验收见[验证说明](../docs/VERIFICATION.md)。

[包格式](../launcher-spec/PACK-FORMAT.md) · [设置规格](../launcher-spec/EXPERIENCE-SETTINGS.md) · [多目标规格](../launcher-spec/TARGETS.md) · [隐私](../docs/PRIVACY.md)
