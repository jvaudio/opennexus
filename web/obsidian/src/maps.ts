// Maps in the vault (M49): a `.nexusjson` file, or a `.nexus` package, which Obsidian shows
// as a folder. They're read with the viewer site's readers (M47d): the viewer copy, or the
// outline without one. On the Mac, a map without a copy is drawn by `nexus bundle` instead.

import { FileSystemAdapter, normalizePath, TFile, TFolder, type App } from "obsidian";
import { openJSON, openPackage, type Opened, type PackageFiles } from "../../viewer-app/src/document";
import { run } from "./nexus";

export type MapSource = { kind: "file"; file: TFile } | { kind: "package"; folder: TFolder };

export function isPackage(f: unknown): f is TFolder {
  return f instanceof TFolder && f.name.toLowerCase().endsWith(".nexus");
}

export function isMapFile(f: unknown): f is TFile {
  return f instanceof TFile && f.extension.toLowerCase() === "nexusjson";
}

/** The map at a vault path, if there's one there. */
export function mapAt(app: App, path: string): MapSource | undefined {
  const f = app.vault.getAbstractFileByPath(normalizePath(path));
  if (isMapFile(f)) return { kind: "file", file: f };
  if (isPackage(f)) return { kind: "package", folder: f };
  return undefined;
}

export function sourcePath(s: MapSource): string {
  return s.kind === "file" ? s.file.path : s.folder.path;
}

export function sourceName(s: MapSource): string {
  return s.kind === "file" ? s.file.name : s.folder.name;
}

/** Where a vault path is on disk; undefined off the desktop. */
export function fullPath(app: App, path: string): string | undefined {
  const a = app.vault.adapter;
  return a instanceof FileSystemAdapter ? a.getFullPath(normalizePath(path)) : undefined;
}

/** A package's files through the vault's adapter, keyed by path inside the package; `extra` adds or replaces some. */
export function packageFiles(app: App, root: string, paths: string[], extra = new Map<string, Uint8Array>()): PackageFiles {
  return {
    paths: () => [...paths.filter((p) => !extra.has(p)), ...extra.keys()],
    bytes: async (p) => extra.get(p) ?? new Uint8Array(await app.vault.adapter.readBinary(normalizePath(`${root}/${p}`))),
  };
}

/** Every file in a package, depth first, as paths inside it. */
export async function listPackage(app: App, root: string): Promise<string[]> {
  const out: string[] = [];
  const walk = async (dir: string): Promise<void> => {
    const l = await app.vault.adapter.list(dir);
    for (const f of l.files) out.push(f.slice(root.length + 1));
    for (const d of l.folders) await walk(d);
  };
  await walk(normalizePath(root));
  return out.sort();
}

/**
 * Reads a map. `tool` is the `nexus` tool when there is one: a map without a viewer copy is
 * then drawn by it (`nexus bundle`), as OpenNexus would save its copy.
 */
export async function openMap(app: App, s: MapSource, tool?: string): Promise<Opened> {
  if (s.kind === "file") {
    const text = await app.vault.read(s.file);
    const opened = openJSON(s.file.name, text);
    const drawn = opened.kind === "outline" ? await draw(app, s, tool) : undefined;
    if (drawn === undefined) return opened;
    const doc = JSON.parse(text) as Record<string, unknown>;
    doc.render = JSON.parse(drawn) as unknown;
    return openJSON(s.file.name, JSON.stringify(doc));
  }
  const root = s.folder.path;
  const paths = await listPackage(app, root);
  const opened = await openPackage(s.folder.name, packageFiles(app, root, paths));
  const drawn = opened.kind === "outline" ? await draw(app, s, tool) : undefined;
  if (drawn === undefined) return opened;
  const extra = new Map([["render/viewer.json", new TextEncoder().encode(drawn)]]);
  return openPackage(s.folder.name, packageFiles(app, root, paths, extra));
}

/** `nexus bundle`'s drawing of a map, or undefined (no tool, or it failed). */
async function draw(app: App, s: MapSource, tool?: string): Promise<string | undefined> {
  const path = fullPath(app, sourcePath(s));
  if (tool === undefined || path === undefined) return undefined;
  const r = await run(tool, ["bundle", path]);
  return r.code === 0 && r.stdout.trim() !== "" ? r.stdout : undefined;
}
