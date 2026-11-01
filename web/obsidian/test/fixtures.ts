// Small maps for the plugin's tests: a viewer bundle, and documents that carry it or don't.

const theme = { canvas: "#FFFFFF", ink: "#000000", ink2: "#333333", accent: "#6E56CF", dark: false };

export const bundle = {
  format: "opennexus-viewer",
  version: 1,
  title: "Launch",
  assets: {},
  canvases: [
    {
      id: "c1",
      title: "Plan",
      type: "mindmap",
      typeName: "Mind map",
      theme,
      layouts: {
        saved: {
          svg: '<svg xmlns="http://www.w3.org/2000/svg"/>',
          viewBox: [0, 0, 1000, 500],
          topics: {
            r: { frame: [450, 230, 100, 40], depth: 0 },
            p: { frame: [100, 100, 80, 30], depth: 1, parent: "r" },
            p1: { frame: [60, 160, 80, 30], depth: 2, parent: "p" },
            s: { frame: [800, 300, 80, 30], depth: 1, parent: "r" },
          },
        },
      },
      outline: [{ id: "r", children: [{ id: "p", children: [{ id: "p1" }] }, { id: "s" }] }],
      topics: {
        r: { text: "Launch", label: "Launch", note: "See [[Risks]]" },
        p: { text: "Pricing", label: "Pricing", note: "Ask about the discount" },
        p1: { text: "Pro", label: "Pro" },
        s: { text: "Sales", label: "Sales", link: { href: "obsidian://open?vault=Test%20vault&file=Risks", kind: "other" } },
      },
    },
    {
      id: "c2",
      title: "Roadmap",
      type: "mindmap",
      typeName: "Mind map",
      theme,
      layouts: { saved: { svg: '<svg xmlns="http://www.w3.org/2000/svg"/>', viewBox: [0, 0, 100, 40], topics: { q: { frame: [0, 0, 100, 40], depth: 0 } } } },
      outline: [{ id: "q", children: [] }],
      topics: { q: { text: "Q3", label: "Q3" } },
    },
  ],
};

const canvases = [
  {
    id: "c1",
    title: "Plan",
    root: "r",
    nodes: {
      r: { text: "Launch", children: ["p", "s"] },
      p: { text: "Pricing", children: ["p1"], note: { text: "Ask about the discount" } },
      p1: { text: "Pro", children: [] },
      s: { text: "Sales", children: [] },
    },
  },
];

export const manifest = { format: "opennexus", version: 1, canvases: ["c1"] };

/** A `.nexusjson`, with its viewer copy or without. */
export function nexusjson(render: boolean): string {
  return JSON.stringify({ manifest, canvases, ...(render ? { render: bundle } : {}) });
}

/** A package's files, under `root`. */
export function packageFiles(root: string, render: boolean): Record<string, string> {
  const files: Record<string, string> = {
    [`${root}/manifest.json`]: JSON.stringify(manifest),
    [`${root}/canvases/c1.json`]: JSON.stringify(canvases[0]),
  };
  if (render) files[`${root}/render/viewer.json`] = JSON.stringify(bundle);
  return files;
}
