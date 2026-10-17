// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Peel",
    platforms: [.macOS(.v15), .iOS("26.0")],
    products: [
        .library(name: "PeelCore", targets: ["PeelCore"]),
        .library(name: "AgentKit", targets: ["AgentKit"]),
        .library(name: "PeelUI", targets: ["PeelUI"]),
        .library(name: "PeelAgent", targets: ["PeelAgent"]),
        .executable(name: "peel", targets: ["peel"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server-community/mqtt-nio.git", from: "2.13.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.0.0"),
    ],
    targets: [
        // Rust core, built by scripts/build-ffi.sh.
        .binaryTarget(name: "sphinxrsFFI", path: "Vendor/sphinxrsFFI.xcframework"),
        // Generated bindings; not written for Swift 6 concurrency checking.
        .target(
            name: "Sphinxrs",
            dependencies: ["sphinxrsFFI"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "PeelCore",
            dependencies: [
                "Sphinxrs",
                .product(name: "MQTTNIO", package: "mqtt-nio"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            ]
        ),
        // The agent: its records and event log, the model clients and the turn loop
        // (docs/agent-architecture.md, docs/phases/09-agents.md);
        // GRDB only, so it builds for macOS and iOS without the core.
        .target(name: "AgentKit", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        // The Sphinx tools over the engine's storage; no AppKit or UIKit.
        .target(
            name: "PeelAgent",
            dependencies: [
                "AgentKit", "PeelCore",
                // The loopback server strut calls when an automation fires.
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        .executableTarget(name: "peel", dependencies: ["PeelCore", "AgentKit", "PeelAgent"]),
        // The app's model, shared by the Mac and the iPhone: `AppModel` and
        // what it holds, with the platform's services behind protocols
        // (`Platform`). No AppKit, UIKit, LiveKit or PeelAgent. The apps
        // themselves are in Apps/, in Apps/Peel.xcodeproj; the Mac app is
        // the only one that links LiveKit and WebRTC (its package reference
        // is the project's, not this package's).
        .target(name: "PeelUI", dependencies: ["PeelCore", "AgentKit"]),
        // The storage and engine fixtures the test targets below share; a
        // test target cannot depend on another, so they live in a library.
        .target(
            name: "PeelTestSupport",
            dependencies: ["PeelCore", .product(name: "GRDB", package: "GRDB.swift")],
            path: "Tests/PeelTestSupport"
        ),
        // No PeelAgent here, so these also run on iOS.
        .testTarget(
            name: "PeelCoreTests",
            dependencies: ["PeelCore", "PeelTestSupport", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        // The app's model, on a real engine and profile; no window, no server.
        .testTarget(name: "PeelUITests", dependencies: ["PeelUI", "PeelCore", "AgentKit", "PeelTestSupport"]),
        // PeelAgent is Mac-only, and so are its tests (and `peel agent`'s).
        .testTarget(
            name: "PeelAgentTests",
            dependencies: ["PeelAgent", "AgentKit", "PeelCore", "PeelTestSupport", "peel"]
        ),
        .testTarget(
            name: "AgentKitTests",
            dependencies: ["AgentKit", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Fixtures")]
        ),
        // Journeys through the real core against a local stack
        // (scripts/test-stack.sh); skipped unless PEEL_INTEGRATION=1. The
        // agent's journeys drive AgentKit and PeelAgent with a scripted model.
        .testTarget(
            name: "PeelIntegrationTests",
            dependencies: ["PeelCore", "AgentKit", "PeelAgent", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        // Timings on a synthetic large account; skipped unless PEEL_BENCH=1.
        .testTarget(
            name: "PeelBenchmarks",
            dependencies: ["PeelCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ]
)
