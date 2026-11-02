// The viewer bundle (schema/viewer.schema.json, version 1), read defensively: a bundle
// is untrusted input, so every field is checked and every record becomes a Map (no
// prototype lookups for ids like "constructor").

export type Rect = readonly [number, number, number, number];

export interface Placement {
  frame: Rect;
  depth: number;
  text?: Rect;
  parent?: string;
  hidden?: number;
  badge?: Rect;
}

export interface Zone {
  id: string;
  title: string;
  frame: Rect;
}

export interface Layout {
  svg: string;
  viewBox: Rect;
  topics: Map<string, Placement>;
  zones: Zone[];
}

export type LinkKind = "web" | "mail" | "topic" | "file" | "other";

export interface Link {
  href: string;
  kind: LinkKind;
  canvas?: string;
  topic?: string;
}

export interface Comment {
  author: string;
  date: string;
  text: string;
}

export interface Attachment {
  name: string;
  size?: number;
  asset?: string;
}

export interface Topic {
  text: string;
  label: string;
  type?: string;
  note?: string;
  comments: Comment[];
  link?: Link;
  attachments: Attachment[];
  task?: string;
  labels: string[];
  markers: string[];
  fields: { key: string; value: string }[];
}

export interface OutlineItem {
  id: string;
  children: OutlineItem[];
  folded: boolean;
}

export interface Theme {
  canvas: string;
  ink: string;
  ink2: string;
  accent: string;
  dark: boolean;
}

/** One slide of the canvas's deck (M47d): what the camera frames and what the caption says. */
export interface Slide {
  kicker: string;
  title: string;
  /** Topics the camera frames; the rest dims. Empty frames the whole map, dimming nothing. */
  focus: string[];
  /** Topics drawn with the step's ring. */
  highlight: string[];
  note?: string;
}

/** The deck as the app plays it: its slides after the user's order, merges and skips. */
export interface Deck {
  /** How the camera moves between slides: at once, a short glide, or flying. */
  move: "cut" | "glide" | "fly";
  /** Width over height. */
  aspect: number;
  slides: Slide[];
}

export interface Canvas {
  id: string;
  title: string;
  type: string;
  typeName: string;
  theme: Theme;
  layouts: { saved: Layout; expanded?: Layout };
  outline: OutlineItem[];
  topics: Map<string, Topic>;
  legend?: { title: string; rows: { text: string; marker?: string }[] };
  threats?: { columns: string[]; rows: string[][] };
  deck?: Deck;
}

export interface Asset {
  type: string;
  size: number;
  data?: string;
}

export interface Bundle {
  title: string;
  lang: string;
  strings: Map<string, string>;
  canvases: Canvas[];
  assets: Map<string, Asset>;
}

export class BundleError extends Error {}

type Obj = Record<string, unknown>;

function fail(path: string, what: string): never {
  throw new BundleError(`${path}: ${what}`);
}

function obj(v: unknown, path: string): Obj {
  if (typeof v !== "object" || v === null || Array.isArray(v)) fail(path, "expected an object");
  return v as Obj;
}

function arr(v: unknown, path: string): unknown[] {
  if (!Array.isArray(v)) fail(path, "expected an array");
  return v;
}

function str(v: unknown, path: string): string {
  if (typeof v !== "string") fail(path, "expected a string");
  return v;
}

function num(v: unknown, path: string): number {
  if (typeof v !== "number" || !Number.isFinite(v)) fail(path, "expected a number");
  return v;
}

function int(v: unknown, path: string, min: number): number {
  const n = num(v, path);
  if (!Number.isInteger(n) || n < min) fail(path, `expected an integer ≥ ${String(min)}`);
  return n;
}

function own(o: Obj, key: string): unknown {
  return Object.hasOwn(o, key) ? o[key] : undefined;
}

function optStr(o: Obj, key: string, path: string): string | undefined {
  const v = own(o, key);
  return v === undefined ? undefined : str(v, `${path}.${key}`);
}

function strings(v: unknown, path: string): string[] {
  return v === undefined ? [] : arr(v, path).map((s, i) => str(s, `${path}[${String(i)}]`));
}

function rect(v: unknown, path: string): Rect {
  const a = arr(v, path);
  if (a.length !== 4) fail(path, "expected four numbers");
  const [x, y, w, h] = a.map((n, i) => num(n, `${path}[${String(i)}]`));
  return [x ?? 0, y ?? 0, w ?? 0, h ?? 0];
}

function entries(v: unknown, path: string): [string, unknown][] {
  return Object.entries(obj(v, path));
}

function placement(v: unknown, path: string): Placement {
  const o = obj(v, path);
  const p: Placement = { frame: rect(own(o, "frame"), `${path}.frame`), depth: int(own(o, "depth"), `${path}.depth`, 0) };
  if (own(o, "text") !== undefined) p.text = rect(own(o, "text"), `${path}.text`);
  const parent = optStr(o, "parent", path);
  if (parent !== undefined) p.parent = parent;
  if (own(o, "hidden") !== undefined) p.hidden = int(own(o, "hidden"), `${path}.hidden`, 1);
  if (own(o, "badge") !== undefined) p.badge = rect(own(o, "badge"), `${path}.badge`);
  return p;
}

function layout(v: unknown, path: string): Layout {
  const o = obj(v, path);
  const topics = new Map<string, Placement>();
  for (const [id, p] of entries(own(o, "topics"), `${path}.topics`)) topics.set(id, placement(p, `${path}.topics.${id}`));
  const zones = own(o, "zones") === undefined ? [] : arr(own(o, "zones"), `${path}.zones`).map((z, i) => {
    const zp = `${path}.zones[${String(i)}]`;
    const zo = obj(z, zp);
    return { id: str(own(zo, "id"), `${zp}.id`), title: str(own(zo, "title"), `${zp}.title`), frame: rect(own(zo, "frame"), `${zp}.frame`) };
  });
  return { svg: str(own(o, "svg"), `${path}.svg`), viewBox: rect(own(o, "viewBox"), `${path}.viewBox`), topics, zones };
}

const linkKinds: readonly LinkKind[] = ["web", "mail", "topic", "file", "other"];

function link(v: unknown, path: string): Link {
  const o = obj(v, path);
  const kind = str(own(o, "kind"), `${path}.kind`);
  if (!(linkKinds as readonly string[]).includes(kind)) fail(`${path}.kind`, "unknown link kind");
  const l: Link = { href: str(own(o, "href"), `${path}.href`), kind: kind as LinkKind };
  const canvas = optStr(o, "canvas", path);
  const topic = optStr(o, "topic", path);
  if (canvas !== undefined) l.canvas = canvas;
  if (topic !== undefined) l.topic = topic;
  return l;
}

function topic(v: unknown, path: string): Topic {
  const o = obj(v, path);
  const t: Topic = {
    text: str(own(o, "text"), `${path}.text`),
    label: str(own(o, "label"), `${path}.label`),
    comments: (own(o, "comments") === undefined ? [] : arr(own(o, "comments"), `${path}.comments`)).map((c, i) => {
      const cp = `${path}.comments[${String(i)}]`;
      const co = obj(c, cp);
      return { author: str(own(co, "author"), `${cp}.author`), date: str(own(co, "date"), `${cp}.date`), text: str(own(co, "text"), `${cp}.text`) };
    }),
    attachments: (own(o, "attachments") === undefined ? [] : arr(own(o, "attachments"), `${path}.attachments`)).map((a, i) => {
      const ap = `${path}.attachments[${String(i)}]`;
      const ao = obj(a, ap);
      const att: Attachment = { name: str(own(ao, "name"), `${ap}.name`) };
      if (own(ao, "size") !== undefined) att.size = int(own(ao, "size"), `${ap}.size`, 0);
      const asset = optStr(ao, "asset", ap);
      if (asset !== undefined) att.asset = asset;
      return att;
    }),
    labels: strings(own(o, "labels"), `${path}.labels`),
    markers: strings(own(o, "markers"), `${path}.markers`),
    fields: (own(o, "fields") === undefined ? [] : arr(own(o, "fields"), `${path}.fields`)).map((f, i) => {
      const fp = `${path}.fields[${String(i)}]`;
      const fo = obj(f, fp);
      return { key: str(own(fo, "key"), `${fp}.key`), value: str(own(fo, "value"), `${fp}.value`) };
    }),
  };
  for (const key of ["type", "note", "task"] as const) {
    const s = optStr(o, key, path);
    if (s !== undefined) t[key] = s;
  }
  if (own(o, "link") !== undefined) t.link = link(own(o, "link"), `${path}.link`);
  return t;
}

function outlineItem(v: unknown, path: string, depth: number): OutlineItem {
  if (depth > 256) fail(path, "outline too deep");
  const o = obj(v, path);
  const children = own(o, "children") === undefined ? [] : arr(own(o, "children"), `${path}.children`);
  return {
    id: str(own(o, "id"), `${path}.id`),
    children: children.map((c, i) => outlineItem(c, `${path}.children[${String(i)}]`, depth + 1)),
    folded: own(o, "folded") === true,
  };
}

const colour = /^#[0-9A-F]{6}$/;

function theme(v: unknown, path: string): Theme {
  const o = obj(v, path);
  const c = (key: string): string => {
    const s = str(own(o, key), `${path}.${key}`);
    if (!colour.test(s)) fail(`${path}.${key}`, "expected #RRGGBB");
    return s;
  };
  return { canvas: c("canvas"), ink: c("ink"), ink2: c("ink2"), accent: c("accent"), dark: own(o, "dark") === true };
}

function canvas(v: unknown, path: string): Canvas {
  const o = obj(v, path);
  const layouts = obj(own(o, "layouts"), `${path}.layouts`);
  const topics = new Map<string, Topic>();
  for (const [id, t] of entries(own(o, "topics"), `${path}.topics`)) topics.set(id, topic(t, `${path}.topics.${id}`));
  const c: Canvas = {
    id: str(own(o, "id"), `${path}.id`),
    title: str(own(o, "title"), `${path}.title`),
    type: str(own(o, "type"), `${path}.type`),
    typeName: str(own(o, "typeName"), `${path}.typeName`),
    theme: theme(own(o, "theme"), `${path}.theme`),
    layouts: { saved: layout(own(layouts, "saved"), `${path}.layouts.saved`) },
    outline: arr(own(o, "outline"), `${path}.outline`).map((item, i) => outlineItem(item, `${path}.outline[${String(i)}]`, 0)),
    topics,
  };
  if (own(layouts, "expanded") !== undefined) c.layouts.expanded = layout(own(layouts, "expanded"), `${path}.layouts.expanded`);
  if (own(o, "legend") !== undefined) {
    const lo = obj(own(o, "legend"), `${path}.legend`);
    c.legend = {
      title: str(own(lo, "title"), `${path}.legend.title`),
      rows: arr(own(lo, "rows"), `${path}.legend.rows`).map((r, i) => {
        const rp = `${path}.legend.rows[${String(i)}]`;
        const ro = obj(r, rp);
        const row: { text: string; marker?: string } = { text: str(own(ro, "text"), `${rp}.text`) };
        const marker = optStr(ro, "marker", rp);
        if (marker !== undefined) row.marker = marker;
        return row;
      }),
    };
  }
  if (own(o, "threats") !== undefined) {
    const to = obj(own(o, "threats"), `${path}.threats`);
    c.threats = {
      columns: strings(own(to, "columns"), `${path}.threats.columns`),
      rows: arr(own(to, "rows"), `${path}.threats.rows`).map((r, i) => strings(r, `${path}.threats.rows[${String(i)}]`)),
    };
  }
  if (own(o, "deck") !== undefined) c.deck = deck(own(o, "deck"), `${path}.deck`);
  return c;
}

function deck(v: unknown, path: string): Deck {
  const o = obj(v, path);
  const move = str(own(o, "move"), `${path}.move`);
  if (move !== "cut" && move !== "glide" && move !== "fly") fail(`${path}.move`, "expected cut, glide or fly");
  const aspect = num(own(o, "aspect"), `${path}.aspect`);
  if (aspect <= 0) fail(`${path}.aspect`, "expected a positive number");
  const slides = arr(own(o, "slides"), `${path}.slides`).map((s, i) => {
    const sp = `${path}.slides[${String(i)}]`;
    const so = obj(s, sp);
    const slide: Slide = {
      kicker: str(own(so, "kicker"), `${sp}.kicker`),
      title: str(own(so, "title"), `${sp}.title`),
      focus: strings(own(so, "focus"), `${sp}.focus`),
      highlight: strings(own(so, "highlight"), `${sp}.highlight`),
    };
    const note = optStr(so, "note", sp);
    if (note !== undefined) slide.note = note;
    return slide;
  });
  return { move, aspect, slides };
}

/** Reads a bundle from its JSON text; throws `BundleError` naming the first bad field. */
export function parseBundle(text: string): Bundle {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    fail("$", "not JSON");
  }
  const o = obj(raw, "$");
  if (own(o, "format") !== "opennexus-viewer") fail("$.format", "not an OpenNexus viewer bundle");
  if (own(o, "version") !== 1) fail("$.version", "unsupported version");
  const canvases = arr(own(o, "canvases"), "$.canvases").map((c, i) => canvas(c, `$.canvases[${String(i)}]`));
  if (canvases.length === 0) fail("$.canvases", "no canvases");
  const strs = new Map<string, string>();
  if (own(o, "strings") !== undefined) {
    for (const [k, s] of entries(own(o, "strings"), "$.strings")) strs.set(k, str(s, `$.strings.${k}`));
  }
  const assets = new Map<string, Asset>();
  for (const [name, a] of entries(own(o, "assets"), "$.assets")) {
    const ap = `$.assets.${name}`;
    const ao = obj(a, ap);
    const asset: Asset = { type: str(own(ao, "type"), `${ap}.type`), size: int(own(ao, "size"), `${ap}.size`, 0) };
    const data = optStr(ao, "data", ap);
    if (data !== undefined) asset.data = data;
    assets.set(name, asset);
  }
  return { title: str(own(o, "title"), "$.title"), lang: optStr(o, "lang", "$") ?? "en", strings: strs, canvases, assets };
}
