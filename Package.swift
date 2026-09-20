// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "InkletMac",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "InkletMac", targets: ["InkletMac"]),
        .library(name: "InkletPresentationKit", targets: ["InkletPresentationKit"]),
        .library(name: "InkletPresentationWidget", targets: ["InkletPresentationWidget"]),
        .executable(name: "InkletWidgetPreview", targets: ["InkletWidgetPreview"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
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
            dependencies: [
                "InkletPresentationKit",
                "InkletPresentationWidget",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/InkletMac",
            resources: [.process("Resources")],
            linkerSettings: [
                // Sparkle.framework is copied into Contents/Frameworks by
                // Scripts/build-app.sh; this is where the loader looks for it.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
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
