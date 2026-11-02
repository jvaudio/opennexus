// The map views (M49): a `.nexusjson` file opens in one (registerExtensions), and a `.nexus`
// folder from its folder menu (Obsidian shows packages as folders). Read-only: Edit in
// OpenNexus hands the map to the app, and the view redraws when the app saves, keeping its
// canvas and camera.

import { FileView, ItemView, Notice, type TFile, type ViewStateResult, type WorkspaceLeaf } from "obsidian";
import type { Host } from "./host";
import { hostLinks, topicLink, type TopicTarget } from "./links";
import { fullPath, mapAt, openMap } from "./maps";
import { canRunApp, openInApp } from "./nexus";
import { MapPanel, type Place } from "./panel";

export const VIEW_MAP = "opennexus-map";
export const VIEW_PACKAGE = "opennexus-package";
export const ICON = "git-fork";
/** How long a burst of vault changes (an app's save writes several files) settles. */
export const SETTLE_MS = 150;

/** A view's map: what it shows, and redrawing it when the vault changes under it. */
export class MapController {
  readonly panel: MapPanel;
  path = "";
  selection: { canvas: string; topic: string | null } | undefined;
  /** Resolves when the latest open has drawn. */
  ready: Promise<void> = Promise.resolve();
  /** How many times the map has been drawn (the tests watch it). */
  draws = 0;
  private timer: number | undefined;
  private generation = 0;

  constructor(
    private readonly view: ItemView,
    private readonly host: Host,
  ) {
    const el = view.contentEl;
    el.classList.add("opennexus-view");
    this.panel = new MapPanel(el.appendChild(el.ownerDocument.createElement("div")));
  }

  /** Listens to the vault; called from the view's onload so it's undone with the view. */
  wire(): void {
    const vault = this.host.app.vault;
    for (const name of ["modify", "create", "delete"] as const) {
      this.view.registerEvent(vault.on(name as "modify", (f) => { this.changed(f.path); }));
    }
    this.view.registerEvent(
      vault.on("rename", (f, old) => {
        if (old === this.path) this.path = f.path;
        else this.changed(f.path);
      }),
    );
    this.view.register(() => {
      window.clearTimeout(this.timer);
      this.generation++;
      this.panel.clear();
    });
  }

  /** Opens the map at `path`; `keep` holds the canvas and camera (a redraw). */
  open(path: string, keep = false): Promise<void> {
    this.path = path;
    const generation = ++this.generation;
    this.ready = this.draw(generation, keep);
    return this.ready;
  }

  private async draw(generation: number, keep: boolean): Promise<void> {
    const app = this.host.app;
    const source = mapAt(app, this.path);
    if (source === undefined) return;
    const tool = await this.host.nexus();
    const opened = await openMap(app, source, tool);
    if (generation !== this.generation) {
      if (opened.kind === "bundle") opened.close();
      return;
    }
    const s = this.host.settings;
    this.panel.show(
      opened,
      {
        chrome: "full",
        layout: s.layout,
        followTheme: s.followTheme,
        hostLinks: hostLinks(app, this.path, (t) => void this.host.openTopic(t)),
        onSelect: (canvas, topic) => { this.selection = { canvas, topic }; },
        canDraw: canRunApp() && tool === undefined,
      },
      keep ? this.panel.keep() : undefined,
    );
    this.draws++;
    this.view.contentEl.dataset.opennexusDraws = String(this.draws);
  }

  /** A vault change: redraws once things settle if it's this map or inside its package. */
  changed(path: string): void {
    if (this.path === "" || (path !== this.path && !path.startsWith(`${this.path}/`))) return;
    window.clearTimeout(this.timer);
    this.timer = window.setTimeout(() => void this.open(this.path, true), SETTLE_MS);
  }

  goTo(place: Place): boolean {
    return this.panel.goTo(place, "select");
  }

  /** The `obsidian://opennexus` link to the selected topic (or the canvas). */
  topicLink(): string | undefined {
    if (this.selection === undefined) return undefined;
    const t: TopicTarget = { file: this.path, canvas: this.selection.canvas };
    if (this.selection.topic !== null) t.topic = this.selection.topic;
    return topicLink(this.host.app.vault.getName(), t);
  }

  async copyLink(): Promise<void> {
    const link = this.topicLink();
    if (link === undefined) return;
    await navigator.clipboard.writeText(link);
    new Notice(this.selection?.topic === null ? "Copied a link to this canvas." : "Copied a link to this topic.");
  }

  async editInApp(): Promise<void> {
    const path = fullPath(this.host.app, this.path);
    if (path === undefined) return;
    const r = await openInApp(path);
    if (r.code !== 0) new Notice("OpenNexus isn’t installed on this Mac.");
  }

  /** The view's header buttons. */
  addActions(): void {
    if (canRunApp()) this.view.addAction("pencil", "Edit in OpenNexus", () => void this.editInApp());
    this.view.addAction("link", "Copy link to topic", () => void this.copyLink());
  }
}

/** Views that show a map. */
export interface MapView {
  readonly map: MapController;
}

export class MapFileView extends FileView implements MapView {
  readonly map: MapController;

  constructor(
    leaf: WorkspaceLeaf,
    readonly host: Host,
  ) {
    super(leaf);
    this.map = new MapController(this, host);
  }

  getViewType(): string {
    return VIEW_MAP;
  }

  override getIcon(): string {
    return ICON;
  }

  override canAcceptExtension(extension: string): boolean {
    return extension.toLowerCase() === "nexusjson";
  }

  override onload(): void {
    super.onload();
    this.map.wire();
    this.map.addActions();
  }

  override async onLoadFile(file: TFile): Promise<void> {
    await this.map.open(file.path);
  }

  override async onUnloadFile(): Promise<void> {
    this.map.panel.clear();
    await Promise.resolve();
  }

  override async onRename(file: TFile): Promise<void> {
    this.map.path = file.path;
    await super.onRename(file);
  }
}

export class PackageView extends ItemView implements MapView {
  readonly map: MapController;

  constructor(
    leaf: WorkspaceLeaf,
    readonly host: Host,
  ) {
    super(leaf);
    this.navigation = true;
    this.map = new MapController(this, host);
  }

  getViewType(): string {
    return VIEW_PACKAGE;
  }

  override getIcon(): string {
    return ICON;
  }

  getDisplayText(): string {
    const name = this.map.path.split("/").pop() ?? "";
    return name === "" ? "OpenNexus map" : name.replace(/\.nexus$/i, "");
  }

  override onload(): void {
    super.onload();
    this.map.wire();
    this.map.addActions();
  }

  override async setState(state: unknown, result: ViewStateResult): Promise<void> {
    const path = (state as { path?: unknown } | null)?.path;
    if (typeof path === "string" && path !== this.map.path) await this.map.open(path);
    await super.setState(state, result);
    // Obsidian sets an item view's header title once, as it loads; the tab follows getDisplayText.
    (this as unknown as { titleEl?: HTMLElement }).titleEl?.setText(this.getDisplayText());
  }

  override getState(): Record<string, unknown> {
    return { ...super.getState(), path: this.map.path };
  }
}
