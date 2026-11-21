# CyberKuku 更新与发布

从「设置 → 伙伴 → 应用更新」或应用主菜单打开更新窗口。默认每天检查一次。点击「下载安装更新」后，应用显示字节进度，验证通过即安装并重新启动。

1.0 起，更新清单统一为 [update.json](https://github.com/go1f/cyberkuku/releases/latest/download/update.json)。它使用 Ed25519 签名，指向仓库中与版本匹配的 `CyberKuku-X.Y.Z-macOS-arm64.zip`。应用校验下载长度、SHA-256、归档结构、应用标识、签名证书和构建号。安装助手在同卷替换应用，失败时回滚。上一版保存在应用同目录的 `.cyberkuku-update-UUID/previous.app`。

从 0.x 进入 1.0 需手动安装一次。1.0 使用 `com.kojyufu.cyberkuku` 和独立的应用数据目录。再次开始监测时，请授权摄像头并重新校准。

## 发布流程

1. 更新 `App/Info.plist` 的版本与构建号，编写 `docs/release-vX.Y.Z.md`。
2. 运行 `zsh scripts/build_release.sh` 与 `zsh scripts/create_dmg.sh`，生成签名应用、ZIP、DMG 和校验文件。
3. 运行 `python3 scripts/build_update_manifest.py`，生成 `release/update.json`。更新签名私钥保存在登录钥匙串。
4. 用 `release/CyberKuku.app/Contents/MacOS/CyberKuku --update-manifest-check release/update.json release/CyberKuku-X.Y.Z-macOS-arm64.zip` 核验签名与安装包。
5. 提交并推送源码和版本标签。将 ZIP、DMG、两份 SHA-256 文件、`update.json` 和 `extensions/catalog.json`（上传名 `extensions.json`）上传到同一 Release。发布后匿名核验最新更新入口、安装包下载以及 `extensions.json`。

签名命令使用维护者机器上 `.local/sparkle/bin/sign_update`，该工具来自 [Sparkle 官方发布](https://github.com/sparkle-project/Sparkle/releases)。应用包使用 macOS 原生更新助手。发布密钥通过钥匙串迁移。应用签名证书指纹由 `UpdateInstallation.requirement` 固定。
