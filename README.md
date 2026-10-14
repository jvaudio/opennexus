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
  NexusCore            graph model, reversible edits (patches), undo, tree operations
  NexusLayout          pure layout engines and branch-line geometry
  NexusFormat          .nexus package read/write, canonical JSON, schema validation
  NexusTheme           tokens, themes, node styles, contrast checks
  NexusKeys            command registry, key chords, profiles, conflict detection
  NexusCanvas          AppKit canvas (rendering, editing, animation)
  nexus                command-line tool (`nexus validate`)
App/                   Xcode project for the macOS app (thin shell over the package)
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

## File format

A `.nexus` document is a folder package of canonical, diff-friendly JSON: `manifest.json`,
one `canvases/<id>.json` per canvas, `theme.json`, and `assets/`. See
[`schema/nexus.schema.json`](schema/nexus.schema.json).
