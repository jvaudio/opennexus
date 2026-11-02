// Embeds (M49): a ```nexus block draws a map in Reading view and Live Preview, the map alone
// with its pan and zoom and an Open link. Each starts only when it's scrolled into view, so
// long notes stay smooth, and is torn down with its section. Obsidian's own embed registry
// isn't public API, so it isn't used.
//
//     ```nexus
//     file: Plans/Launch.nexusjson
//     canvas: Roadmap
//     topic: Launch plan > Pricing
//     layout: expanded
//     height: 360
//     ```

import { MarkdownRenderChild, normalizePath, type App } from "obsidian";
import type { Host } from "./host";
import { hostLinks } from "./links";
import { isPackage, mapAt, openMap, sourcePath, type MapSource } from "./maps";
import { MapPanel } from "./panel";
import { clampHeight, type LayoutName } from "./settings";

export interface EmbedOptions {
  file: string;
  canvas?: string;
  topic?: string;
  layout?: LayoutName;
  height?: number;
}

/** A block's options, or what's wrong with it. */
export function parseEmbed(source: string): EmbedOptions | { error: string } {
  const o: Partial<EmbedOptions> = {};
  for (const raw of source.split("\n")) {
    const line = raw.trim();
    if (line === "" || line.startsWith("#") || line.startsWith("//")) continue;
    const m = /^([A-Za-z]+)\s*:\s*(.*)$/.exec(line);
    if (m === null) return { error: `“${line}” isn’t “key: value”.` };
    const key = (m[1] ?? "").toLowerCase();
    let value = (m[2] ?? "").trim().replace(/^(["'])(.*)\1$/, "$2");
    const wiki = /^\[\[([^[\]|]+)(?:\|[^[\]]*)?\]\]$/.exec(value);
    if (wiki?.[1] !== undefined) value = wiki[1].trim();
    switch (key) {
      case "file":
        o.file = value;
        break;
      case "canvas":
        o.canvas = value;
        break;
      case "topic":
        o.topic = value;
        break;
      case "layout": {
        const l = value.toLowerCase();
        if (l === "saved" || l === "as saved") o.layout = "saved";
        else if (l === "expanded" || l === "everything") o.layout = "expanded";
        else return { error: `layout is “saved” or “expanded”, not “${value}”.` };
        break;
      }
      case "height": {
        const n = Number(value.replace(/px$/i, ""));
        if (!Number.isFinite(n) || n <= 0) return { error: `height is a number of pixels, not “${value}”.` };
        o.height = clampHeight(n);
        break;
      }
      default:
        return { error: `There’s no “${key}”: use file, canvas, topic, layout and height.` };
    }
  }
  if (o.file === undefined || o.file === "") return { error: "Name the map with “file: Folder/Map.nexusjson”." };
  return o as EmbedOptions;
}

/** The map a block names: a link to a file, a vault path, a path beside the note, or a package's name; with or without its extension. */
export function resolveMap(app: App, ref: string, from: string): MapSource | undefined {
  const dir = from.includes("/") ? from.slice(0, from.lastIndexOf("/")) : "";
  for (const name of [ref, `${ref}.nexusjson`, `${ref}.nexus`]) {
    const linked = app.metadataCache.getFirstLinkpathDest(name, from);
    const s = (linked === null ? undefined : mapAt(app, linked.path)) ?? mapAt(app, name) ?? (dir === "" ? undefined : mapAt(app, normalizePath(`${dir}/${name}`)));
    if (s !== undefined) return s;
  }
  // Links don't reach folders, so a package is also found by its name anywhere in the vault.
  const name = ref.split("/").pop()?.toLowerCase() ?? "";
  const pkg = app.vault
    .getAllLoadedFiles()
    .filter(isPackage)
    .sort((a, b) => a.path.localeCompare(b.path))
    .find((f) => f.name.toLowerCase() === name || f.name.toLowerCase() === `${name}.nexus`);
  return pkg === undefined ? undefined : { kind: "package", folder: pkg };
}

export class EmbedChild extends MarkdownRenderChild {
  readonly panel: MapPanel;
  /** Whether it has started (been scrolled into view). */
  started = false;
  private path = "";
  private timer: number | undefined;
  private generation = 0;
  private readonly options: EmbedOptions | { error: string };

  constructor(
    containerEl: HTMLElement,
    private readonly host: Host,
    source: string,
    private readonly sourcePath: string,
    private readonly onDone: (e: EmbedChild) => void,
  ) {
    super(containerEl);
    this.options = parseEmbed(source);
    containerEl.classList.add("opennexus-embed");
    this.panel = new MapPanel(containerEl.appendChild(containerEl.ownerDocument.createElement("div")));
  }

  override onload(): void {
    const el = this.containerEl;
    const o = this.options;
    if ("error" in o) {
      el.classList.add("opennexus-embed-error");
      const p = el.ownerDocument.createElement("p");
      p.className = "opennexus-message";
      p.textContent = `OpenNexus embed: ${o.error}`;
      this.panel.el.replaceChildren(p);
      return;
    }
    el.style.setProperty("--opennexus-embed-height", `${String(o.height ?? this.host.settings.embedHeight)}px`);
    el.dataset.opennexusFile = o.file;
    const label = el.ownerDocument.createElement("p");
    label.className = "opennexus-embed-placeholder";
    label.textContent = o.file;
    this.panel.el.replaceChildren(label);
    if (typeof IntersectionObserver === "undefined") {
      void this.start();
    } else {
      const seen = new IntersectionObserver(
        (entries) => {
          if (!entries.some((e) => e.isIntersecting)) return;
          seen.disconnect();
          void this.start();
        },
        { rootMargin: "200px 0px" },
      );
      seen.observe(el);
      this.register(() => { seen.disconnect(); });
    }
    const vault = this.host.app.vault;
    for (const name of ["modify", "create", "delete"] as const) {
      this.registerEvent(vault.on(name as "modify", (f) => { this.changed(f.path); }));
    }
  }

  override onunload(): void {
    window.clearTimeout(this.timer);
    this.generation++;
    this.panel.clear();
    this.onDone(this);
  }

  /** Draws the map (on first sight, and again when it changes). */
  async start(keep = false): Promise<void> {
    const o = this.options;
    if ("error" in o) return;
    this.started = true;
    const generation = ++this.generation;
    const app = this.host.app;
    const source = resolveMap(app, o.file, this.sourcePath);
    if (source === undefined) {
      const p = this.panel.el.ownerDocument.createElement("p");
      p.className = "opennexus-message";
      p.textContent = `OpenNexus embed: there’s no map “${o.file}” in this vault.`;
      this.panel.clear();
      this.panel.el.append(p);
      return;
    }
    this.path = sourcePath(source);
    const opened = await openMap(app, source, await this.host.nexus());
    if (generation !== this.generation) {
      if (opened.kind === "bundle") opened.close();
      return;
    }
    const s = this.host.settings;
    const place = { file: this.path, ...(o.canvas === undefined ? {} : { canvas: o.canvas }), ...(o.topic === undefined ? {} : { topic: o.topic }) };
    this.panel.show(
      opened,
      {
        chrome: "none",
        layout: o.layout ?? s.layout,
        followTheme: s.followTheme,
        hostLinks: hostLinks(app, this.path, (t) => void this.host.openTopic(t)),
        actions: [{ label: "Open", run: () => void this.host.openTopic(place) }],
      },
      keep ? this.panel.keep() : undefined,
    );
    if (!keep) this.panel.goTo(place, "focus");
    this.containerEl.dataset.opennexusReady = "true";
  }

  private changed(path: string): void {
    if (!this.started || this.path === "" || (path !== this.path && !path.startsWith(`${this.path}/`))) return;
    window.clearTimeout(this.timer);
    this.timer = window.setTimeout(() => void this.start(true), 150);
  }
}
