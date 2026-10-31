// What a document holds, as the viewer site shows it (M47d): its viewer copy (D314), or
// without one the outline of each canvas, read from the document's own JSON. A
// `.nexusjson` file, a `.nexus` folder's files and a zipped package all come here. The
// files are untrusted: everything is checked, and the viewer copy goes on to parseBundle.

import { entries, read, ZipError } from "./zip";

export interface OutlineTopic {
  text: string;
  note?: string;
  children: OutlineTopic[];
}

export interface OutlineCanvas {
  title: string;
  topics: OutlineTopic[];
}

export type Opened =
  | {
      kind: "bundle";
      name: string;
      /** The viewer copy's JSON text. */
      text: string;
      /** A blob: URL for an asset the copy names, typed as the bundle says. */
      asset: (name: string, type?: string) => string | undefined;
      /** Lets go of the asset URLs. */
      close: () => void;
    }
  | { kind: "outline"; name: string; title: string; canvases: OutlineCanvas[]; json: boolean }
  | { kind: "encrypted"; name: string; hint?: string }
  | { kind: "refused"; name: string; reason: string };

/** A package's files, by path inside the package. */
export interface PackageFiles {
  paths: () => string[];
  bytes: (path: string) => Promise<Uint8Array>;
}

export const FORMAT = "opennexus";
const VIEWER_COPY = "render/viewer.json";

type Obj = Record<string, unknown>;

function obj(v: unknown): Obj | undefined {
  return typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Obj) : undefined;
}

function own(o: Obj | undefined, k: string): unknown {
  return o !== undefined && Object.prototype.hasOwnProperty.call(o, k) ? o[k] : undefined;
}

function str(v: unknown): string | undefined {
  return typeof v === "string" ? v : undefined;
}

function parseJSON(text: string): unknown {
  try {
    return JSON.parse(text) as unknown;
  } catch {
    return undefined;
  }
}

/** The display name without the document's extension. */
export function baseName(name: string): string {
  return name.replace(/\/+$/, "").replace(/^.*\//, "").replace(/(?:\.nexus)?\.zip$|\.(?:nexusjson|nexus|json)$/i, "") || name;
}

/** Each canvas's outline: the root and floating topics, depth first, with notes. */
export function outline(canvas: unknown): OutlineCanvas {
  const c = obj(canvas);
  const nodes = obj(own(c, "nodes"));
  const seen = new Set<string>();
  function topic(id: unknown): OutlineTopic | undefined {
    if (typeof id !== "string" || seen.has(id)) return undefined;
    const n = obj(own(nodes, id));
    if (n === undefined) return undefined;
    seen.add(id);
    const kids = own(n, "children");
    const t: OutlineTopic = {
      text: str(own(n, "text")) ?? "",
      children: (Array.isArray(kids) ? kids : []).map(topic).filter((x): x is OutlineTopic => x !== undefined),
    };
    const note = str(own(obj(own(n, "note")), "text"));
    if (note !== undefined && note.trim() !== "") t.note = note;
    return t;
  }
  const floating = own(c, "floating");
  const topics = [own(c, "root"), ...(Array.isArray(floating) ? (floating as unknown[]) : [])]
    .map(topic)
    .filter((x): x is OutlineTopic => x !== undefined);
  const title = str(own(c, "title")) ?? "";
  return { title: title === "" ? (topics[0]?.text ?? "") : title, topics };
}

/** Refuses what isn't an OpenNexus document; notices an encrypted one. */
function check(name: string, manifest: Obj | undefined): Opened | undefined {
  if (manifest === undefined || own(manifest, "format") !== FORMAT) {
    return { kind: "refused", name, reason: "It isn’t an OpenNexus document." };
  }
  if (own(manifest, "encrypted") === true) {
    // The hint sits beside the encryption's parameters, readable without the password.
    const hint = str(own(manifest, "hint"));
    return hint === undefined || hint === "" ? { kind: "encrypted", name } : { kind: "encrypted", name, hint };
  }
  return undefined;
}

function title(canvases: OutlineCanvas[], name: string): string {
  return canvases[0]?.topics[0]?.text ?? baseName(name);
}

class Assets {
  private readonly urls = new Map<string, string>();
  constructor(private readonly blob: (name: string) => Blob | undefined) {}

  url(name: string, type?: string): string | undefined {
    const cached = this.urls.get(name);
    if (cached !== undefined) return cached;
    const b = this.blob(name);
    if (b === undefined) return undefined;
    const u = URL.createObjectURL(type === undefined ? b : new Blob([b], { type }));
    this.urls.set(name, u);
    return u;
  }

  close(): void {
    for (const u of this.urls.values()) URL.revokeObjectURL(u);
    this.urls.clear();
  }
}

function bundle(name: string, text: string, blob: (name: string) => Blob | undefined): Opened {
  const assets = new Assets(blob);
  return {
    kind: "bundle",
    name,
    text,
    asset: (n, type) => assets.url(n, type),
    close: () => {
      assets.close();
    },
  };
}

function base64(s: string): Uint8Array | undefined {
  try {
    return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
  } catch {
    return undefined;
  }
}

/** A single-file document: its `render` key, or the outline of its canvases. */
export function openJSON(name: string, text: string): Opened {
  const o = obj(parseJSON(text));
  if (o === undefined) return { kind: "refused", name, reason: "It isn’t an OpenNexus document." };
  const refused = check(name, obj(own(o, "manifest")));
  if (refused !== undefined) return refused;
  const render = own(o, "render");
  if (render !== undefined) {
    const assets = obj(own(o, "assets"));
    return bundle(name, JSON.stringify(render), (n) => {
      const data = str(own(assets, n));
      const bytes = data === undefined ? undefined : base64(data);
      return bytes === undefined ? undefined : new Blob([bytes as BlobPart]);
    });
  }
  const list = own(o, "canvases");
  const canvases = (Array.isArray(list) ? list : []).map(outline);
  return { kind: "outline", name, title: title(canvases, name), canvases, json: true };
}

/** Where the package sits among `paths`: the folder holding the shallowest manifest. */
export function packageRoot(paths: string[]): string | undefined {
  let best: string | undefined;
  for (const p of paths) {
    if (p !== "manifest.json" && !p.endsWith("/manifest.json")) continue;
    const root = p.slice(0, p.length - "manifest.json".length);
    if (best === undefined || root.split("/").length < best.split("/").length) best = root;
  }
  return best;
}

/** A package's files: its viewer copy, or the outline of its canvases. */
export async function openPackage(name: string, files: PackageFiles): Promise<Opened> {
  const paths = files.paths();
  const root = packageRoot(paths);
  if (root === undefined) {
    // A zip or folder holding one single-file document.
    const json = paths.filter((p) => p.toLowerCase().endsWith(".nexusjson"));
    if (json.length === 1 && json[0] !== undefined) {
      return openJSON(baseName(json[0]), new TextDecoder().decode(await files.bytes(json[0])));
    }
    return { kind: "refused", name, reason: "It doesn’t hold an OpenNexus document." };
  }
  const has = new Set(paths);
  const text = async (p: string): Promise<string> => new TextDecoder().decode(await files.bytes(root + p));
  const manifest = obj(parseJSON(await text("manifest.json")));
  const refused = check(name, manifest);
  if (refused !== undefined) return refused;
  if (has.has(root + VIEWER_COPY)) {
    // The copy names its assets; they're the package's `assets/` files.
    const blobs = new Map<string, Blob>();
    for (const p of paths) {
      if (!p.startsWith(root + "assets/")) continue;
      blobs.set(p.slice(root.length + "assets/".length), new Blob([(await files.bytes(p)) as BlobPart]));
    }
    return bundle(name, await text(VIEWER_COPY), (n) => blobs.get(n));
  }
  const order = own(manifest, "canvases");
  const canvases: OutlineCanvas[] = [];
  for (const id of Array.isArray(order) ? order : []) {
    if (typeof id !== "string" || !/^[A-Za-z0-9_-]+$/.test(id) || !has.has(`${root}canvases/${id}.json`)) continue;
    canvases.push(outline(parseJSON(await text(`canvases/${id}.json`))));
  }
  return { kind: "outline", name, title: title(canvases, name), canvases, json: false };
}

/** A folder's files, keyed by path inside it. */
export function folderFiles(files: Map<string, Blob>): PackageFiles {
  return {
    paths: () => [...files.keys()],
    bytes: async (p) => {
      const f = files.get(p);
      if (f === undefined) throw new Error(`missing ${p}`);
      return new Uint8Array(await f.arrayBuffer());
    },
  };
}

/** A zip's files. */
export function zipFiles(data: Uint8Array): PackageFiles {
  const list = new Map(entries(data).map((e) => [e.name, e]));
  return {
    paths: () => [...list.keys()],
    bytes: (p) => {
      const e = list.get(p);
      if (e === undefined) throw new ZipError(`missing ${p}`);
      return read(data, e);
    },
  };
}

/** A zipped package (or a zipped `.nexusjson`). */
export async function openZip(name: string, data: Uint8Array): Promise<Opened> {
  try {
    return await openPackage(name, zipFiles(data));
  } catch (e) {
    if (e instanceof ZipError) return { kind: "refused", name, reason: `The zip can’t be read: ${e.message}.` };
    throw e;
  }
}

/** A file the reader chose or dropped. */
export async function openFile(file: File): Promise<Opened> {
  const name = file.name;
  const lower = name.toLowerCase();
  if (lower.endsWith(".zip")) return openZip(name, new Uint8Array(await file.arrayBuffer()));
  if (lower.endsWith(".nexusjson") || lower.endsWith(".json")) return openJSON(name, await file.text());
  if (lower.endsWith(".nexus")) {
    return { kind: "refused", name, reason: "A .nexus document is a folder: open the folder, or a zip of it." };
  }
  return { kind: "refused", name, reason: "It isn’t an OpenNexus document (.nexusjson, a .nexus folder or a zip of one)." };
}
