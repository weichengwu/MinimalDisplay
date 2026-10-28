# UUyc-companion 源码提炼

阅读对象：[aoyamashou/UUyc-companion](https://github.com/aoyamashou/UUyc-companion)，固定提交 `f5e45dc6d8c5f5fcae2011774d5c735d25ab8fa1`。MinimalDisplay 是独立实现的手动工具，参考范围如下。

## 原项目核心功能

| 功能 | 实现位置 | 本次处理 |
| --- | --- | --- |
| UU 远程连接检测 | `UUMonitor.swift`、`UUConnectionState.swift` | 完全去掉 |
| 通过辅助功能读取设备、控制端名称 | `UUReader.swift` | 完全去掉，因此不需要其辅助功能授权 |
| 按设备分辨率自动创建 HiDPI 虚拟屏 | `Coordinator.swift`、`DisplayManager.swift` | 改成用户维护独立配置、手动选择 |
| 关闭所有非虚拟屏 | `PhysicalDisplays.swift` | 手动切换时关闭原有内置屏和外接屏，仅保留选中虚拟屏 |
| 断开连接恢复原屏和排列 | `DisplayManager.swift` | 改成菜单、快捷键、退出时手动恢复；不监听远程状态 |
| 恢复看门狗、主线程心跳 | `Watchdog.swift` | 保留恢复机制的思路，独立子进程按需运行，不安装 LaunchAgent |
| 导览、权限向导、作者关于页 | `SetupWizard.swift` 等及 Vendor、AboutKit | 去掉；AboutKit 是原项目私有依赖，本工具不依赖它 |

## 两组关键私有 API

1. **`CGVirtualDisplayDescriptor` / `CGVirtualDisplayMode` / `CGVirtualDisplaySettings` / `CGVirtualDisplay`**：描述名称、像素上限、屏幕尺寸、标识和模式，构造对象并调用 `applySettings:`。保留对象即保留虚拟屏，释放对象即移除虚拟屏。HiDPI 模式使用宽高各减半的逻辑尺寸，对应完整像素。
2. **`CGSConfigureDisplayEnabled`**：在 `CGBeginDisplayConfiguration` / `CGCompleteDisplayConfiguration` 事务中设置启停。通过 `dlsym` 动态查找。原项目记录：`.forAppOnly` 不能可靠保证退出后自动恢复；禁用屏可能不再出现在在线列表中，所以必须先保存身份和恢复记录。

公共 API 负责在线/活动检查、读取当前模式、设置排列和完成事务；ColorSync 的公共 UUID API 用于验证恢复目标，避免只凭可能复用的数字 ID 操作错误屏幕。

本工具通过 Objective-C 桥接动态查找私有类和关键方法，避免静态依赖未公开类符号；缺失时报告不可用。创建、实际模式核对、主屏、关闭内置屏按顺序执行。私有 API 在未来 macOS 上仍可能改变，没有 SDK 兼容性承诺。

## 直接影响实现的发现

- 原项目源码记录了创建/移除过快可能导致 WindowServer 崩溃或显示配置卡死，因此本工具保留串行事务、稳定等待、最短对象寿命和超时保护。
- 手动切换时关闭所有原物理屏，原屏幕列表整体用于禁用和恢复，不仅筛选内置屏。
- 原项目的辅助功能权限与 UU 界面读取相关；虚拟屏和显示排列本身没有相同的辅助功能授权路径，不应照搬权限申请。
- 只检测符号不能证明虚拟屏可创建，必须检查创建返回值、`applySettings`、上线状态和实际帧缓冲模式。已实现这些检查，真实画面由用户手测。
- 原项目可选看门狗通过 LaunchAgent 安装；本工具要求恢复进程先就绪才能禁用内置屏，且不修改系统登录/后台设置。

## 主要来源

- [原项目说明与技术实现](https://github.com/aoyamashou/UUyc-companion/tree/f5e45dc6d8c5f5fcae2011774d5c735d25ab8fa1)
- [原项目虚拟屏管理](https://github.com/aoyamashou/UUyc-companion/blob/f5e45dc6d8c5f5fcae2011774d5c735d25ab8fa1/Sources/UUDisplay/DisplayManager.swift)
- [原项目物理屏控制与风险注释](https://github.com/aoyamashou/UUyc-companion/blob/f5e45dc6d8c5f5fcae2011774d5c735d25ab8fa1/Sources/UUDisplay/PhysicalDisplays.swift)
- [原项目桥接声明（MIT）](https://github.com/aoyamashou/UUyc-companion/blob/f5e45dc6d8c5f5fcae2011774d5c735d25ab8fa1/Sources/CGVirtualDisplayBridge/include/CGVirtualDisplay.h)
- [Chromium 的同类私有接口声明与创建流程](https://source.chromium.org/chromium/chromium/src/+/main:ui/display/mac/test/virtual_display_util_mac.mm)，用于交叉核对字段类型、队列、色度和 HiDPI 参数。没有复制 Chromium 实现。

改编的接口声明保留上游 MIT 许可证，随源码和 App 一并提供 `THIRD_PARTY_LICENSES.txt`。

上游桥接头文件还标注了 [FreeDisplay](https://github.com/huberdf/FreeDisplay) 作为接口声明来源；此处保留该来源链。MinimalDisplay 未引入其应用实现。
