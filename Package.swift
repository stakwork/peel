// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Peel",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "PeelCore", targets: ["PeelCore"]),
        .executable(name: "peel", targets: ["peel"]),
        .executable(name: "PeelApp", targets: ["PeelApp"]),
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
        .executableTarget(name: "peel", dependencies: ["PeelCore"]),
        .executableTarget(name: "PeelApp", dependencies: ["PeelCore"]),
    ]
)
