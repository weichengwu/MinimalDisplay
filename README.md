# MinimalDisplay 屏幕切换

一个极简的 macOS 原生菜单栏 App：手动切换虚拟屏，需要时再恢复物理屏。

## 为什么做这个项目

我经常通过远程桌面连接 Mac。自动切换虚拟屏原本很方便，但在我的使用场景里，临时退出远程连接、过一会儿再连回来，也会重新经历一次屏幕恢复和切换。每次都要等显示器重新就绪，反而打断了操作。

我想要的是：**切换一次，就一直用；什么时候恢复，由我决定。**

于是有了 MinimalDisplay。它借鉴了 [UUyc-companion](https://github.com/aoyamashou/UUyc-companion) 的虚拟显示器与物理屏控制思路，去掉了 UU 连接检测、设备识别和自动切换，保留手动管理、切换与恢复。远程连接断开或重新连入时，App 不会因此改变显示状态。

## 能做什么

- 原生菜单栏操作，手动维护虚拟屏名称和分辨率。
- 一次启用一块虚拟屏，并停用原有内置屏及外接屏。
- 每条配置独立选择「高清」（HiDPI），输入分辨率无需自己乘以 2。
- 切换后持续使用，没有确认倒计时；编辑配置后，手动切换才会应用。
- 通过菜单或 **Control + Option + Command + 9** 恢复物理屏。
- 退出时尝试恢复，最多等待 8 秒；独立恢复进程处理异常退出后的恢复。

没有 UU 集成，没有联网、遥测或第三方包依赖。

## 下载与使用

从 [Releases](https://github.com/weichengwu/MinimalDisplay/releases) 下载与你的 Mac 架构对应的 ZIP，解压后将 `MinimalDisplay.app` 放到「应用程序」或其他固定位置。更新前先退出旧版本。

当前提供 Apple Silicon（arm64）预览包，最低部署目标为 macOS 14。包采用 ad-hoc 签名，**没有 Developer ID 签名或 Apple 公证**；下载后可能需要按 macOS 提示在「系统设置 → 隐私与安全性」允许打开。Intel 和其他系统版本尚未实测。

1. 打开 App，点击菜单栏双屏图标，选择「管理虚拟屏」。
2. 添加名称、宽度和高度，按需要选择「高清」。
3. 远程客户端已连接时，手动选择配置或点击「切换」。切换会停用全部原有物理屏，请在远程客户端选择新虚拟屏。
4. 临时断开再连接，继续使用当前虚拟屏；需要结束时，点击「恢复物理屏」或按恢复快捷键。

退出 App 会尝试恢复原显示器及排列。恢复失败也不会阻止退出；再次点击退出可直接结束主程序，由恢复进程继续收尾。重新打开 App 不会自动启用虚拟屏，配置列表会保留。

> 当前使用 macOS 私有显示 API，尚未完成跨设备、跨系统和全部真实屏幕恢复场景的验收。编译与非 UI 测试通过不代表硬件兼容性已验证，详见 [验证记录](docs/verification.md) 和 [手动验收清单](TODO.md)。

## 分辨率和 HiDPI 怎么选

填写的是你希望桌面呈现的**界面分辨率**。「高清」只决定是否按宽高各 2 倍的像素渲染，不会修改输入值：

| 配置 | 高清 | 实际渲染像素 |
| --- | --- | --- |
| 1920 × 1080 | 关 | 1920 × 1080 |
| 1920 × 1080 | 开 | 3840 × 2160 |

高清通常让文字更细腻，也会增加渲染和远程传输负担。最终清晰度还取决于远程客户端的采集分辨率、编码和缩放。想让界面元素更大，可降低输入的界面分辨率；想容纳更多内容，可提高它。

支持横屏、竖屏和奇数界面尺寸。普通模式宽高范围为 320–8192，高清模式为 160–4096，实际宽高均不超过 8192 像素；刷新率固定为 60 Hz。

## 权限、数据与恢复

手动显示控制不请求辅助功能、屏幕录制或管理员权限。远程桌面软件自身需要的权限由该软件管理。

配置、恢复记录和有大小限制的日志仅保存在 `~/Library/Application Support/MinimalDisplay/`，不会上传。使用虚拟屏时，请保留该目录和正在运行的 App。

App 在改变显示布局前保存恢复记录，确认虚拟屏上线、分辨率正确且恢复进程就绪后，才停用物理屏。恢复进程作为子进程按需启动，不安装 LaunchAgent、不添加登录项。它负责主程序异常结束后的恢复；WindowServer 卡死、私有 API 失效或硬件异常时仍可能需要注销或重启。

「关闭物理屏」指停用系统显示拓扑中的原显示器，面板背光和实际耗电行为取决于硬件及 macOS。切换后新插入的显示器不自动管理，需要先恢复再手动切换。

## 从源码构建

需要 macOS 14+、Xcode 或可提供 macOS SDK 的 Swift 5.9+ 工具链。

```sh
git clone https://github.com/weichengwu/MinimalDisplay.git
cd MinimalDisplay
zsh scripts/build-app.sh
```

脚本生成 `build/1.0.8/MinimalDisplay.app`、对应架构的 `build/MinimalDisplay-1.0.8-<arch>.zip` 及 SHA-256 文件。它只构建、签名和打包，不会启动 App 或修改显示设置。默认使用 ad-hoc 签名，可通过环境变量 `SIGN_IDENTITY` 指定已有签名身份；公证需另行处理。

本地校验下载包（在 ZIP 所在目录执行）：

```sh
shasum -a 256 -c MinimalDisplay-1.0.8-arm64.zip.sha256
```

开发与非 UI 验证方法见 [CONTRIBUTING.md](CONTRIBUTING.md)，显示控制与恢复细节见 [技术说明](docs/architecture.md)。

## 致谢与许可

感谢 [AoyamaShou / UUyc-companion](https://github.com/aoyamashou/UUyc-companion) 提供的开源实现。本项目参考了其虚拟屏创建、物理屏停用及恢复保护的设计，并改编了私有接口声明。[源码提炼](docs/upstream-analysis.md) 记录了参考范围和固定提交。

本项目以 [MIT License](LICENSE) 开源。上游版权声明及 MIT 许可保留在 [THIRD_PARTY_LICENSES.txt](THIRD_PARTY_LICENSES.txt)，并随 App 一起分发。
