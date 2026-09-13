// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "InkletMac",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "InkletMac", targets: ["InkletMac"]),
        .library(name: "InkletPresentationKit", targets: ["InkletPresentationKit"]),
        .library(name: "InkletPresentationWidget", targets: ["InkletPresentationWidget"]),
        .executable(name: "InkletWidgetPreview", targets: ["InkletWidgetPreview"]),
    ],
    targets: [
        .target(
            name: "InkletPresentationKit",
            path: "Sources/InkletPresentationKit"
        ),
        .target(
            name: "InkletPresentationWidget",
            dependencies: ["InkletPresentationKit"],
            path: "Sources/InkletPresentationWidget",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "InkletMac",
            dependencies: ["InkletPresentationKit", "InkletPresentationWidget"],
            path: "Sources/InkletMac",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "InkletPresentationKitTests",
            dependencies: ["InkletPresentationKit"],
            path: "Tests/InkletPresentationKitTests"
        ),
        .testTarget(
            name: "InkletMacTests",
            dependencies: ["InkletMac", "InkletPresentationKit"],
            path: "Tests/InkletMacTests"
        ),
        .executableTarget(
            name: "InkletWidgetPreview",
            dependencies: ["InkletPresentationKit", "InkletPresentationWidget"],
            path: "PreviewSupport"
        ),
    ]
)
