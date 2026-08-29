// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "InkletMac",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "InkletMac",
            path: "Sources/InkletMac",
            resources: [.process("Resources")]
        )
    ]
)
