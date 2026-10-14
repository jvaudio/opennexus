# SET-8 · Integrations (MCP, CLI, Quick Capture)

- Source: `design/source/SetIntegrations.dc.html`
- Screenshot: `screenshots/40-SetIntegrations.png`
- Artboard size: 1440×900 pt

> Text extracted verbatim from the rendered artboard, top-to-bottom. Use it alongside the screenshot for exact copy, labels, shortcuts and values.

```text
Search settings
G
General
E
Editing
A
Appearance
F
Files & Backup
✦
AI
⌘
Shortcuts
↗
Export
⇄
Integrations
◐
Privacy & Data
◎
Accessibility
⌘, opens Settings · ⌘F searches every pane
Integrations
Ways in and out of OpenNexus without leaving the Mac.
Quick Capture
Global shortcut
✦ N
Start at login
Lives in the menu bar
Send captures to
Inbox map ▾
Multi-line text becomes
Indented lines keep their hierarchy
Inbox items
A new map
macOS
Shortcuts & Siri actions
Create from clipboard, add to inbox, export, convert
Services menu: New Map from Selection
Share extension
Send text, links and images to a map
Safari web clipper
Summarises the page on-device into a branch
Spotlight indexing of node text
Open code links in
Xcode ▾
Agents · MCP & CLI
Local MCP server
Off by default. No network port; stdio only
Allowed folders
2 folders
Edit…
Read maps
Allow
Ask
Block
Edit maps
Allow
Ask
Block
Create & export files
Allow
Ask
Block
Command-line tool
Installs /usr/local/bin/nexus
Install…
Every agent edit is one undo step and is marked with the ✦ provenance sparkle.
CONNECT AN AGENT
Server running · local only
Any MCP client on this Mac (Claude, Codex, Cursor…) can read and edit maps in the folders you allow. Nothing is uploaded.
$ nexus mcp            # stdio server
$ nexus new "Q3 plan" --type mindmap
$ nexus export plan.nexus --to mermaid
$ nexus validate plan.nexus
// MCP client config
{ "opennexus": { "command": "nexus", "args": ["mcp"] } }
list_maps
read_map
add_topic
add_edge
set_style
convert_type
export
```
