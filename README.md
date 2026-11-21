# CyberKuku · 桌面电子伙伴

默认的小灰猫可以独立留在桌面。从菜单栏可打开设置及已启用插件的快捷操作。「同学请注意坐姿！」使用 MacBook 内置摄像头进行本地分析，提醒通过宿主气泡显示。面向笔记本敞开、外接显示器位于上方的工作情境，不需要外接摄像头或手机。

## 安装

从 [GitHub 最新发行版](https://github.com/go1f/cyberkuku/releases/latest) 下载 macOS arm64 DMG，打开后把 `CyberKuku.app` 拖到 Applications。也提供 ZIP。安装后可从“应用程序”、Spotlight 或 Dock 启动，菜单栏入口继续保留。

发行包包含原生界面、本地 MediaPipe 推理运行时和模型，**无需安装 Python、无需克隆项目，也不需要联网推理**。目标为 Apple Silicon Mac，包括 M5 / macOS 27；当前已在 M2 / macOS 27 验证，尚未在 M5 实机测试。

当前发行包使用登录钥匙串中的本地开发证书自签名，未进行 Apple Developer ID 公证。macOS 可能拦截从网络下载的应用，请按“系统设置 → 隐私与安全性”中的系统提示手动允许。首次开始监测时，还需允许应用使用摄像头。

从 0.x 进入 1.0 时，请退出旧版后手动安装 CyberKuku。首次开启监测需要重新授权摄像头和校准。

## 日常使用

1. 从菜单栏打开「设置 → 拓展」，在插件商店导入「同学请注意坐姿！」，再在「已安装」中启用。
2. 看向平常使用的屏幕，在舒适坐姿下校准。经常在笔记本和外接屏之间切换时，可分别建立参考。
3. 选择「及时」「均衡」或「宽松」。均衡模式在头部偏离约 3° 并持续 5 秒时开始提醒，连续回正 2 秒后确认恢复。

插件启用后，侧栏的「插件配置」出现专属页面，可直接打开监测窗口或调整双击伙伴的快捷动作。状态栏也提供监测与画中画快捷操作。监测窗口在视频上方显示姿态与校准，并在视频下缘集中操作。形象与应用更新在「设置 → 伙伴」。

头部、肩部和手口习惯独立计时。气泡只提示当前动作；点击气泡或小灰猫可暂静 30 秒。转头、离座或画面识别不可靠时保持安静。画中画只显示摄像头视频，记住位置和大小，双击可回到监测窗口。镜像仅影响预览。

可展开「手口习惯」调整提醒或采集个人动作示范。先录自然放松，再录入动作。应用在本机比较画面中的几何特征，结果用于习惯提醒。

## 从源码构建

需要 Apple Silicon Mac、Xcode Command Line Tools 和 Python 3.11+（已验证 Python 3.12）。

```sh
zsh scripts/setup_pose_backend.sh /absolute/path/to/python3.12
zsh scripts/build_pose_runtime.sh
zsh scripts/create_signing_identity.sh
zsh scripts/build_release.sh
zsh scripts/create_dmg.sh
zsh scripts/install_app.sh
```

输出为 `release/CyberKuku.app` 和可下载的 ZIP。`build_release.sh` 将 Python 运行时冻结到应用内，配置中不保留开发机器的 Python 绝对路径。

开发界面版本可使用 `zsh scripts/build_app.sh --demo`。实际 Release 包通过以下检查：

```sh
swift run --build-system native PostureCoreChecks
release/CyberKuku.app/Contents/MacOS/CyberKuku --bridge-check
```

核心检查无需 XCTest 或完整 Xcode。当前 Swift 6.4 的原生构建参数用于仅有 Command Line Tools 的环境，会提示未来弃用；尚未对其它构建工具版本做保证。

## 隐私与仓库内容

图像只在本机内存和私有进程管道中处理，不保存照片、录像或上传画面。个人参考保存在应用自己的 Application Support，设置保存在 UserDefaults。源码仓库不上传 `.venv-pose`、本机模型缓存、个人校准及实拍验证记录。

## 文档

- [v1.1.0 插件商店与设置侧栏](docs/release-v1.1.0.md)
- [v1.0.0 正式版](docs/release-v1.0.0.md)
- [v0.12.6 提醒气泡布局](docs/release-v0.12.6.md)
- [v0.12.5 桌宠提醒](docs/release-v0.12.5.md)

- [v0.10.2 更新下载进度与一次确认安装](docs/release-v0.10.2.md)
- [v0.10.1 提醒居中与紧凑留白](docs/release-v0.10.1.md)
- [v0.10.0 稳定提醒、恢复圆环、原生菜单与双画面对照](docs/release-v0.10.0.md)
- [v0.9.1 恢复绿灯完整显示修复](docs/release-v0.9.1.md)
- [v0.9.0 紧凑提示、点击收起与单屏灵动岛效果](docs/release-v0.9.0.md)
- [v0.8.0 绿灯恢复、解锁续监测、画中画记忆与空格控制](docs/release-v0.8.0.md)
- [v0.7.0 原生自动检查与更新](docs/release-v0.7.0.md)
- [v0.6.0 独立计时、持续提示与个人口部示范](docs/release-v0.6.0.md)
- [v0.6 口部采样与能力说明](docs/monitor-v0.6.md)
- [v0.5.0 可调提醒、独立视频与口部习惯](docs/release-v0.5.0.md)
- [v0.5 全盘架构审查与能力边界](docs/architecture-review-v0.5.md)

- [v0.4 发布与布局更新](docs/release-v0.4.md)
- [v0.4.1 应用与菜单栏图标](docs/release-v0.4.1.md)
- [v0.4.2 透明应用图标与实心菜单栏图标](docs/release-v0.4.2.md)
- [v0.4.3 判定可用性与具体状态](docs/release-v0.4.3.md)
- [v0.4.4 轻微歪头阈值与恢复范围](docs/release-v0.4.4.md)
- [原生常驻设计 v0.3](docs/monitor-v0.3.md)
- [诊断原型 v0.2](docs/mvp-v0.2.md)
- [初版架构](docs/architecture-v0.1.md)
- [第三方组件与许可](THIRD_PARTY_NOTICES.md)

### 自动检查和更新

从「设置 → 伙伴 → 应用更新」或应用主菜单可检查新版，默认每天自动检查。点击「下载安装更新」后显示下载进度，校验通过即安装并重新启动。发布维护见 [更新说明](docs/updating.md)。
