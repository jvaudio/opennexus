// What views, embeds and commands need from the plugin (M49).

import type { App } from "obsidian";
import type { TopicTarget } from "./links";
import type { Settings } from "./settings";

export interface Host {
  readonly app: App;
  readonly settings: Settings;
  /** The `nexus` tool, when this is a Mac with OpenNexus. */
  nexus(): Promise<string | undefined>;
  /** Opens a map in a view, at a topic when the target names one. */
  openTopic(t: TopicTarget): Promise<void>;
}
