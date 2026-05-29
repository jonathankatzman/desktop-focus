// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DesktopFocus",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DesktopFocus",
            path: "Sources/DesktopFocus"
        ),
        .testTarget(
            name: "DesktopFocusTests",
            dependencies: ["DesktopFocus"]
        )
    ]
)
