# 发版流程

Sakura 的公开仓库只放 `public-files.txt` 列出的文件，并有自己独立的提交历史；开发目录的历史、日志和私人素材不进入公开仓库。下面的脚本只处理本地文件：不建仓库、不提交、不推送、不上传。

## 1. 准备

- 改版本号：`launcher-macos/Resources/Info.plist`（`CFBundleShortVersionString`、`CFBundleVersion`，以及“检查更新”使用的完整版本 `SakuraReleaseVersion`，例如 `0.2.0-preview.5`）、`launcher-windows/GardenBoot.App/GardenBoot.App.csproj`（`<Version>`）、`CHANGELOG.md`。
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

Windows x64（自包含目录、完整重建、不带调试信息；先按[开发指南](DEVELOPMENT.md)准备仓库外的本机包源与匹配 SDK，下载前核实实际出口；在 Windows 上运行）：

```powershell
powershell -ExecutionPolicy Bypass -File launcher-windows\scripts\publish-release.ps1 -Output <新目录> -RuntimeVersion <10.0.patch> -Offline -OfflineSource <本机包目录>
```

两个脚本都会在发现开发机用户目录路径时直接失败。

## 3. 打包

```sh
python3 scripts/package-release.py --version <版本> \
    --signing-key "$HOME/.sakura-release/update-signing-key.pem" \
  --mac-app <package.sh 输出的 Sakura.app> --windows-dir <publish-release.ps1 的输出目录> --out <新目录>
```

生成 macOS、Windows、源码三个 ZIP，两份平台 ZIP 的 `.zip.sig` 签名，以及 `SHA256SUMS.txt`、`inventory.json`。安装说明来自 `docs/release/README-*.txt`（`{version}` 会被替换）。ZIP 内容固定时间戳、统一用 `/` 分隔、中文文件名标记 UTF-8、保留可执行权限，不含 `__MACOSX`、`._*`、`.DS_Store` 或 `.pdb`。最后逐文件扫描个人路径（ASCII 与 UTF-16）、私钥和令牌；有任何发现就中止，不留下半成品。

扫描器对微软 .NET 10.0.15 原版 `System.Private.CoreLib.dll` 的语言区域名称表有一个已核实的令牌误报例外，同时绑定文件名、整个文件 SHA-256 与误报片段 SHA-256；不跳过该文件的路径/私钥或其他内容检查。更换 .NET 服务版本后若出现类似误报，需重新对照官方包确认，不能按文件名或供应商整体放行。

## 4. 同步到公开仓库

```sh
python3 scripts/sync-public.py <公开仓库目录>           # 只列出变化
python3 scripts/sync-public.py <公开仓库目录> --apply   # 让公开仓库与导出内容完全一致
```

脚本不运行 git。之后在公开仓库里查看 `git status` / `git diff`，确认后自己提交、推送，等 CI 通过。

## 5. 发布

在 CI 已通过的那个提交上创建 Release，上传第 3 步的七个文件（三个 ZIP、两个平台 ZIP 的 `.sig`、`SHA256SUMS.txt`、`inventory.json`）。缺少签名会导致客户端拒绝更新。正文区分更新包签名与尚未完成的平台分发代码签名/公证，并写清平台和未验收的场景。

发布后更新 README 顶部“下载”区的版本号（两个下载按钮和“所有下载”链接里都有），再按第 4 步同步、推送。预发布版不会被 GitHub 标为“最新版”，所以 README 里不要用 `/releases/latest` 链接，要写具体版本的地址。公开仓库前要启用并测试私密漏洞报告（见 `SECURITY.md`）。

## 应用内更新签名

每个平台 ZIP 必须附带同名 `.zip.sig`，发布时一起上传。协议及信任根见 [SIGNED-UPDATES.md](../launcher-spec/SIGNED-UPDATES.md)。`package-release.py --signing-key` 自动生成并校验公钥匹配；也可分别调用：

```sh
python3 scripts/sign-update.py --key "$HOME/.sakura-release/update-signing-key.pem" \
  --version <版本> --platform macOS Sakura-<版本>-macOS.zip
python3 scripts/sign-update.py --key "$HOME/.sakura-release/update-signing-key.pem" \
  --version <版本> --platform windows-x64 Sakura-<版本>-windows-x64.zip
```

私钥只在发布者 Mac 的仓库外保存，父目录 700，文件 600；不要在终端打印、上传 GitHub/CI、放入源码、构建日志或发布目录。首次建钥用系统 `/usr/bin/openssl ecparam -name prime256v1 -genkey -noout -out <仓库外私钥>`（先 `umask 077`）；导出的 SPKI 公钥固化到两端及 `launcher-spec/update-public-key.txt`。已有密钥不可重新生成覆盖。请离线备份；丢失后现有客户端无法信任新密钥，需要再手动更新一次轮换公钥。泄露后停止签包并轮换。

签名采用系统 CryptoKit / .NET ECDsa，无额外运行时依赖；不是 Apple Developer ID / Authenticode 签名或公证。发布前执行两端签名一致性及隔离更新测试。preview.7 及更早用户需要手动更新一次，才能获取一键更新功能。
