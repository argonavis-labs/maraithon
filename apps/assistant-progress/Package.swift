// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AssistantProgressKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "AssistantProgressKit", targets: ["AssistantProgressKit"])],
    targets: [.target(name: "AssistantProgressKit")]
)
