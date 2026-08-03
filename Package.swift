// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "hexad",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "hexad", path: "Sources/hexad")
    ]
)
