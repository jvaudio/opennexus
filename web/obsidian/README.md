# OpenNexus for Obsidian

See [OpenNexus](https://github.com/jvaudio/opennexus) mind maps and diagrams in your vault,
embed them in notes, and see any note as a map. Maps are read-only here; you edit them in
OpenNexus.

## What it does

- **Maps in tabs.** A `.nexusjson` file opens in its own tab: pan, zoom, the outline, search,
  each topic's details and Present. A `.nexus` package is a folder to Obsidian: choose
  **Open as OpenNexus map** from its menu.
- **Maps in notes.** A `nexus` code block shows a map in a note, in Reading view and Live
  Preview. Only `file` is needed:

  ````markdown
  ```nexus
  file: Maps/Launch plan.nexusjson
  canvas: Roadmap
  topic: Launch plan > Pricing
  layout: expanded
  height: 300
  ```
  ````

  `file` is a path in the vault, a `[[link]]`, or a package's name. `canvas` is a canvas's
  title or id; `topic` frames a branch (an id, a title, or a path like `A > B`); `layout` is
  `saved` (as saved, with folded branches) or `expanded` (every topic); `height` is in
  pixels. A map in a note starts drawing when you scroll to it.
- **Links.** `[[Wikilinks]]` in topic notes and `obsidian://open` links on topics open your
  notes. **Copy link to topic** (the link button on a map's tab, or the command) copies an
  `obsidian://opennexus` link that reopens the map at that topic.
- **Live.** An open map redraws when OpenNexus saves it.
- **With OpenNexus on a Mac** (it uses the app's `nexus` tool):
  - **Edit in OpenNexus** opens the map in the app.
  - **Show this note as a map** draws the note beside it, its headings and lists as topics,
    and keeps up as you type. Click a topic to put the cursor on its line.
  - **Convert note to OpenNexus map** saves the note as a map beside it.
  - Maps saved without a viewer copy are drawn too.

  **Insert map as outline** works everywhere: it writes a map's topics into the note as a
  list.

Elsewhere, including Obsidian on iPhone and iPad, maps show from the viewer copy that
OpenNexus saves in each document (Settings › Files & Backup › Save a viewer copy; for
`.nexusjson` files, also turn on "Also in single-file documents"). A note shows as its
outline.

## Privacy

The plugin makes no network requests, and maps never leave your vault. Text in a map is
shown as text, never as HTML. Links to notes open only notes in this vault; web and email
links open the way Obsidian opens any link.

## Settings

- **OpenNexus command-line tool**: where the app's `nexus` tool is. Leave it empty to use the
  one inside OpenNexus.
- **Layout**: how maps open, as saved or with every branch expanded.
- **Embed height**: for `nexus` blocks that don't give one.
- **Use Obsidian's theme**: the map's bar, outline and details take Obsidian's colours; the
  map keeps its own.
- **Note as map layout**: mind map, logic chart, org chart, tree, timeline or fishbone.

## Install by hand

Download `main.js`, `manifest.json` and `styles.css` from a release into
`<vault>/.obsidian/plugins/opennexus/`, then turn on OpenNexus in Settings › Community
plugins.

## Source

The plugin is built from `web/obsidian` in the OpenNexus repository, with the viewer from
`web/viewer-core`: `npm ci && npm run build -w obsidian` in `web/`. This repository mirrors
it for releases. MIT licence.
