# 参与开发

欢迎提交问题和范围明确的改进。项目保持原生、纯手动的菜单栏工具定位，不监听远程客户端连接，不在重连时自动切屏。

## 目录

- `Sources/MinimalDisplay`：AppKit 菜单栏、SwiftUI 管理窗口、应用生命周期。
- `Sources/DisplayCore`：配置、显示事务、恢复记录和恢复进程。
- `Sources/DisplayBridge`：Objective-C 私有显示接口桥接。
- `Tests/DisplayCoreTests`：模拟显示驱动、临时文件和进程互斥测试。
- `scripts`：构建打包与静态图标生成。

## 验证范围

修改前先查看 [验证记录](docs/verification.md) 和 [TODO](TODO.md)。按修改范围选择相关测试，不用真实屏幕切换代替可隔离的逻辑测试。例如修改配置或 HiDPI 换算时：

```sh
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security --filter 'ProfileAndGuardTests/(testHiDPIRendersDoublePixelsAndTogglePreservesInterfaceSize|testValidationRejectsUnsafeSizeButAllowsOddLogicalHiDPIAndPortrait|testProfilesRoundTripAndInvalidSavePreservesExistingFile)'
```

编译与打包：

```sh
zsh scripts/build-app.sh
```

恢复进程集成验证使用全新临时目录、真实测试子进程，不创建或切换真实显示器，也不修改用户配置：

```sh
build/1.0.8/MinimalDisplay.app/Contents/MacOS/MinimalDisplay --verify-recovery-runtime
```

真实关屏、恢复、远程断开重连和 UI 操作应单独手测，记录 macOS 版本、芯片、显示器和远程客户端。请明确区分构建通过、模拟测试通过和真实设备通过。

## 提交问题与修改

问题报告请附复现步骤、预期与实际结果，以及系统和硬件信息。日志位于 `~/Library/Application Support/MinimalDisplay/events.log`；提交前请删除个人路径、显示器标识和其他敏感信息，不要上传整个配置或恢复目录。

显示器停用和恢复涉及私有 API。修改这部分时，应说明事务顺序、恢复失败后的行为，以及相应的非 UI 验证。不要在 CI 中执行真实关屏或 GUI 验收。

提交代码时请遵循项目现有风格，保留上游署名，并更新直接受影响的文档。提交贡献即表示你有权将该贡献按项目 MIT 许可证提供。
