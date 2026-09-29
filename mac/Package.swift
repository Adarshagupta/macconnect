// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacConnectAgent",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MacConnectAgent",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreImage"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
