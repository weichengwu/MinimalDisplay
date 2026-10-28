// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MinimalDisplay",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MinimalDisplay", targets: ["MinimalDisplay"])],
    targets: [
        .target(name: "DisplayBridge", cSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("CoreGraphics")]),
        .target(name: "DisplayCore", dependencies: ["DisplayBridge"]),
        .executableTarget(name: "MinimalDisplay", dependencies: ["DisplayCore"],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Carbon")]),
        .testTarget(name: "DisplayCoreTests", dependencies: ["DisplayCore"]),
    ]
)
