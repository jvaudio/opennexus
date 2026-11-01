// The plugin's settings and their tab (M49): the `nexus` tool, the layout maps open in, how
// tall embeds are, and whether the viewer's chrome takes Obsidian's theme.

import { PluginSettingTab, Setting, type App, type Plugin } from "obsidian";
import { canRunApp } from "./nexus";

export type LayoutName = "saved" | "expanded";

export interface Settings {
  /** The `nexus` tool; empty finds it in OpenNexus. */
  nexusPath: string;
  layout: LayoutName;
  /** Embeds' height in pixels when a block doesn't give one. */
  embedHeight: number;
  /** The bar, outline and details use Obsidian's colours and font. */
  followTheme: boolean;
  /** How notes are laid out as maps; empty is OpenNexus's default (a balanced mind map). */
  noteStructure: string;
}

export const DEFAULTS: Settings = { nexusPath: "", layout: "saved", embedHeight: 400, followTheme: true, noteStructure: "" };

/** The structures `nexus bundle --structure` takes, as the settings show them. */
export const STRUCTURES: Record<string, string> = {
  "": "Mind map (balanced)",
  "mindmap.right": "Mind map (right)",
  "logic.right": "Logic chart",
  "org.down": "Org chart",
  "tree.down": "Tree",
  "tree.indented": "Indented tree",
  "timeline.horizontal": "Timeline",
  "fishbone.left": "Fishbone",
};

export const MIN_HEIGHT = 160;
export const MAX_HEIGHT = 2000;

export function clampHeight(n: number): number {
  return Math.round(Math.min(MAX_HEIGHT, Math.max(MIN_HEIGHT, n)));
}

/** Saved data as settings: anything missing or wrong becomes the default. */
export function readSettings(data: unknown): Settings {
  const o = typeof data === "object" && data !== null ? (data as Record<string, unknown>) : {};
  const s = { ...DEFAULTS };
  if (typeof o.nexusPath === "string") s.nexusPath = o.nexusPath;
  if (o.layout === "saved" || o.layout === "expanded") s.layout = o.layout;
  if (typeof o.embedHeight === "number" && Number.isFinite(o.embedHeight)) s.embedHeight = clampHeight(o.embedHeight);
  if (typeof o.followTheme === "boolean") s.followTheme = o.followTheme;
  if (typeof o.noteStructure === "string" && o.noteStructure in STRUCTURES) s.noteStructure = o.noteStructure;
  return s;
}

/** What the settings tab needs from the plugin. */
export interface SettingsHost extends Plugin {
  settings: Settings;
  saveSettings(): Promise<void>;
  /** The tool found with the current setting, for the field's placeholder. */
  nexus(): Promise<string | undefined>;
}

export class SettingsTab extends PluginSettingTab {
  constructor(
    app: App,
    private readonly host: SettingsHost,
  ) {
    super(app, host);
  }

  override display(): void {
    const { containerEl } = this;
    containerEl.replaceChildren();
    const s = this.host.settings;
    const save = (): void => { void this.host.saveSettings(); };

    if (canRunApp()) {
      const tool = new Setting(containerEl)
        .setName("OpenNexus command-line tool")
        .setDesc("Draws maps without a viewer copy and notes as maps. Leave empty to use the one inside OpenNexus.")
        .addText((t) => {
          t.setPlaceholder("Looking…").setValue(s.nexusPath).onChange((v) => {
            s.nexusPath = v.trim();
            save();
          });
          void this.host.nexus().then((found) => {
            t.setPlaceholder(found ?? "Not found: install OpenNexus");
          });
        });
      tool.settingEl.addClass("opennexus-setting-tool");
    }
    new Setting(containerEl)
      .setName("Layout")
      .setDesc("How maps open: as saved, or with every branch expanded.")
      .addDropdown((d) =>
        d.addOptions({ saved: "As saved", expanded: "Everything" }).setValue(s.layout).onChange((v) => {
          s.layout = v === "expanded" ? "expanded" : "saved";
          save();
        }),
      );
    new Setting(containerEl)
      .setName("Embed height")
      .setDesc("In pixels, for ```nexus blocks that don’t give a height.")
      .addText((t) => {
        t.inputEl.type = "number";
        t.setValue(String(s.embedHeight)).onChange((v) => {
          const n = Number(v);
          if (Number.isFinite(n) && v.trim() !== "") {
            s.embedHeight = clampHeight(n);
            save();
          }
        });
      });
    new Setting(containerEl)
      .setName("Use Obsidian’s theme")
      .setDesc("The map’s bar, outline and details take Obsidian’s colours. The map keeps its own.")
      .addToggle((t) =>
        t.setValue(s.followTheme).onChange((v) => {
          s.followTheme = v;
          save();
        }),
      );
    if (canRunApp()) {
      new Setting(containerEl)
        .setName("Note as map layout")
        .setDesc("How “Show this note as a map” lays a note out.")
        .addDropdown((d) =>
          d.addOptions(STRUCTURES).setValue(s.noteStructure).onChange((v) => {
            s.noteStructure = v in STRUCTURES ? v : "";
            save();
          }),
        );
    }
  }
}
