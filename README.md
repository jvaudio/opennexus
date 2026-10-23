# OpenNexus

An open-source, native **macOS 27** app for mind maps and technical diagrams:
Xmind's keyboard flow, plus flowcharts, data flow diagrams, threat models, architecture
and sequence diagrams, and on-device AI. Apple silicon only.

The full product brief, design artboards, tokens and build plan are in [`Handoff/`](Handoff/README.md).
Milestone plans and results live in [`docs/plans/`](docs/plans), and design decisions in
[`docs/DECISIONS.md`](docs/DECISIONS.md).

## Layout

```
Package.swift          Swift package: all app logic, testable without the UI
Sources/
  NexusCore            graph model, reversible edits (patches), undo, tree operations, tasks
  NexusLayout          pure layout engines and branch-line geometry
  NexusFormat          .nexus package read/write, canonical JSON, schema validation
  NexusTheme           tokens, themes, node styles, contrast checks
  NexusKeys            command registry, key chords, profiles, conflict detection
  NexusInterchange     import and export: Xmind (Zen and XMind 8), OPML, Markdown, Office,
                       MindManager, Mermaid, PlantUML, draw.io, images and PDF to map
  NexusAI              on-device AI (Apple Intelligence), never the network
  NexusAgent           the nexus CLI and MCP server's tools
  NexusCanvas          AppKit canvas and SwiftUI chrome (rendering, editing, animation)
  NexusWidgetsUI       widgets
  nexus                command-line tool
App/                   Xcode project for the macOS app and its extensions (thin shell)
  tools/               make_project.py, release.sh, axaudit.swift
schema/                published JSON Schema for .nexus files
Handoff/               design handoff package (brief, artboards, screenshots, specs)
```

## Build and test

Requires Xcode 27 (Swift 6.4) on macOS 27.

```bash
swift test
```

```bash
xcodebuild -project App/OpenNexus.xcodeproj -scheme OpenNexus build
```

```bash
swift run nexus validate path/to/Map.nexus
```

```bash
swift run nexus --help
```

## Install

Download `OpenNexus-<version>.dmg` from the release, open it and drag OpenNexus to
Applications. It needs macOS 27 on Apple silicon.

A notarized release opens with a double-click. A release that's only signed (no
notarization yet) needs one extra step the first time: Control-click OpenNexus in
Applications and choose Open, or open it once and use System Settings › Privacy & Security
› Open Anyway.

The command-line tool is inside the app. To use it from Terminal:

```bash
ln -sf /Applications/OpenNexus.app/Contents/Helpers/nexus /usr/local/bin/nexus
```

## Make a release

```bash
App/tools/release.sh
```

This archives a Release build signed with your Developer ID, checks every signature, and
writes `dist/OpenNexus-<version>.dmg` with its SHA-256. It needs a "Developer ID
Application" certificate and `App/Config/Signing.local.xcconfig` naming your team (see
`App/Config/Base.xcconfig`). The version comes from `MARKETING_VERSION` in
`App/tools/make_project.py` (or `VERSION=…`), and the build number from the commit count.

To notarize and staple as well, store a notarytool profile once (an app-specific password
from account.apple.com); the script uses it whenever it exists:

```bash
xcrun notarytool store-credentials opennexus --apple-id you@example.com --team-id ABCDE12345
```

## File format

A `.nexus` document is a folder package of canonical, diff-friendly JSON: `manifest.json`,
one `canvases/<id>.json` per canvas, `theme.json`, and `assets/`. See
[`schema/nexus.schema.json`](schema/nexus.schema.json).

## Licence

MIT. See [LICENSE](LICENSE).
