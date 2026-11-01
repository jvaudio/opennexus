// Note as map (M49): a side view of a Markdown note as a map, redrawn a moment after typing
// stops. On the Mac `nexus bundle -` reads the note as OpenNexus's Markdown import does and
// lays it out, keeping each topic's line, so selecting a topic moves the editor's cursor to
// it. The note stays the source of truth. Elsewhere it shows the note's outline.

import { ItemView, MarkdownView, type ViewStateResult, type WorkspaceLeaf } from "obsidian";
import type { Host } from "./host";
import { hostLinks } from "./links";
import { run } from "./nexus";
import { noteOutline, noteOutlineList } from "./outline";
import { MapPanel } from "./panel";
import { ICON } from "./views";

export const VIEW_NOTE = "opennexus-note-map";
/** How long typing has to pause before the map is redrawn. */
export const TYPING_MS = 400;

/** Each topic's line from a `nexus bundle` of Markdown (its first canvas's `lines`). */
export function bundleLines(text: string): Map<string, number> {
  const out = new Map<string, number>();
  let b: unknown;
  try {
    b = JSON.parse(text);
  } catch {
    return out;
  }
  const canvases = (b as { canvases?: unknown } | null)?.canvases;
  const lines = Array.isArray(canvases) ? (canvases[0] as { lines?: unknown } | undefined)?.lines : undefined;
  if (typeof lines !== "object" || lines === null) return out;
  for (const [id, n] of Object.entries(lines)) if (typeof n === "number" && Number.isInteger(n) && n > 0) out.set(id, n);
  return out;
}

export class NoteMapView extends ItemView {
  readonly panel: MapPanel;
  path = "";
  /** How many times the map has been drawn, and how long the last took (the tests watch them). */
  draws = 0;
  private lines = new Map<string, number>();
  private timer: number | undefined;
  private generation = 0;

  constructor(
    leaf: WorkspaceLeaf,
    readonly host: Host,
  ) {
    super(leaf);
    this.contentEl.classList.add("opennexus-view");
    this.panel = new MapPanel(this.contentEl.appendChild(this.contentEl.ownerDocument.createElement("div")));
  }

  getViewType(): string {
    return VIEW_NOTE;
  }

  override getIcon(): string {
    return ICON;
  }

  getDisplayText(): string {
    const name = this.path.split("/").pop()?.replace(/\.md$/i, "") ?? "";
    return name === "" ? "Note as map" : `${name} as a map`;
  }

  override onload(): void {
    super.onload();
    const { workspace, vault } = this.app;
    this.registerEvent(
      workspace.on("editor-change", (editor, info) => {
        if (info.file?.path === this.path) this.schedule(() => editor.getValue());
      }),
    );
    this.registerEvent(
      vault.on("modify", (f) => {
        if (f.path === this.path) this.schedule(() => this.read());
      }),
    );
    this.registerEvent(
      vault.on("rename", (f, old) => {
        if (old === this.path) this.path = f.path;
      }),
    );
    this.register(() => {
      window.clearTimeout(this.timer);
      this.generation++;
      this.panel.clear();
    });
  }

  override async setState(state: unknown, result: ViewStateResult): Promise<void> {
    const path = (state as { path?: unknown } | null)?.path;
    if (typeof path === "string" && path !== this.path) {
      this.path = path;
      await this.draw(await this.read());
    }
    await super.setState(state, result);
  }

  override getState(): Record<string, unknown> {
    return { ...super.getState(), path: this.path };
  }

  private async read(): Promise<string> {
    const f = this.app.vault.getFileByPath(this.path);
    return f === null ? "" : this.app.vault.cachedRead(f);
  }

  private schedule(text: () => string | Promise<string>): void {
    window.clearTimeout(this.timer);
    this.timer = window.setTimeout(() => void Promise.resolve(text()).then((t) => this.draw(t)), TYPING_MS);
  }

  /** Draws `text` as a map with `nexus`, or as its outline. */
  async draw(text: string): Promise<void> {
    const generation = ++this.generation;
    const tool = await this.host.nexus();
    const title = this.path.split("/").pop()?.replace(/\.md$/i, "") ?? "Note";
    if (tool === undefined) {
      this.panel.clear();
      const doc = this.contentEl.ownerDocument;
      const box = doc.createElement("div");
      box.className = "opennexus-message opennexus-outline";
      const p = doc.createElement("p");
      p.textContent = "With OpenNexus on a Mac, this shows the note as a map. Here it’s the note’s outline.";
      box.append(p, noteOutlineList(doc, noteOutline(text), (line) => { this.goToLine(line); }));
      this.panel.el.append(box);
      this.drawn();
      return;
    }
    const structure = this.host.settings.noteStructure;
    const args = ["bundle", "-", "--title", title, ...(structure === "" ? [] : ["--structure", structure])];
    const r = await run(tool, args, text);
    if (generation !== this.generation) return;
    if (r.code !== 0) {
      this.panel.clear();
      const p = this.contentEl.ownerDocument.createElement("p");
      p.className = "opennexus-message";
      p.textContent = `OpenNexus couldn’t draw this note: ${r.stderr.trim()}`;
      this.panel.el.append(p);
      return;
    }
    this.lines = bundleLines(r.stdout);
    const s = this.host.settings;
    this.panel.show(
      { kind: "bundle", name: title, text: r.stdout, asset: () => undefined, close: () => undefined },
      {
        chrome: "full",
        layout: "saved",
        followTheme: s.followTheme,
        hostLinks: hostLinks(this.app, this.path, (t) => void this.host.openTopic(t)),
        onSelect: (_canvas, topic) => {
          const line = topic === null ? undefined : this.lines.get(topic);
          if (line !== undefined) this.goToLine(line);
        },
      },
      this.panel.keep(),
    );
    this.drawn();
  }

  private drawn(): void {
    this.draws++;
    this.contentEl.dataset.opennexusDraws = String(this.draws);
  }

  /** Moves the cursor of the note's editor to `line` (from 1) and scrolls to it, leaving focus where it is. */
  goToLine(line: number): void {
    for (const leaf of this.app.workspace.getLeavesOfType("markdown")) {
      const v = leaf.view;
      if (!(v instanceof MarkdownView) || v.file?.path !== this.path) continue;
      const pos = { line: Math.max(0, Math.min(line - 1, v.editor.lineCount() - 1)), ch: 0 };
      v.editor.setCursor(pos);
      v.editor.scrollIntoView({ from: pos, to: pos }, true);
    }
  }
}
