// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexResetsWindow",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "CodexResetsWindow", targets: ["CodexResetsWindow"])],
    targets: [
        .executableTarget(name: "CodexResetsWindow")
    ]
)
