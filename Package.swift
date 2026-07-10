// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexWindow",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "CodexWindow", targets: ["CodexWindow"])],
    targets: [
        .executableTarget(name: "CodexWindow")
    ]
)
