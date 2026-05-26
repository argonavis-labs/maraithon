// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Maraithon",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Maraithon", targets: ["Maraithon"])
    ],
    dependencies: [
        // Async timers built on Clock APIs — replaces ad-hoc Task.sleep loops
        // in the iMessage poller. See AGENTS.md "Background work".
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0")
        // Sparkle is added only to the Xcode project (project.yml). It needs
        // to embed a framework into the bundled .app, which the SwiftPM
        // executable target doesn't produce. Keeping it out of Package.swift
        // means `swift build` stays clean and fast.
    ],
    targets: [
        .executableTarget(
            name: "Maraithon",
            dependencies: [
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms")
            ],
            path: "Sources/Maraithon",
            exclude: [
                // These belong to the Xcode app target only; SwiftPM forbids
                // Info.plist as a bundle resource and ignores entitlements /
                // privacy manifests anyway.
                "Resources/Info.plist",
                "Resources/Maraithon.entitlements",
                "Resources/PrivacyInfo.xcprivacy"
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "MaraithonTests",
            dependencies: ["Maraithon"],
            path: "Tests/MaraithonTests",
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
