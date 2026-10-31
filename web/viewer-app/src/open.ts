// The viewer site's front page (M47d): open a `.nexusjson`, a `.nexus` folder or a zip of
// one from this computer, by picker or by drop, and draw its viewer copy with viewer-core.
// Nothing leaves the browser: the files are read here and never sent anywhere.

import { BundleError, parseBundle } from "../../viewer-core/src/bundle";
import { mount, type ViewerHandle } from "../../viewer-core/src/viewer";
import { baseName, folderFiles, openFile, openPackage, type Opened, type OutlineTopic } from "./document";

/** A folder with more files than this isn't a document someone meant to open. */
export const MAX_FILES = 20000;

declare global {
  interface Window {
    /** The opened viewer copy's JSON text, or the outline shown (the open tests read it). */
    OpenNexusOpen?: { kind: Opened["kind"]; text?: string };
  }
}

/** The File System Access API's directory handles, where the browser has them (Chromium). */
interface DirectoryHandle {
  kind: "directory";
  name: string;
  values: () => AsyncIterable<DirectoryHandle | FileHandle>;
}

interface FileHandle {
  kind: "file";
  name: string;
  getFile: () => Promise<File>;
}

type Picker = () => Promise<DirectoryHandle>;

class TooMany extends Error {}

function el<K extends keyof HTMLElementTagNameMap>(tag: K, text?: string, cls?: string): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (text !== undefined) e.textContent = text;
  if (cls !== undefined) e.className = cls;
  return e;
}

function button(text: string, run: () => void, cls?: string): HTMLButtonElement {
  const b = el("button", text, cls);
  b.type = "button";
  b.addEventListener("click", run);
  return b;
}

function add(files: Map<string, Blob>, path: string, file: Blob): void {
  if (files.size >= MAX_FILES) throw new TooMany();
  files.set(path, file);
}

/** A picked folder's files, by path inside it. */
export async function handleFiles(dir: DirectoryHandle, prefix = "", files = new Map<string, Blob>()): Promise<Map<string, Blob>> {
  for await (const h of dir.values()) {
    if (h.kind === "file") add(files, prefix + h.name, await h.getFile());
    else await handleFiles(h, `${prefix}${h.name}/`, files);
  }
  return files;
}

function readBatch(reader: FileSystemDirectoryReader): Promise<FileSystemEntry[]> {
  return new Promise((resolve, reject) => {
    reader.readEntries(resolve, reject);
  });
}

function entryFile(entry: FileSystemFileEntry): Promise<File> {
  return new Promise((resolve, reject) => {
    entry.file(resolve, reject);
  });
}

/** A dropped folder's files, by path inside it. */
export async function entryFiles(dir: FileSystemDirectoryEntry, prefix = "", files = new Map<string, Blob>()): Promise<Map<string, Blob>> {
  const reader = dir.createReader();
  // readEntries answers in batches until it answers with none.
  for (let batch = await readBatch(reader); batch.length > 0; batch = await readBatch(reader)) {
    for (const e of batch) {
      if (e.isFile) add(files, prefix + e.name, await entryFile(e as FileSystemFileEntry));
      else if (e.isDirectory) await entryFiles(e as FileSystemDirectoryEntry, `${prefix}${e.name}/`, files);
    }
  }
  return files;
}

/** A folder input's files (`webkitdirectory`), by path inside the chosen folder. */
export function inputFiles(list: FileList): { name: string; files: Map<string, Blob> } {
  const files = new Map<string, Blob>();
  let name = "";
  for (const f of Array.from(list)) {
    const parts = f.webkitRelativePath.split("/");
    name = parts[0] ?? name;
    add(files, parts.slice(1).join("/"), f);
  }
  return { name, files };
}

async function openFolder(name: string, read: () => Promise<Map<string, Blob>>): Promise<Opened> {
  try {
    return await openPackage(name, folderFiles(await read()));
  } catch (e) {
    if (e instanceof TooMany) return { kind: "refused", name, reason: "The folder holds too many files to be one document." };
    throw e;
  }
}

/** What the page shows, and how to let it go. */
let current: { handle?: ViewerHandle; opened?: Opened } = {};

function release(): void {
  current.handle?.destroy();
  if (current.opened?.kind === "bundle") current.opened.close();
  current = {};
}

function card(state: string, ...children: HTMLElement[]): HTMLElement {
  release();
  document.documentElement.dataset.onxState = state;
  const main = el("main", undefined, "share open");
  main.id = "open";
  main.append(...children);
  document.body.replaceChildren(main);
  return main;
}

function another(): HTMLButtonElement {
  return button("Open Another…", () => { home(); });
}

function outlineList(topics: OutlineTopic[]): HTMLUListElement {
  const ul = el("ul");
  for (const t of topics) {
    const li = el("li");
    li.append(el("span", t.text === "" ? "Untitled topic" : t.text, "open-topic"));
    if (t.note !== undefined) li.append(el("p", t.note, "open-note"));
    if (t.children.length > 0) li.append(outlineList(t.children));
    ul.append(li);
  }
  return ul;
}

/** Shows what was opened: the map, the outline, or why not. */
export function show(opened: Opened): void {
  const name = baseName(opened.name);
  switch (opened.kind) {
    case "bundle": {
      let bundle;
      try {
        bundle = parseBundle(opened.text);
      } catch (e) {
        opened.close();
        const why = e instanceof BundleError && e.message.includes("version") ? "It was saved by a newer version of OpenNexus." : "Its viewer copy is damaged.";
        show({ kind: "refused", name: opened.name, reason: `${why} Open it in OpenNexus and save it again.` });
        return;
      }
      release();
      const host = el("div");
      host.id = "opennexus-viewer";
      document.body.replaceChildren(host);
      const handle = mount(host, bundle, {
        asset: (n) => opened.asset(n, bundle.assets.get(n)?.type),
        actions: [{ label: "Open Another…", run: () => { home(); } }],
      });
      current = { handle, opened };
      document.title = `${bundle.title === "" ? name : bundle.title} · OpenNexus`;
      window.OpenNexusOpen = { kind: "bundle", text: opened.text };
      document.documentElement.dataset.onxState = "ready";
      return;
    }
    case "outline": {
      const how = opened.json
        ? "To see the map here, turn on Settings › Files & Backup › Save a viewer copy and Also in single-file documents in OpenNexus, then save the document again."
        : "To see the map here, turn on Settings › Files & Backup › Save a viewer copy in OpenNexus, then save the document again.";
      const sections = opened.canvases.map((c) => {
        const s = el("section", undefined, "open-canvas");
        s.append(el("h2", c.title === "" ? "Untitled canvas" : c.title), outlineList(c.topics));
        return s;
      });
      card(
        "outline",
        el("h1", opened.title === "" ? name : opened.title),
        el("p", "This document has no viewer copy, so this is its outline: every canvas’s topics and notes, without the map."),
        el("p", how, "open-how"),
        ...sections,
        another(),
      );
      document.title = `${opened.title === "" ? name : opened.title} · OpenNexus`;
      window.OpenNexusOpen = { kind: "outline", text: JSON.stringify(opened.canvases) };
      return;
    }
    case "encrypted": {
      const children = [
        el("h1", `“${name}” is encrypted`),
        el("p", "An encrypted document opens only in OpenNexus, with its password. This viewer never sees its contents."),
      ];
      if (opened.hint !== undefined) children.push(el("p", `Password hint: ${opened.hint}`, "open-hint"));
      card("encrypted", ...children, another());
      document.title = "Encrypted · OpenNexus";
      window.OpenNexusOpen = { kind: "encrypted" };
      return;
    }
    case "refused":
      card("refused", el("h1", `Can’t open “${name}”`), el("p", opened.reason), another());
      document.title = "Can’t open · OpenNexus";
      window.OpenNexusOpen = { kind: "refused", text: opened.reason };
      return;
  }
}

async function run(name: string, open: () => Promise<Opened>): Promise<void> {
  card("loading", el("h1", `Opening “${baseName(name)}”…`), el("p", "It’s read here, in your browser."));
  try {
    show(await open());
  } catch {
    show({ kind: "refused", name, reason: "It couldn’t be read." });
  }
}

/** Opens a dropped item: a file, or a folder (a `.nexus` package). */
export async function openDropped(data: DataTransfer): Promise<void> {
  const item = Array.from(data.items).find((i) => i.kind === "file");
  // webkitGetAsEntry is the only way a drop says it's a folder (every engine has it).
  const entry = item?.webkitGetAsEntry() ?? null;
  if (entry?.isDirectory === true) {
    await run(entry.name, () => openFolder(entry.name, () => entryFiles(entry as FileSystemDirectoryEntry)));
    return;
  }
  const file = item?.getAsFile() ?? data.files[0];
  if (file !== undefined) await run(file.name, () => openFile(file));
}

/** The front page: the pickers, and the words about the site that were here before. */
export function home(): void {
  const fileInput = el("input");
  fileInput.type = "file";
  fileInput.accept = ".nexusjson,.json,.zip,application/zip,application/json";
  fileInput.hidden = true;
  fileInput.id = "open-file";
  fileInput.addEventListener("change", () => {
    const f = fileInput.files?.[0];
    if (f !== undefined) void run(f.name, () => openFile(f));
  });
  const folderInput = el("input");
  folderInput.type = "file";
  folderInput.webkitdirectory = true;
  folderInput.hidden = true;
  folderInput.id = "open-folder";
  folderInput.addEventListener("change", () => {
    const list = folderInput.files;
    if (list === null || list.length === 0) return;
    let picked: { name: string; files: Map<string, Blob> };
    try {
      picked = inputFiles(list);
    } catch {
      show({ kind: "refused", name: "folder", reason: "The folder holds too many files to be one document." });
      return;
    }
    void run(picked.name, () => openFolder(picked.name, () => Promise.resolve(picked.files)));
  });
  const picker = (window as unknown as { showDirectoryPicker?: Picker }).showDirectoryPicker;
  const pickFolder = (): void => {
    if (picker === undefined) {
      folderInput.click();
      return;
    }
    picker.call(window).then(
      (dir) => { void run(dir.name, () => openFolder(dir.name, () => handleFiles(dir))); },
      () => undefined, // Cancelled.
    );
  };
  const actions = el("div", undefined, "open-actions");
  actions.append(button("Open File…", () => { fileInput.click(); }), button("Open Folder…", pickFolder, "secondary"), fileInput, folderInput);
  const about = el("p");
  const link = el("a", "github.com/jvaudio/opennexus");
  link.href = "https://github.com/jvaudio/opennexus";
  about.append("OpenNexus is a free mind-mapping and diagramming app for the Mac, iPad and iPhone: ", link, ".");
  card(
    "home",
    el("h1", "OpenNexus Viewer"),
    el("p", "Open a map saved by OpenNexus: a .nexusjson file, a .nexus document (it’s a folder) or a zip of one. You can also drop it anywhere on this page. It’s read here, in your browser, and never uploaded."),
    actions,
    el("h2", "Shared maps"),
    el("p", "This site also opens maps shared from OpenNexus. A share link carries its key after the #, which your browser never sends to any server, so the map is decrypted here, on your device."),
    about,
  );
  document.title = "OpenNexus Viewer";
  delete window.OpenNexusOpen;
}

/** Drop a file or folder anywhere, on the front page or over an open map. */
export function startOpen(): void {
  const root = document.documentElement;
  const files = (e: DragEvent): boolean => e.dataTransfer?.types.includes("Files") === true;
  document.addEventListener("dragover", (e) => {
    if (!files(e)) return;
    e.preventDefault();
    if (e.dataTransfer !== null) e.dataTransfer.dropEffect = "copy";
    root.classList.add("onx-dragging");
  });
  document.addEventListener("dragleave", (e) => {
    if (e.relatedTarget === null) root.classList.remove("onx-dragging");
  });
  document.addEventListener("drop", (e) => {
    root.classList.remove("onx-dragging");
    if (!files(e) || e.dataTransfer === null) return;
    e.preventDefault();
    void openDropped(e.dataTransfer);
  });
  home();
}
