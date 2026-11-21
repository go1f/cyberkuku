// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CyberKuku",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CyberKuku", targets: ["CyberKuku"]),
        .executable(name: "PostureCoreChecks", targets: ["PostureCoreChecks"])
    ],
    targets: [
        .target(name: "PostureCore"),
        .executableTarget(name: "CyberKukuUpdateInstaller", dependencies: ["PostureCore"]),
        .executableTarget(name: "CyberKuku", dependencies: ["PostureCore"]),
        // Dependency-free native checks also run with Command Line Tools alone.
        .executableTarget(name: "PostureCoreChecks", dependencies: ["PostureCore"], path: "Tests/PostureCoreTests")
    ]
)
