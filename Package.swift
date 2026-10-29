// swift-tools-version: 6.4
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny")
]

let package = Package(
    name: "OpenNexus",
    defaultLocalization: "en",
    platforms: [.macOS(.v27)],
    products: [
        .library(
            name: "OpenNexusKit",
            targets: ["NexusCore", "NexusLayout", "NexusFormat", "NexusTheme", "NexusKeys", "NexusAI", "NexusInterchange",
                "NexusSync", "NexusReplica", "NexusCanvas",
            ]
        ),
        // For the light extensions (Share, Spotlight, Widgets): the model and file format only.
        .library(name: "NexusShared", targets: ["NexusCore", "NexusFormat"]),
        .library(name: "NexusWidgetsKit", targets: ["NexusWidgetsUI"]),
        // The CLI's code, for the app's embedded `nexus` tool target.
        .library(name: "NexusAgentKit", targets: ["NexusAgent"]),
        // For OpenNexusNet.xpc only (M44): the one process that may use the network.
        .library(name: "NexusNetKit", targets: ["NexusNet"]),
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
            resources: [.copy("Resources/nexus.schema.json"), .copy("Resources/viewer.schema.json")],
            swiftSettings: strict
        ),
        // HTTP with an allow-list and a request log, AWS SigV4, and the share destinations
        // (M44). Linked only into OpenNexusNet.xpc: the app and its extensions never link it.
        .target(name: "NexusNet", dependencies: ["NexusCore", "NexusFormat"], swiftSettings: strict),
        // Bring-your-own sync (M45): a library folder and an S3-compatible bucket, encrypted by
        // default, merged topic by topic. Platform-neutral: the bucket is reached through a
        // transport (the network service in the app, memory in tests).
        .target(name: "NexusSync", dependencies: ["NexusCore", "NexusFormat"], swiftSettings: strict),
        // Real-time co-editing (M46): the CRDT over `Patch` (registers, Kleppmann tree moves,
        // ordered places), the invite link and the room client. Platform-neutral: the relay is
        // reached through a transport (the network service in the app, memory in tests).
        .target(name: "NexusReplica", dependencies: ["NexusCore", "NexusFormat"], swiftSettings: strict),
        // Tokens, themes, node styles, contrast checks.
        .target(name: "NexusTheme", dependencies: ["NexusCore"], swiftSettings: strict),
        // Command registry, key chords, profiles, conflict detection.
        .target(name: "NexusKeys", swiftSettings: strict),
        // Import and export of other formats (.xmind, OPML, Markdown, Mermaid, PlantUML,
        // draw.io, FreeMind, MindManager, Word, CSV, JSON/YAML). Pure and headless.
        // Uses the themes to write and read Xmind styles (M18).
        .target(
            name: "NexusInterchange", dependencies: ["NexusCore", "NexusFormat", "NexusTheme"], swiftSettings: strict),
        // Thin wrappers around Apple's on-device frameworks (Foundation Models, Translation,
        // NaturalLanguage, Vision, Image Playground, SpeechAnalyzer). No network.
        .target(name: "NexusAI", dependencies: ["NexusCore"], swiftSettings: strict),
        // AppKit canvas: rendering, hit testing, editing overlay, animation.
        .target(
            name: "NexusCanvas",
            dependencies: [
                "NexusCore", "NexusLayout", "NexusTheme", "NexusKeys", "NexusAI", "NexusFormat", "NexusInterchange",
                "NexusSync", "NexusReplica",
            ],
            // Starters/ and Guides/ are copied as folders: one JSON file per built-in starter
            // (M39) and guide (M41).
            // Viewer/ holds the built interactive viewer (web/viewer-core, M43).
            resources: [.process("Resources"), .copy("Starters"), .copy("Guides"), .copy("Viewer")],
            swiftSettings: strict
        ),
        // The `nexus` CLI and MCP server (M9): commands, map tools, permissions. Uses the
        // canvas offscreen for exports so they match the app exactly.
        .target(
            name: "NexusAgent",
            dependencies: ["NexusCore", "NexusFormat", "NexusInterchange", "NexusCanvas"],
            swiftSettings: strict
        ),
        // The widgets' SwiftUI content (the extension adds WidgetKit's container).
        .target(name: "NexusWidgetsUI", dependencies: ["NexusFormat"], swiftSettings: strict),
        .executableTarget(
            name: "nexus",
            dependencies: ["NexusAgent"],
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
        // The share tests run the network service in process, against stubs and Docker (M44).
        .testTarget(
            name: "NexusCanvasTests",
            dependencies: ["NexusCanvas", "NexusFormat", "NexusWidgetsUI", "NexusNet", "NexusSync", "NexusReplica"]),
        .testTarget(
            name: "NexusNetTests", dependencies: ["NexusNet", "NexusFormat", "NexusCore"], resources: [.copy("Fixtures")]),
        // The live run (MinIO in Docker) goes through the real network service (M45).
        .testTarget(name: "NexusSyncTests", dependencies: ["NexusSync", "NexusFormat", "NexusCore", "NexusNet"]),
        .testTarget(name: "NexusReplicaTests", dependencies: ["NexusReplica", "NexusFormat", "NexusCore"]),
        .testTarget(name: "NexusAITests", dependencies: ["NexusAI", "NexusCore"]),
        .testTarget(name: "NexusAgentTests", dependencies: ["NexusAgent", "NexusCanvas", "NexusFormat", "NexusCore"]),
        .testTarget(
            name: "NexusInterchangeTests",
            dependencies: ["NexusInterchange", "NexusFormat", "NexusCore", "NexusTheme"],
            exclude: ["Fixtures", "Goldens"]
        ),
    ]
)
