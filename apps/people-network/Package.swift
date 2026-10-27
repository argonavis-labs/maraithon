// swift-tools-version: 5.9
// Shared native People presentation. No source ingestion or ranking runs here.
import PackageDescription

let package = Package(
    name: "PeopleNetworkKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "PeopleNetworkKit", targets: ["PeopleNetworkKit"])],
    targets: [.target(name: "PeopleNetworkKit")]
)
