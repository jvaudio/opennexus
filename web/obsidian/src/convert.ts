// Conversions (M49): "Convert note to OpenNexus map" writes a `.nexusjson` beside the note
// with `nexus import` (and its viewer copy, so it shows on Obsidian for iOS too); "Insert map
// as outline" writes a map's Markdown export into the note: `nexus export` on the Mac, else
// the outline of its viewer copy.

import { FuzzySuggestModal, Notice, TFile, type App, type Editor, type MarkdownView } from "obsidian";
import { parseBundle, type Bundle, type Canvas } from "../../viewer-core/src/bundle";
import type { Opened, OutlineTopic } from "../../viewer-app/src/document";
import type { Host } from "./host";
import { fullPath, isMapFile, isPackage, openMap, sourceName, sourcePath, type MapSource } from "./maps";
import { run } from "./nexus";

/** Where a note's map goes: beside it, named after it. */
export function mapPathFor(note: string): string {
  return note.replace(/\.md$/i, "") + ".nexusjson";
}

export async function convertNote(host: Host, view: MarkdownView): Promise<void> {
  const app = host.app;
  const file = view.file;
  const tool = await host.nexus();
  if (file === null || tool === undefined) return;
  await view.save();
  const out = mapPathFor(file.path);
  if (app.vault.getAbstractFileByPath(out) !== null) {
    new Notice(`“${out}” already exists.`);
    return;
  }
  const from = fullPath(app, file.path);
  const to = fullPath(app, out);
  if (from === undefined || to === undefined) return;
  const r = await run(tool, ["import", from, "--out", to, "--viewer-copy"]);
  if (r.code !== 0) {
    new Notice(`OpenNexus couldn’t convert the note: ${r.stderr.trim()}`);
    return;
  }
  new Notice(`Made “${out}”.`);
  // The vault notices the new file a moment later.
  for (let i = 0; i < 40 && !(app.vault.getAbstractFileByPath(out) instanceof TFile); i++) {
    await new Promise((r) => window.setTimeout(r, 50));
  }
  const made = app.vault.getAbstractFileByPath(out);
  if (made instanceof TFile) await app.workspace.getLeaf("tab").openFile(made);
}

function bullets(items: OutlineTopic[], depth: number, out: string[]): void {
  const pad = "  ".repeat(depth);
  for (const t of items) {
    out.push(`${pad}- ${t.text.replace(/\n/g, " ")}`);
    if (t.note !== undefined && t.note !== "") for (const l of t.note.split("\n")) out.push(`${pad}  ${l}`);
    bullets(t.children, depth + 1, out);
  }
}

/** A bundle's canvases as Markdown: a heading each, then its topics as bullets with notes. */
export function bundleMarkdown(b: Bundle): string {
  const out: string[] = [];
  for (const c of b.canvases) {
    const tree = (items: Canvas["outline"]): OutlineTopic[] =>
      items.map((i) => {
        const t = c.topics.get(i.id);
        return { text: t?.text ?? "", ...(t?.note === undefined ? {} : { note: t.note }), children: tree(i.children) };
      });
    if (b.canvases.length > 1) out.push(`## ${c.title}`, "");
    bullets(tree(c.outline), 0, out);
    out.push("");
  }
  return out.join("\n");
}

/** A map's Markdown without `nexus`: its viewer copy's outline, or its own outline. */
export function openedMarkdown(opened: Opened): string | undefined {
  if (opened.kind === "bundle") {
    try {
      return bundleMarkdown(parseBundle(opened.text));
    } catch {
      return undefined;
    } finally {
      opened.close();
    }
  }
  if (opened.kind !== "outline") return undefined;
  const out: string[] = [];
  for (const c of opened.canvases) {
    if (opened.canvases.length > 1) out.push(`## ${c.title}`, "");
    bullets(c.topics, 0, out);
    out.push("");
  }
  return out.join("\n");
}

/** Every map in the vault. */
export function vaultMaps(app: App): MapSource[] {
  return app.vault
    .getAllLoadedFiles()
    .flatMap((f): MapSource[] => (isMapFile(f) ? [{ kind: "file", file: f }] : isPackage(f) ? [{ kind: "package", folder: f }] : []))
    .sort((a, b) => sourcePath(a).localeCompare(sourcePath(b)));
}

class MapPicker extends FuzzySuggestModal<MapSource> {
  constructor(
    app: App,
    private readonly maps: MapSource[],
    private readonly chosen: (m: MapSource) => void,
  ) {
    super(app);
    this.setPlaceholder("Choose a map to insert as an outline");
  }

  getItems(): MapSource[] {
    return this.maps;
  }

  getItemText(m: MapSource): string {
    return sourcePath(m);
  }

  onChooseItem(m: MapSource): void {
    this.chosen(m);
  }
}

/** The map's Markdown: `nexus export --to md` on the Mac, else its outline. */
export async function mapMarkdown(host: Host, m: MapSource): Promise<string | undefined> {
  const tool = await host.nexus();
  const path = fullPath(host.app, sourcePath(m));
  if (tool !== undefined && path !== undefined) {
    const r = await run(tool, ["export", path, "--to", "md"]);
    if (r.code === 0) return r.stdout;
  }
  return openedMarkdown(await openMap(host.app, m));
}

export function insertOutline(host: Host, editor: Editor): void {
  const maps = vaultMaps(host.app);
  if (maps.length === 0) {
    new Notice("There are no OpenNexus maps in this vault.");
    return;
  }
  new MapPicker(host.app, maps, (m) => {
    void mapMarkdown(host, m).then((md) => {
      if (md === undefined) new Notice(`Couldn’t read “${sourceName(m)}”.`);
      else editor.replaceSelection(md.endsWith("\n") ? md : `${md}\n`);
    });
  }).open();
}
