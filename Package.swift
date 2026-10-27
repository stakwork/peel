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
        .library(name: "PeelDiagnostics", targets: ["PeelDiagnostics"]),
        .library(name: "PeelPush", targets: ["PeelPush"]),
        .library(name: "PeelPushCrypto", targets: ["PeelPushCrypto"]),
        .executable(name: "peel", targets: ["peel"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-server-community/mqtt-nio.git", from: "2.13.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.0.0"),
        // On-device crash reports (PeelDiagnostics); no upload, see docs/diagnostics.md.
        .package(url: "https://github.com/microsoft/plcrashreporter.git", exact: "1.12.2"),
    ],
    targets: [
        // On-device crash and memory diagnostics: the crash reporter, the event
        // ring, the redactor. No UI; the pure logic builds and tests anywhere,
        // the crash reporter only for macOS and iOS (docs/diagnostics.md).
        .target(
            name: "PeelDiagnostics",
            dependencies: [
                .product(name: "CrashReporter", package: "plcrashreporter", condition: .when(platforms: [.macOS, .iOS])),
            ]
        ),
        // Remote push without the core: the token, the shared push key, the
        // ids from Info.plist, the flag, and what a push says. Pure logic that
        // the app and the notification extension share; builds anywhere.
        .target(name: "PeelPush"),
        // The core's decryptChildIndex for the notification extension, which
        // links this and PeelPush alone (not PeelCore).
        .target(name: "PeelPushCrypto", dependencies: ["PeelPush", "Sphinxrs"]),
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
                "PeelDiagnostics",
                "PeelPush",
                .product(name: "MQTTNIO", package: "mqtt-nio"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
            ]
        ),
        // The agent's client side: its records and event log, the approval
        // gate and its rules, the connected model's key and the chat Peel's
        // own loop kept before strut was the agent (docs/agent-architecture.md);
        // GRDB only, so it builds for macOS and iOS without the core.
        .target(name: "AgentKit", dependencies: [.product(name: "GRDB", package: "GRDB.swift"), "PeelDiagnostics"]),
        // The device side of the agent in strut: the Sphinx tools over the
        // engine's storage, the device requests, strut and the bridge Peel
        // ships; no AppKit or UIKit.
        .target(name: "PeelAgent", dependencies: ["AgentKit", "PeelCore", "PeelDiagnostics"]),
        .executableTarget(name: "peel", dependencies: ["PeelCore", "PeelAgent"]),
        // The app's model, shared by the Mac and the iPhone: `AppModel` and
        // what it holds, with the platform's services behind protocols
        // (`Platform`). No AppKit, UIKit, LiveKit or PeelAgent. The apps
        // themselves are in Apps/, in Apps/Peel.xcodeproj; the Mac app is
        // the only one that links LiveKit and WebRTC (its package reference
        // is the project's, not this package's).
        .target(name: "PeelUI", dependencies: ["PeelCore", "AgentKit", "PeelDiagnostics"]),
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
            dependencies: ["PeelCore", "PeelPush", "PeelTestSupport", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        // The app's model, on a real engine and profile; no window, no server.
        .testTarget(name: "PeelUITests", dependencies: ["PeelUI", "PeelCore", "AgentKit", "PeelTestSupport"]),
        // Pure logic: runs on Linux too (`swift test --filter PeelPushTests`).
        .testTarget(name: "PeelPushTests", dependencies: ["PeelPush"]),
        // Pure logic: runs on Linux too (`swift test --filter PeelDiagnosticsTests`).
        .testTarget(name: "PeelDiagnosticsTests", dependencies: ["PeelDiagnostics"]),
        // PeelAgent is Mac-only, and so are its tests.
        .testTarget(
            name: "PeelAgentTests",
            dependencies: ["PeelAgent", "AgentKit", "PeelCore", "PeelTestSupport"]
        ),
        .testTarget(name: "AgentKitTests", dependencies: ["AgentKit", .product(name: "GRDB", package: "GRDB.swift")]),
        // Journeys through the real core against a local stack
        // (scripts/test-stack.sh); skipped unless PEEL_INTEGRATION=1. The
        // agent's journeys drive PeelAgent, strut and the bridge with a stand-in model.
        .testTarget(
            name: "PeelIntegrationTests",
            dependencies: ["PeelCore", "AgentKit", "PeelAgent", "PeelTestSupport", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        // Timings on a synthetic large account; skipped unless PEEL_BENCH=1.
        .testTarget(
            name: "PeelBenchmarks",
            dependencies: ["PeelCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
    ]
)
