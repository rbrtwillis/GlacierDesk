// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GlacierDesk",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GlacierDesk", targets: ["GlacierDesk"])],
    targets: [.executableTarget(name: "GlacierDesk")]
)
