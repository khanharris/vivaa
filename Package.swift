// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Viva",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Viva", path: "Sources/Viva")
    ]
)
