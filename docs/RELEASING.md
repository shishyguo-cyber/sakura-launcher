# 发版流程

Sakura 的公开仓库只放 `public-files.txt` 列出的文件，并有自己独立的提交历史；开发目录的历史、日志和私人素材不进入公开仓库。下面的脚本只处理本地文件：不建仓库、不提交、不推送、不上传。

## 1. 准备

- 改版本号：`launcher-macos/Resources/Info.plist`（`CFBundleShortVersionString`、`CFBundleVersion`）、`launcher-windows/GardenBoot.App/GardenBoot.App.csproj`（`<Version>`）、`CHANGELOG.md`。
- 两端测试与桌面检查通过（见 [验证说明](VERIFICATION.md)）。
- 导出公开源码并做严格检查：

```sh
python3 scripts/export-public.py <新目录>/Sakura-<版本>
python3 <新目录>/Sakura-<版本>/scripts/check-public-tree.py --strict
```

## 2. 构建发布用程序（从导出的公开源码构建）

macOS（通用版、去掉调试信息、ad-hoc 签名；工作目录默认 `~/Library/Caches/Sakura-release`，不影响日常开发版）：

```sh
bash <导出目录>/launcher-macos/scripts/package.sh
```

Windows x64（完整重建、不带调试信息、离线还原；在 Windows 上运行）：

```powershell
powershell -ExecutionPolicy Bypass -File launcher-windows\scripts\publish-release.ps1 -Output <新目录> -Offline
```

两个脚本都会在发现开发机用户目录路径时直接失败。

## 3. 打包

```sh
python3 scripts/package-release.py --version <版本> \
  --mac-app <package.sh 输出的 Sakura.app> --windows-dir <publish-release.ps1 的输出目录> --out <新目录>
```

生成 macOS、Windows、源码三个 ZIP，以及 `SHA256SUMS.txt`、`inventory.json`。安装说明来自 `docs/release/README-*.txt`（`{version}` 会被替换）。ZIP 内容固定时间戳、统一用 `/` 分隔、中文文件名标记 UTF-8、保留可执行权限，不含 `__MACOSX`、`._*`、`.DS_Store` 或 `.pdb`。最后逐文件扫描个人路径（ASCII 与 UTF-16）、私钥和令牌；有任何发现就中止，不留下半成品。

## 4. 同步到公开仓库

```sh
python3 scripts/sync-public.py <公开仓库目录>           # 只列出变化
python3 scripts/sync-public.py <公开仓库目录> --apply   # 让公开仓库与导出内容完全一致
```

脚本不运行 git。之后在公开仓库里查看 `git status` / `git diff`，确认后自己提交、推送，等 CI 通过。

## 5. 发布

在 CI 已通过的那个提交上创建 Release，上传第 3 步的五个文件，正文写清楚未签名、平台和未验收的场景。

发布后更新 README 顶部“下载”区的版本号（两个下载按钮和“所有下载”链接里都有），再按第 4 步同步、推送。预发布版不会被 GitHub 标为“最新版”，所以 README 里不要用 `/releases/latest` 链接，要写具体版本的地址。公开仓库前要启用并测试私密漏洞报告（见 `SECURITY.md`）。
