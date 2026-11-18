// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NeSpat",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/orchetect/MenuBarExtraAccess", from: "1.2.2")
    ],
    targets: [
        .executableTarget(
            name: "NeSpat",
            dependencies: [
                "NeSpatPrivilegeCore",
                .product(name: "MenuBarExtraAccess", package: "MenuBarExtraAccess")
            ],
            path: "Sources/NeSpat"
        ),
        .testTarget(name: "NeSpatTests", dependencies: ["NeSpat"]),
        .target(name: "NeSpatPrivilegeCore"),
        .executableTarget(name: "NeSpatPrivilegeHelper", dependencies: ["NeSpatPrivilegeCore"]),
        .executableTarget(name: "NeSpatAcceptanceHelper", dependencies: ["NeSpatPrivilegeCore"]),
        .target(name: "NeSpatLiveTestCore", dependencies: ["NeSpatPrivilegeCore"]),
        .executableTarget(name: "NeSpatLiveTestHelper", dependencies: ["NeSpatLiveTestCore"]),
        .executableTarget(name: "NeSpatLiveRecoveryWatchdog", dependencies: ["NeSpatLiveTestCore"]),
        .testTarget(name: "NeSpatLiveTestTests", dependencies: ["NeSpatLiveTestCore"]),
        .testTarget(name: "NeSpatPrivilegeTests", dependencies: ["NeSpatPrivilegeCore"])
    ]
)
