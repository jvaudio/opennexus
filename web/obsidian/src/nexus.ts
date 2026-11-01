// The `nexus` tool that ships inside OpenNexus on the Mac (M49): it draws maps that have no
// viewer copy, notes as maps, and converts notes. It isn't sandboxed, so it reads the vault
// itself. Node's modules load only when the tool is used, so mobile never asks for them.

import type * as ChildProcess from "child_process";
import type * as FS from "fs";
import type * as OS from "os";
import { Platform } from "obsidian";

interface NodeModules {
  child_process: typeof ChildProcess;
  fs: typeof FS;
  os: typeof OS;
}

/** Loads Node's modules through the desktop app's `require`; tests stand in for it. */
export const loader = {
  // eslint-disable-next-line @typescript-eslint/no-require-imports -- loaded lazily, so mobile never asks for it
  load: (name: string): unknown => require(name),
};

/** One of Node's modules, when it's first used. */
function node<K extends keyof NodeModules>(name: K): NodeModules[K] {
  return loader.load(name) as NodeModules[K];
}

/** Where OpenNexus keeps its command-line tool, in the order they're tried. */
export function candidates(home: string): string[] {
  return [
    "/Applications/OpenNexus.app/Contents/Helpers/nexus",
    `${home}/Applications/OpenNexus.app/Contents/Helpers/nexus`,
    "/usr/local/bin/nexus",
    "/opt/homebrew/bin/nexus",
  ];
}

/** Whether this Obsidian can run the app's tools: the desktop app on macOS. */
export function canRunApp(): boolean {
  return Platform.isDesktopApp && Platform.isMacOS;
}

/** The tool's path: the setting, else the first candidate that runs; undefined without one (or off the Mac). */
export function findNexus(setting: string): Promise<string | undefined> {
  if (!canRunApp()) return Promise.resolve(undefined);
  const fs = node("fs");
  const os = node("os");
  const list = setting.trim() === "" ? candidates(os.homedir()) : [setting.trim()];
  return Promise.resolve(
    list.find((p) => {
      try {
        fs.accessSync(p, fs.constants.X_OK);
        return fs.statSync(p).isFile();
      } catch {
        return false;
      }
    }),
  );
}

export interface Result {
  code: number;
  stdout: string;
  stderr: string;
}

/** Runs the tool with `args` (never through a shell), writing `input` to its stdin. */
export function run(tool: string, args: string[], input?: string, timeout = 30_000): Promise<Result> {
  const cp = node("child_process");
  return new Promise((resolve) => {
    const child = cp.execFile(tool, args, { encoding: "utf8", maxBuffer: 256 * 1024 * 1024, timeout }, (error, stdout, stderr) => {
      const code = error === null ? 0 : typeof error.code === "number" ? error.code : 1;
      resolve({ code, stdout, stderr });
    });
    child.stdin?.end(input ?? "");
  });
}

/** Opens a file in the OpenNexus app (Edit in OpenNexus). */
export function openInApp(path: string): Promise<Result> {
  const cp = node("child_process");
  return new Promise((resolve) => {
    cp.execFile("/usr/bin/open", ["-b", "com.opennexus.OpenNexus", path], { encoding: "utf8" }, (error, stdout, stderr) => {
      resolve({ code: error === null ? 0 : 1, stdout, stderr });
    });
  });
}
