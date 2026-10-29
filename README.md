<h1>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="brand/svg/lockup/opennexus-lockup-dark.svg">
    <img src="brand/svg/lockup/opennexus-lockup-light.svg" alt="OpenNexus" width="320">
  </picture>
</h1>

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
  NexusNet             HTTP client and share destinations, linked only into OpenNexusNet.xpc
  NexusSync            library sync through your own bucket: encryption, merging, history
  NexusReplica         live co-editing: the CRDT behind sessions, invites and the room client
  NexusCanvas          AppKit canvas and SwiftUI chrome (rendering, editing, animation)
  NexusWidgetsUI       widgets
  nexus                command-line tool
App/                   Xcode project for the macOS app and its extensions (thin shell)
  tools/               make_project.py, release.sh, axaudit.swift
schema/                published JSON Schema for .nexus files
web/                   the interactive viewer (viewer-core) and the share-link site (viewer-app)
server/                OpenNexus Server: stores share links, relays live sessions (Swift, Docker)
brand/                 the Aperture brand kit: spec (BRAND.md), icons, marks, lockups
scripts/               build-icons.sh (document icon from brand/), lint.sh (what CI lints)
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

Lint as CI does: Swift formatting, and the brand checks (no old logo, document icon up to
date with `brand/`):

```bash
scripts/lint.sh
```

Share links for real: MinIO and two OpenNexus Servers in Docker, links made against them,
then opened in Chromium and WebKit (needs Docker; everything stays on `127.0.0.1`):

```bash
scripts/test-share.sh
```

Sync for real: MinIO in Docker, the sync property test and the upload and speed checks
through the real network service, then a longer property run in memory:

```bash
scripts/test-sync.sh
```

Live sessions for real: an OpenNexus Server in Docker, four Macs' worth of windows editing
through the real network code, then the server's files searched for anything readable:

```bash
scripts/test-collab.sh
```

## Install

Download `OpenNexus-<version>.dmg` from the release, open it and drag OpenNexus to
Applications. It needs macOS 27 on Apple silicon.

A notarized release opens with a double-click. A release that's only signed (no
notarization yet) needs one extra step the first time: Control-click OpenNexus in
Applications and choose Open, or open it once and use System Settings › Privacy & Security
› Open Anyway.

### Updates

From 0.2 on, OpenNexus can update itself. Updates are off until you turn them on: Settings ›
General › Updates, or answer yes when OpenNexus asks on a later launch. You can also choose
OpenNexus › Check for Updates… at any time.

With checks on, OpenNexus looks for a new version about once a day. Turn on "Download and
install updates automatically" to have new versions installed when you quit; otherwise it
asks first. The Beta channel also offers test versions.

The app itself still has no network permission. Sparkle's separate update service fetches
[`appcast.xml`](appcast.xml) from this repository and the DMG from GitHub Releases, and
every update must carry the project's signature before it's installed. Version 0.1 predates
updates, so install 0.2 by hand once.

### Share links

File › Share Link… (⌃⌘S) turns a map, a canvas, a branch or a zone into a link anyone can
open in a browser. The map is encrypted on your Mac and the key is only in the link, so the
place that stores it (your own S3-compatible bucket, a secret GitHub gist, or an
[OpenNexus Server](server/README.md) you run) holds bytes it can't read.

Sharing is off until you turn it on in Settings › Privacy & Data › Network. Even then the
app has no network permission: a separate service, OpenNexusNet, makes every request, only
to the destinations you set up in Settings › Sharing, and Privacy & Data lists each one.

### Sync

Settings › Sync keeps a folder of documents (a library) the same on each of your Macs
through an S3-compatible bucket you own: AWS, Cloudflare R2, Backblaze B2, MinIO and others.
Everything is encrypted on your Mac first; Show Recovery Key… gives the key (as text and a
QR code) to set up your other Macs. Changes from two Macs are merged topic by topic, and
where both changed the same topic, your Mac's version stays until you choose in File ›
Resolve Conflicts…. File › Sync History… restores any earlier version, and deleted documents
can be restored for 30 days. Like sharing, sync is off until you turn it on in Privacy &
Data › Network, and only OpenNexusNet makes its requests.

Folders that iCloud Drive, Dropbox, Google Drive, OneDrive or Syncthing sync work too: when
those apps leave a conflicting copy, opening the document offers to merge it in.

For maps kept in Git, run this once in the repository so Git merges them topic by topic and
shows diffs as outlines:

```bash
nexus git setup
```

### Live sessions (Labs)

File › Collaborate… (⌃⌘L) lets several people edit a document at the same time, each on
their own Mac. Choose an OpenNexus Server from Settings › Sharing and whether the invite
lets people edit or only watch, then send the link. Everyone sees each other's selections
and edits as they happen, every copy ends up the same, and ⌘Z undoes only your own changes.
Everything is sealed with a key that's only in the invite, so the server passes along bytes
it can't read. People without the app see the host's latest view in the browser. End
Session deletes what the server kept; everyone keeps their copy. Turn on "Live co-editing"
in Settings › Privacy & Data › Network first.

### Command-line tool

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

The script also signs the DMG for Sparkle with the EdDSA key in your login keychain (made
once with Sparkle's `generate_keys --account opennexus`; the first signing asks to use it),
and adds the release to `appcast.xml`. `CHANNEL=beta` marks it for the Beta channel. Then
publish it: this tags the build, creates the GitHub Release with the DMG, and only then
pushes the feed, so installed copies are offered the new version. A Beta build becomes a
GitHub pre-release, read from its feed entry:

```bash
App/tools/publish.sh 0.2
```

Keep a backup of the update signing key: without it, installed copies can't be updated.

```bash
generate_keys --account opennexus -x ~/opennexus-update-key.txt
```

`generate_keys` is in Sparkle's `bin/` folder, under the build's
`SourcePackages/artifacts/sparkle/Sparkle/bin`. Store the exported file somewhere safe and
offline, not in Git.

## File format

A `.nexus` document is a folder package of canonical, diff-friendly JSON: `manifest.json`,
one `canvases/<id>.json` per canvas, `theme.json`, and `assets/`. See
[`schema/nexus.schema.json`](schema/nexus.schema.json).

## Licence

MIT. See [LICENSE](LICENSE).
