// swift-tools-version: 6.4
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny")
]

let package = Package(
    name: "OpenNexus",
    platforms: [.macOS(.v27)],
    products: [
        .library(
            name: "OpenNexusKit",
            targets: ["NexusCore", "NexusLayout", "NexusFormat", "NexusTheme", "NexusKeys", "NexusAI", "NexusCanvas"]
        ),
        .executable(name: "nexus", targets: ["nexus"]),
    ],
    targets: [
        // Graph model, reversible edits, undo. No AppKit.
        .target(name: "NexusCore", swiftSettings: strict),
        // One pure layout engine per structure.
        .target(name: "NexusLayout", dependencies: ["NexusCore"], swiftSettings: strict),
        // .nexus package read/write, canonical JSON, schema validation.
        .target(
            name: "NexusFormat",
            dependencies: ["NexusCore"],
            resources: [.copy("Resources/nexus.schema.json")],
            swiftSettings: strict
        ),
        // Tokens, themes, node styles, contrast checks.
        .target(name: "NexusTheme", dependencies: ["NexusCore"], swiftSettings: strict),
        // Command registry, key chords, profiles, conflict detection.
        .target(name: "NexusKeys", swiftSettings: strict),
        // Thin wrappers around Apple's on-device frameworks (Foundation Models, Translation,
        // NaturalLanguage, Vision, Image Playground, SpeechAnalyzer). No network.
        .target(name: "NexusAI", dependencies: ["NexusCore"], swiftSettings: strict),
        // AppKit canvas: rendering, hit testing, editing overlay, animation.
        .target(
            name: "NexusCanvas",
            dependencies: ["NexusCore", "NexusLayout", "NexusTheme", "NexusKeys", "NexusAI"],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "nexus",
            dependencies: ["NexusCore", "NexusFormat"],
            swiftSettings: strict
        ),

        .testTarget(name: "NexusCoreTests", dependencies: ["NexusCore"]),
        .testTarget(name: "NexusLayoutTests", dependencies: ["NexusLayout"]),
        .testTarget(
            name: "NexusFormatTests",
            dependencies: ["NexusFormat"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "NexusThemeTests", dependencies: ["NexusTheme", "NexusCore"]),
        .testTarget(name: "NexusKeysTests", dependencies: ["NexusKeys"]),
        .testTarget(name: "NexusCanvasTests", dependencies: ["NexusCanvas", "NexusFormat"]),
        .testTarget(name: "NexusAITests", dependencies: ["NexusAI", "NexusCore"]),
    ]
)
