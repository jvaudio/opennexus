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
                "NexusCanvas",
            ]
        ),
        // For the light extensions (Share, Spotlight, Widgets): the model and file format only.
        .library(name: "NexusShared", targets: ["NexusCore", "NexusFormat"]),
        .library(name: "NexusWidgetsKit", targets: ["NexusWidgetsUI"]),
        // The CLI's code, for the app's embedded `nexus` tool target.
        .library(name: "NexusAgentKit", targets: ["NexusAgent"]),
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
            dependencies: ["NexusCore", "NexusLayout", "NexusTheme", "NexusKeys", "NexusAI", "NexusFormat", "NexusInterchange"],
            // Starters/ is copied as a folder: one JSON file per built-in starter (M39).
            resources: [.process("Resources"), .copy("Starters")],
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
        .testTarget(name: "NexusCanvasTests", dependencies: ["NexusCanvas", "NexusFormat", "NexusWidgetsUI"]),
        .testTarget(name: "NexusAITests", dependencies: ["NexusAI", "NexusCore"]),
        .testTarget(name: "NexusAgentTests", dependencies: ["NexusAgent", "NexusCanvas", "NexusFormat", "NexusCore"]),
        .testTarget(
            name: "NexusInterchangeTests",
            dependencies: ["NexusInterchange", "NexusFormat", "NexusCore", "NexusTheme"],
            exclude: ["Fixtures", "Goldens"]
        ),
    ]
)
