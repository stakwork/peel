// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Peel",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "PeelCore", targets: ["PeelCore"]),
        .library(name: "AgentKit", targets: ["AgentKit"]),
        .executable(name: "peel", targets: ["peel"]),
        .executable(name: "PeelApp", targets: ["PeelApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server-community/mqtt-nio.git", from: "2.13.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.0.0"),
        // Calls: media for the app only (docs/phases/06-calls.md, "LiveKit on macOS").
        .package(url: "https://github.com/livekit/client-sdk-swift.git", exact: "2.10.2"),
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
        .executableTarget(name: "peel", dependencies: ["PeelCore", "AgentKit"]),
        // The only target that links LiveKit and WebRTC; PeelCore and the CLI never do.
        .executableTarget(
            name: "PeelApp",
            dependencies: ["PeelCore", .product(name: "LiveKit", package: "client-sdk-swift")],
            // scripts/bundle-app.sh puts LiveKit's WebRTC in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "PeelCoreTests",
            dependencies: ["PeelCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "AgentKitTests",
            dependencies: ["AgentKit", .product(name: "GRDB", package: "GRDB.swift")],
            resources: [.copy("Fixtures")]
        ),
        // Journeys through the real core against a local stack
        // (scripts/test-stack.sh); skipped unless PEEL_INTEGRATION=1.
        .testTarget(
            name: "PeelIntegrationTests",
            dependencies: ["PeelCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        // Timings on a synthetic large account; skipped unless PEEL_BENCH=1.
        .testTarget(
            name: "PeelBenchmarks",
            dependencies: ["PeelCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ]
)
