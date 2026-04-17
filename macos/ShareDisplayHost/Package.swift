// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShareDisplayHost",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ShareDisplayHost", targets: ["ShareDisplayHost"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC.git", from: "137.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "ShareDisplayHost",
            dependencies: [
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            path: "Sources/ShareDisplayHost",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreVideo"),
            ]
        ),
    ]
)
