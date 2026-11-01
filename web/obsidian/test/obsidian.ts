// A stand-in for Obsidian's API (M49, A1), as much of it as the plugin uses. It keeps what
// the plugin registers (views, extensions, code blocks, commands, settings, protocol
// handlers, event listeners) in the App, and takes each away when its component unloads,
// as Obsidian does, so the tests can check that unloading leaves nothing behind.

/* eslint-disable @typescript-eslint/no-unused-vars, @typescript-eslint/no-empty-function, @typescript-eslint/no-extraneous-class -- the API as Obsidian shapes it */

export type IconName = string;

export const Platform = { isDesktopApp: true, isMacOS: true, isMobile: false };

export function normalizePath(p: string): string {
  return p.replace(/\\/g, "/").replace(/\/+/g, "/").replace(/^\/|\/$/g, "");
}

export interface EventRef {
  owner: Events;
  name: string;
  fn: (...args: never[]) => unknown;
}

export class Events {
  readonly handlers = new Map<string, Set<(...args: never[]) => unknown>>();
  on(name: string, fn: (...args: never[]) => unknown): EventRef {
    let set = this.handlers.get(name);
    if (set === undefined) this.handlers.set(name, (set = new Set()));
    set.add(fn);
    return { owner: this, name, fn };
  }
  offref(ref: EventRef): void {
    this.handlers.get(ref.name)?.delete(ref.fn);
  }
  trigger(name: string, ...args: unknown[]): void {
    for (const fn of [...(this.handlers.get(name) ?? [])]) (fn as (...a: unknown[]) => unknown)(...args);
  }
  /** Listeners still attached. */
  listeners(): number {
    let n = 0;
    for (const s of this.handlers.values()) n += s.size;
    return n;
  }
}

export class Component {
  _loaded = false;
  private children: Component[] = [];
  private cleanups: (() => void)[] = [];
  load(): void {
    if (this._loaded) return;
    this._loaded = true;
    void this.onload();
    for (const c of this.children) c.load();
  }
  onload(): void | Promise<void> {}
  unload(): void {
    if (!this._loaded) return;
    this._loaded = false;
    for (const c of this.children.reverse()) c.unload();
    this.children = [];
    this.onunload();
    for (const f of this.cleanups.reverse()) f();
    this.cleanups = [];
  }
  onunload(): void {}
  addChild<T extends Component>(c: T): T {
    this.children.push(c);
    if (this._loaded) c.load();
    return c;
  }
  register(cb: () => unknown): void {
    this.cleanups.push(() => { cb(); });
  }
  registerEvent(ref: EventRef): void {
    this.register(() => { ref.owner.offref(ref); });
  }
  registerDomEvent(el: EventTarget, type: string, cb: EventListener): void {
    el.addEventListener(type, cb);
    this.register(() => { el.removeEventListener(type, cb); });
  }
  registerInterval(id: number): number {
    this.register(() => { window.clearInterval(id); });
    return id;
  }
}

export class TAbstractFile {
  vault!: Vault;
  parent: TFolder | null = null;
  constructor(
    public path: string,
    public name = path.split("/").pop() ?? path,
  ) {}
}

export class TFile extends TAbstractFile {
  get extension(): string {
    return this.name.includes(".") ? (this.name.split(".").pop() ?? "") : "";
  }
  get basename(): string {
    return this.name.replace(/\.[^.]*$/, "");
  }
}

export class TFolder extends TAbstractFile {
  children: TAbstractFile[] = [];
}

/** A vault in memory: path → text or bytes. */
export class FileSystemAdapter {
  constructor(readonly files: Map<string, string | Uint8Array>) {}
  getBasePath(): string {
    return "/vault";
  }
  getFullPath(p: string): string {
    return `/vault/${p}`;
  }
  list(dir: string): Promise<{ files: string[]; folders: string[] }> {
    const files: string[] = [];
    const folders = new Set<string>();
    for (const p of this.files.keys()) {
      if (!p.startsWith(`${dir}/`)) continue;
      const rest = p.slice(dir.length + 1);
      if (rest.includes("/")) folders.add(`${dir}/${rest.split("/")[0] ?? ""}`);
      else files.push(p);
    }
    return Promise.resolve({ files, folders: [...folders] });
  }
  readBinary(p: string): Promise<ArrayBuffer> {
    const v = this.files.get(p);
    if (v === undefined) return Promise.reject(new Error(`no ${p}`));
    const bytes = typeof v === "string" ? new TextEncoder().encode(v) : v;
    return Promise.resolve(bytes.slice().buffer);
  }
}

export class Vault extends Events {
  readonly adapter: FileSystemAdapter;
  constructor(readonly files: Map<string, string | Uint8Array>) {
    super();
    this.adapter = new FileSystemAdapter(files);
  }
  getName(): string {
    return "Test vault";
  }
  getAbstractFileByPath(path: string): TAbstractFile | null {
    if (this.files.has(path)) return new TFile(path);
    if ([...this.files.keys()].some((p) => p.startsWith(`${path}/`))) return new TFolder(path);
    return null;
  }
  getFileByPath(path: string): TFile | null {
    return this.files.has(path) ? new TFile(path) : null;
  }
  getAllLoadedFiles(): TAbstractFile[] {
    const out: TAbstractFile[] = [];
    const folders = new Set<string>();
    for (const p of this.files.keys()) {
      out.push(new TFile(p));
      const parts = p.split("/");
      for (let i = 1; i < parts.length; i++) folders.add(parts.slice(0, i).join("/"));
    }
    return [...out, ...[...folders].map((f) => new TFolder(f))];
  }
  read(f: TFile): Promise<string> {
    const v = this.files.get(f.path);
    return Promise.resolve(typeof v === "string" ? v : new TextDecoder().decode(v));
  }
  cachedRead(f: TFile): Promise<string> {
    return this.read(f);
  }
}

export class WorkspaceLeaf {
  view: View | undefined;
  constructor(readonly app: App) {}
  async setViewState(state: { type: string; state?: unknown }): Promise<void> {
    const factory = this.app.views.get(state.type);
    if (factory === undefined) throw new Error(`no view ${state.type}`);
    this.view?.unload();
    this.view = factory(this);
    this.app.workspace.leaves.add(this);
    this.view.load();
    await this.view.setState(state.state ?? {}, { history: false });
  }
  async openFile(f: TFile): Promise<void> {
    const type = this.app.extensions.get(f.extension) ?? "markdown";
    await this.setViewState({ type, state: { file: f.path } });
  }
  detach(): void {
    this.view?.unload();
    this.app.workspace.leaves.delete(this);
  }
}

export class Workspace extends Events {
  readonly leaves = new Set<WorkspaceLeaf>();
  active: View | undefined;
  opened: string[] = [];
  constructor(readonly app: App) {
    super();
  }
  getLeavesOfType(type: string): WorkspaceLeaf[] {
    return [...this.leaves].filter((l) => l.view?.getViewType() === type);
  }
  getActiveViewOfType<T>(type: abstract new (...a: never[]) => T): T | null {
    return this.active instanceof type ? (this.active) : null;
  }
  getLeaf(): WorkspaceLeaf {
    return new WorkspaceLeaf(this.app);
  }
  revealLeaf(): Promise<void> {
    return Promise.resolve();
  }
  openLinkText(link: string): Promise<void> {
    this.opened.push(link);
    return Promise.resolve();
  }
}

export class MetadataCache extends Events {
  constructor(private readonly vault: Vault) {
    super();
  }
  getFirstLinkpathDest(link: string): TFile | null {
    for (const p of [link, `${link}.md`]) if (this.vault.files.has(p)) return new TFile(p);
    const byName = [...this.vault.files.keys()].find((p) => p.endsWith(`/${link}.md`) || p.endsWith(`/${link}`));
    return byName === undefined ? null : new TFile(byName);
  }
}

export interface Command {
  id: string;
  name: string;
  checkCallback?: (checking: boolean) => boolean | undefined;
  editorCallback?: (editor: unknown, view: unknown) => unknown;
}

export class App {
  readonly vault: Vault;
  readonly workspace: Workspace;
  readonly metadataCache: MetadataCache;
  readonly views = new Map<string, (leaf: WorkspaceLeaf) => View>();
  readonly extensions = new Map<string, string>();
  readonly codeBlocks = new Map<string, (source: string, el: HTMLElement, ctx: { sourcePath: string; addChild: (c: Component) => void }) => unknown>();
  readonly commands = new Map<string, Command>();
  readonly settingTabs = new Set<PluginSettingTab>();
  readonly protocol = new Map<string, (params: Record<string, string>) => unknown>();
  data: unknown;
  constructor(files: Record<string, string | Uint8Array> = {}) {
    this.vault = new Vault(new Map(Object.entries(files)));
    this.workspace = new Workspace(this);
    this.metadataCache = new MetadataCache(this.vault);
  }
}

export interface PluginManifest {
  id: string;
  name: string;
  version: string;
}

export class Plugin extends Component {
  constructor(
    readonly app: App,
    readonly manifest: PluginManifest,
  ) {
    super();
  }
  registerView(type: string, factory: (leaf: WorkspaceLeaf) => View): void {
    this.app.views.set(type, factory);
    this.register(() => {
      // Obsidian closes a plugin's views when it unloads.
      for (const l of this.app.workspace.getLeavesOfType(type)) l.detach();
      this.app.views.delete(type);
    });
  }
  registerExtensions(extensions: string[], type: string): void {
    for (const e of extensions) this.app.extensions.set(e, type);
    this.register(() => { for (const e of extensions) this.app.extensions.delete(e); });
  }
  registerMarkdownCodeBlockProcessor(lang: string, handler: App["codeBlocks"] extends Map<string, infer H> ? H : never): void {
    this.app.codeBlocks.set(lang, handler);
    this.register(() => this.app.codeBlocks.delete(lang));
  }
  registerObsidianProtocolHandler(action: string, handler: (params: Record<string, string>) => unknown): void {
    this.app.protocol.set(action, handler);
    this.register(() => this.app.protocol.delete(action));
  }
  addCommand(c: Command): Command {
    this.app.commands.set(c.id, c);
    this.register(() => this.app.commands.delete(c.id));
    return c;
  }
  addSettingTab(tab: PluginSettingTab): void {
    this.app.settingTabs.add(tab);
    this.register(() => this.app.settingTabs.delete(tab));
  }
  loadData(): Promise<unknown> {
    return Promise.resolve(this.app.data);
  }
  saveData(data: unknown): Promise<void> {
    this.app.data = data;
    return Promise.resolve();
  }
}

export interface ViewStateResult {
  history: boolean;
}

export abstract class View extends Component {
  readonly containerEl: HTMLElement;
  navigation = false;
  readonly app: App;
  constructor(readonly leaf: WorkspaceLeaf) {
    super();
    this.app = leaf.app;
    this.containerEl = document.createElement("div");
  }
  abstract getViewType(): string;
  getDisplayText(): string {
    return "";
  }
  getIcon(): string {
    return "";
  }
  setState(_state: unknown, _result: ViewStateResult): Promise<void> {
    return Promise.resolve();
  }
  getState(): Record<string, unknown> {
    return {};
  }
}

export abstract class ItemView extends View {
  readonly contentEl: HTMLElement;
  readonly actions: string[] = [];
  constructor(leaf: WorkspaceLeaf) {
    super(leaf);
    this.contentEl = document.createElement("div");
    this.containerEl.append(this.contentEl);
    document.body.append(this.containerEl);
  }
  addAction(_icon: string, title: string, _cb: (e: MouseEvent) => unknown): HTMLElement {
    this.actions.push(title);
    return document.createElement("div");
  }
  override onunload(): void {
    this.containerEl.remove();
  }
}

export abstract class FileView extends ItemView {
  file: TFile | null = null;
  allowNoFile = false;
  override async setState(state: unknown, result: ViewStateResult): Promise<void> {
    const path = (state as { file?: unknown }).file;
    if (typeof path === "string") {
      this.file = new TFile(path);
      await this.onLoadFile(this.file);
    }
    await super.setState(state, result);
  }
  onLoadFile(_file: TFile): Promise<void> {
    return Promise.resolve();
  }
  onUnloadFile(_file: TFile): Promise<void> {
    return Promise.resolve();
  }
  onRename(_file: TFile): Promise<void> {
    return Promise.resolve();
  }
  canAcceptExtension(_extension: string): boolean {
    return false;
  }
}

export class MarkdownView extends ItemView {
  file: TFile | null = null;
  editor = {
    value: "",
    cursor: { line: 0, ch: 0 },
    getValue(): string {
      return this.value;
    },
    setCursor(p: { line: number; ch: number }): void {
      this.cursor = p;
    },
    lineCount(): number {
      return this.value.split("\n").length;
    },
    scrollIntoView(): void {},
    replaceSelection(text: string): void {
      this.value += text;
    },
  };
  getViewType(): string {
    return "markdown";
  }
  save(): Promise<void> {
    return Promise.resolve();
  }
}

export type Editor = MarkdownView["editor"];

export class MarkdownRenderChild extends Component {
  constructor(readonly containerEl: HTMLElement) {
    super();
  }
}

export class PluginSettingTab {
  readonly containerEl = document.createElement("div");
  constructor(
    readonly app: App,
    readonly plugin: Plugin,
  ) {}
  display(): void {}
}

class Control<T> {
  value: T;
  readonly inputEl = document.createElement("input");
  constructor(v: T) {
    this.value = v;
  }
  setValue(v: T): this {
    this.value = v;
    return this;
  }
  setPlaceholder(_p: string): this {
    return this;
  }
  addOptions(_o: Record<string, string>): this {
    return this;
  }
  onChange(_cb: (v: T) => unknown): this {
    return this;
  }
}

export class Setting {
  readonly settingEl = document.createElement("div");
  constructor(containerEl: HTMLElement) {
    containerEl.append(this.settingEl);
  }
  setName(name: string): this {
    this.settingEl.dataset.name = name;
    return this;
  }
  setDesc(_d: string): this {
    return this;
  }
  addText(cb: (c: Control<string>) => unknown): this {
    cb(new Control(""));
    return this;
  }
  addDropdown(cb: (c: Control<string>) => unknown): this {
    cb(new Control(""));
    return this;
  }
  addToggle(cb: (c: Control<boolean>) => unknown): this {
    cb(new Control(false));
    return this;
  }
}

export const notices: string[] = [];

export class Notice {
  constructor(message: string) {
    notices.push(message);
  }
}

export abstract class FuzzySuggestModal<T> {
  constructor(readonly app: App) {}
  setPlaceholder(_p: string): void {}
  abstract getItems(): T[];
  abstract getItemText(item: T): string;
  abstract onChooseItem(item: T): void;
  open(): void {}
}

export class Menu {
  readonly items: { title: string; click: () => unknown }[] = [];
  addItem(cb: (item: { setTitle: (t: string) => unknown; setIcon: (i: string) => unknown; onClick: (f: () => unknown) => unknown }) => unknown): this {
    const entry = { title: "", click: (): unknown => undefined };
    const item = {
      setTitle: (t: string) => { entry.title = t; return item; },
      setIcon: () => item,
      onClick: (f: () => unknown) => { entry.click = f; return item; },
    };
    cb(item);
    this.items.push(entry);
    return this;
  }
}
