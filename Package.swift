// swift-tools-version: 6.0
import PackageDescription
import Foundation

let rustLib = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("rust/target/release").path
let nativeLink: [LinkerSetting] = [.linkedFramework("ServiceManagement"), .linkedFramework("Security"), .linkedFramework("AppKit"), .linkedFramework("SystemConfiguration"), .linkedFramework("IOKit"), .unsafeFlags(["-L" + rustLib])]

let package = Package(
    name: "NeSpat",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/orchetect/MenuBarExtraAccess", from: "1.2.2")
    ],
    targets: [
        .systemLibrary(name: "NeSpatNative", path: "rust/bridge"),
        .executableTarget(
            name: "NeSpat",
            dependencies: [
                "NeSpatNative",
                "NeSpatPrivilegeCore",
                .product(name: "MenuBarExtraAccess", package: "MenuBarExtraAccess")
            ],
            path: "Sources/NeSpat", linkerSettings: nativeLink
        ),
        .testTarget(name: "NeSpatTests", dependencies: ["NeSpat"]),
        .target(name: "NeSpatPrivilegeCore", dependencies: ["NeSpatNative"], linkerSettings: nativeLink),
        .executableTarget(name: "NeSpatPrivilegeHelper", dependencies: ["NeSpatPrivilegeCore", "NeSpatNative"], linkerSettings: nativeLink),
        .executableTarget(name: "NeSpatAcceptanceHelper", dependencies: ["NeSpatPrivilegeCore"]),
        .target(name: "NeSpatLiveTestCore", dependencies: ["NeSpatPrivilegeCore"]),
        .executableTarget(name: "NeSpatLiveTestHelper", dependencies: ["NeSpatLiveTestCore"]),
        .executableTarget(name: "NeSpatLiveRecoveryWatchdog", dependencies: ["NeSpatLiveTestCore"]),
        .testTarget(name: "NeSpatLiveTestTests", dependencies: ["NeSpatLiveTestCore"]),
        .testTarget(name: "NeSpatPrivilegeTests", dependencies: ["NeSpatPrivilegeCore"])
    ]
)
