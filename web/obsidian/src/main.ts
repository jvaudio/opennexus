// OpenNexus for Obsidian (M49): maps live in vaults. A `.nexusjson` file or a `.nexus`
// folder opens read-only in a map view, ```nexus blocks embed maps in notes, links in maps
// open vault notes, Edit in OpenNexus hands a map to the Mac app, and any note can be seen as
// a map. Everything is registered through the plugin, so unloading it leaves nothing behind.
// It makes no network requests.

import { MarkdownView, Notice, Plugin, TFile } from "obsidian";
import { convertNote, insertOutline } from "./convert";
import { EmbedChild } from "./embed";
import type { Host } from "./host";
import { PROTOCOL_ACTION, topicTarget, type TopicTarget } from "./links";
import { isPackage, mapAt } from "./maps";
import { canRunApp, findNexus } from "./nexus";
import { NoteMapView, VIEW_NOTE } from "./notemap";
import { readSettings, SettingsTab, type Settings, type SettingsHost } from "./settings";
import { ICON, MapFileView, PackageView, VIEW_MAP, VIEW_PACKAGE, type MapView } from "./views";

export default class OpenNexusPlugin extends Plugin implements Host, SettingsHost {
  override settings: Settings = readSettings(undefined);
  /** Embeds on screen, unloaded with the plugin. */
  readonly embeds = new Set<EmbedChild>();
  private tool: Promise<string | undefined> | undefined;

  override async onload(): Promise<void> {
    this.settings = readSettings(await this.loadData());

    this.registerView(VIEW_MAP, (leaf) => new MapFileView(leaf, this));
    this.registerView(VIEW_PACKAGE, (leaf) => new PackageView(leaf, this));
    this.registerView(VIEW_NOTE, (leaf) => new NoteMapView(leaf, this));
    this.registerExtensions(["nexusjson"], VIEW_MAP);

    this.registerMarkdownCodeBlockProcessor("nexus", (source, el, ctx) => {
      const embed = new EmbedChild(el, this, source, ctx.sourcePath, (e) => this.embeds.delete(e));
      this.embeds.add(embed);
      ctx.addChild(embed);
    });

    this.registerEvent(
      this.app.workspace.on("file-menu", (menu, file) => {
        if (!isPackage(file)) return;
        menu.addItem((item) =>
          item.setTitle("Open as OpenNexus map").setIcon(ICON).onClick(() => void this.openTopic({ file: file.path })),
        );
      }),
    );

    this.registerObsidianProtocolHandler(PROTOCOL_ACTION, (params) => {
      const t = topicTarget(params);
      if (t.file !== "") void this.openTopic(t);
    });

    this.addCommand({
      id: "edit-in-app",
      name: "Edit in OpenNexus",
      checkCallback: (checking) => {
        const v = this.mapView();
        if (v === undefined || !canRunApp()) return false;
        if (!checking) void v.map.editInApp();
        return true;
      },
    });
    this.addCommand({
      id: "copy-topic-link",
      name: "Copy link to topic",
      checkCallback: (checking) => {
        const v = this.mapView();
        if (v?.map.selection === undefined) return false;
        if (!checking) void v.map.copyLink();
        return true;
      },
    });
    this.addCommand({
      id: "note-as-map",
      name: "Show this note as a map",
      checkCallback: (checking) => {
        const file = this.app.workspace.getActiveViewOfType(MarkdownView)?.file;
        if (file === null || file === undefined) return false;
        if (!checking) void this.showNoteAsMap(file);
        return true;
      },
    });
    this.addCommand({
      id: "convert-note",
      name: "Convert note to OpenNexus map",
      checkCallback: (checking) => {
        const view = this.app.workspace.getActiveViewOfType(MarkdownView);
        if (view?.file == null || !canRunApp()) return false;
        if (!checking) void convertNote(this, view);
        return true;
      },
    });
    this.addCommand({
      id: "insert-outline",
      name: "Insert map as outline",
      editorCallback: (editor) => { insertOutline(this, editor); },
    });

    this.addSettingTab(new SettingsTab(this.app, this));
    this.register(() => {
      for (const e of [...this.embeds]) e.unload();
      this.embeds.clear();
    });
  }

  async saveSettings(): Promise<void> {
    this.tool = undefined;
    await this.saveData(this.settings);
  }

  nexus(): Promise<string | undefined> {
    this.tool ??= findNexus(this.settings.nexusPath);
    return this.tool;
  }

  /** The map view in front, if that's what's in front. */
  mapView(): MapView | undefined {
    return this.app.workspace.getActiveViewOfType(MapFileView) ?? this.app.workspace.getActiveViewOfType(PackageView) ?? undefined;
  }

  async openTopic(t: TopicTarget): Promise<void> {
    const source = mapAt(this.app, t.file);
    if (source === undefined) {
      new Notice(`There’s no map “${t.file}” in this vault.`);
      return;
    }
    const { workspace } = this.app;
    const showing = [...workspace.getLeavesOfType(VIEW_MAP), ...workspace.getLeavesOfType(VIEW_PACKAGE)].find(
      (l) => (l.view as unknown as MapView).map.path === t.file,
    );
    const leaf = showing ?? workspace.getLeaf("tab");
    if (showing === undefined) {
      if (source.kind === "file") await leaf.openFile(source.file);
      else await leaf.setViewState({ type: VIEW_PACKAGE, state: { path: source.folder.path }, active: true });
    }
    await workspace.revealLeaf(leaf);
    const view = leaf.view as unknown as MapView;
    await view.map.ready;
    const place = { ...(t.canvas === undefined ? {} : { canvas: t.canvas }), ...(t.topic === undefined ? {} : { topic: t.topic }) };
    if (place.canvas !== undefined || place.topic !== undefined) view.map.goTo(place);
  }

  async showNoteAsMap(file: TFile): Promise<void> {
    const { workspace } = this.app;
    const existing = workspace.getLeavesOfType(VIEW_NOTE).find((l) => (l.view as NoteMapView).path === file.path);
    const leaf = existing ?? workspace.getLeaf("split", "vertical");
    if (existing === undefined) await leaf.setViewState({ type: VIEW_NOTE, state: { path: file.path }, active: false });
    await workspace.revealLeaf(leaf);
  }
}
