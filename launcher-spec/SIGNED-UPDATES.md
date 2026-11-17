# 应用内更新协议 v1

仅用户点击“更新”才下载、验证并安装；每周检查仍只获取版本列表。取消/失败不得删除用户数据。preview.7 及更早版本必须先手动更新一次。

## 资产与信任

仓库固定为 `shishyguo-cyber/sakura-launcher`。资产为 `Sakura-<规范版本>-macOS.zip` / `Sakura-<规范版本>-windows-x64.zip`，签名为完整文件名加 `.sig`。初始 URL 固定 HTTPS GitHub `/shishyguo-cyber/sakura-launcher/releases/download/v<版本>/<资产名>`；仅允许 GitHub 同仓库下载路径和 GitHub 官方 `release-assets.githubusercontent.com` HTTPS 重定向，不接受用户名、非默认端口、其他主机。版本按 UPDATES.md 比较，必须严格高于当前版本。测试运输仅测试程序可使用 127.0.0.1 HTTP，无生产配置入口。

`.sig` 为 UTF-8 JSON（最大 16 KiB）：`format:1, version, platform, bytes, sha256, signature`。`sha256` 为 ZIP 原始字节的 64 位小写十六进制摘要，`bytes` 为正整数（上限 512 MiB），`signature` 为 ECDSA P-256 / SHA-256 ASN.1 DER 签名的标准 Base64。公钥为 SPKI DER 的 Base64，见 update-public-key.txt，并固化到两端代码。签名原文为以下 UTF-8 字节，LF 换行，包括最后一个 LF：

```text
Sakura Update v1
<version>
<platform>
<bytes 的十进制整数>
<sha256>
```

CryptoKit 的 `signature(for:)` / `isValidSignature` 与 .NET `VerifyData(..., SHA256, Rfc3279DerSequence)` 兼容。签名绑定平台、版本和包内容，不能只签哈希或依赖未认证的 SHA256SUMS。签名失败、大小或摘要不符一律禁止解压/安装。两端执行 conformance/signed-updates.json。

## 状态与安装

`available → downloading（百分比/不定长，可取消）→ verifying → preparing → exiting → replacing → restarting → confirmed`。检查更新与安装共享概览、菜单状态；检查不自动调用安装。取消在退出前有效，安装前再次检查取消；替换阶段不再提供取消。

ZIP 最大解压 2 GiB，拒绝路径穿越、符号链接、重复别名。预留临时卷和目标卷各至少 5 GiB；写入/权限/空间错误均保持旧版。macOS 验证 Sakura.app 标识、版本、可执行文件和 codesign 完整性；Windows 验证 Sakura.exe、Sakura.dll 的产品版本。ZIP 的签名是真实发布者信任依据，ad-hoc codesign 不能替代它。

Mac 用系统 ditto 解压，暂存同一父目录，以 renameatx_np(RENAME_SWAP) 原子交换，旧 app 留在暂存路径。Windows 临时复制现有自包含应用作助手（会多占约一个安装目录空间），旧程序退出后两次目录移动整包替换，失败回滚；助手在程序目录外运行。最多等待旧版退出 30 秒、新版确认 30 秒，再观察存活 2 秒。新版完成数据/库初始化后写入版本确认。确认前保留完整旧版；超时、退出、替换错误则还原并重新打开旧版，提示手动下载。备份清理失败不触发回滚。

失败种类：`network, signature, corrupt, space, permission, structure, version, replacement, startup`。旧版仍运行时显示具体错误和 GitHub 手动入口；退出后的错误由重启旧版显示回退提示，原始错误尽量写入本地 work/failure（日志写入失败也继续恢复）。恢复目录也被权限/外部程序锁住时，保留备份并弹出其路径及 GitHub 手动入口，需手动恢复。进程被强杀/系统断电不属于可保证的自动回滚；不触碰设置、动画和记录目录。

## 密钥

仓库外生成 P-256 私钥，目录 700/文件 600，仅用户持有并离线备份。公开文件检查及包扫描拒绝私钥；只提交公钥。丢失后无法给现有安装签可信更新，需手动升级轮换公钥；泄露应停止发布并以手动更新轮换。签名与 Apple Developer ID / Windows Authenticode 是独立机制；本任务不申请收费签名或公证。

API 格式依据：[Apple DER ECDSA](https://developer.apple.com/documentation/cryptokit/p256/signing/ecdsasignature/derrepresentation)、[Microsoft ECDsa.VerifyData](https://learn.microsoft.com/en-us/dotnet/api/system.security.cryptography.ecdsa.verifydata?view=net-10.0)。
