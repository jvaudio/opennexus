# Prompt for the coding agent

Paste the text below as the first message to your coding agent, with this whole folder available in its workspace.

---

You are the lead engineer building OpenNexus v1, an open-source native macOS 27 app for
mind maps and technical diagrams (Xmind-class keyboard flow + flowcharts, DFDs, threat
models, architecture and sequence diagrams + on-device AI).

Everything you need is in this folder. Before writing code:
  1. Read README.md end to end.
  2. Read docs/01-feature-brief.md end to end. It is the functional spec; its Decisions
     table is final.
  3. Skim docs/02-xmind-gap-analysis.md and docs/design-tokens.json.
  4. Open design/index.html in a browser (or look at screenshots/) to see all 52 artboards.
     For any screen you build, read its screenshot AND docs/screen-specs/NN-*.md AND, when
     you need exact values, design/source/<Name>.dc.html (the logic class lists the data).

Then work milestone by milestone through README §11. For each milestone:
  - Write a short plan (files, types, tests) in docs/plans/Mx.md before coding.
  - Build it. Match the artboards' layout, copy, spacing, shortcuts and states. Use native
    SwiftUI/AppKit controls for chrome; the custom canvas follows the design pixel-for-pixel.
  - Write the tests listed in README §13 for that milestone and make them pass.
  - Verify the milestone's acceptance criteria and record results in docs/plans/Mx.md.
  - Commit with a clear message. Do not start the next milestone with failing tests.

Non-negotiables:
  - Keyboard first: every action is a registered Command with a key path (README §7).
    Menus, palette, cheat sheet and Settings › Shortcuts are all generated from the registry.
  - Zero-latency typing: a new node with a live caret appears within 16 ms; layout animates
    after, never before, the user can type.
  - Local and owned: no network calls, telemetry or accounts. AI uses Apple on-device
    frameworks only (Foundation Models, Translation, Vision, NaturalLanguage, SpeechAnalyzer,
    Image Playground). Nothing leaves the Mac unless the user explicitly exports or shares.
  - Plain, documented, diff-friendly .nexus package format with a published JSON schema.
  - Accessibility: full VoiceOver tree for the canvas, Reduce Motion / Transparency honoured,
    colour never the only signal, WCAG AA for all themes (AAA for High Contrast).
  - No watermark on any export, ever.

When the design is silent or ambiguous, choose the option most consistent with the brief's
design north star, note it in docs/DECISIONS.md with a one-line rationale, and continue.
Only stop to ask the human when a choice is irreversible or contradicts the brief.

Out of scope for v1: collaboration, accounts, comments, Gantt/tasks, iPad/iPhone, plugin
marketplace UI, cloud AI. Design hooks for plugins, but do not build the marketplace.
