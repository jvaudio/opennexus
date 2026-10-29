import { afterEach, describe, expect, it, vi } from "vitest";
import { appLink, parseInvite, viewURL, type Invite } from "../src/invite";
import { DOWNLOAD, fetchView, startJoin } from "../src/join";
import { canonical, deflate, importKey, seal, VIEWER_TYPE, type Header } from "../src/sealed";

const b64url = (b: Uint8Array | string): string => Buffer.from(b).toString("base64url");
const range = (n: number, k = 1): Uint8Array => Uint8Array.from({ length: n }, (_, i) => (i * k) & 0xff);
const key = range(32, 7);
const read = b64url(range(32, 3));
const write = b64url(range(32, 5));
const room = "Roomroomroomroomroomrr";
const server = "https://relay.example/";
/** As `Invite.fragment` writes it. */
const fragment = `2.${b64url(server)}.${room}.${b64url(key)}.${read}.${write}`;
const viewOnly = fragment.split(".").slice(0, 5).join(".");

const minimal = {
  format: "opennexus-viewer",
  version: 1,
  title: "Launch plan",
  assets: {},
  canvases: [
    {
      id: "c1",
      title: "C",
      type: "mindmap",
      typeName: "Mind map",
      theme: { canvas: "#FFFFFF", ink: "#000000", ink2: "#333333", accent: "#6E56CF", dark: false },
      layouts: { saved: { svg: "<svg/>", viewBox: [0, 0, 10, 10], topics: { n1: { frame: [0, 0, 1, 1], depth: 0 } } } },
      outline: [{ id: "n1" }],
      topics: { n1: { text: "Launch plan", label: "Launch plan. Central topic." } },
    },
  ],
};

/** An invite the tests know is good. */
function invite(f: string): Invite {
  const i = parseInvite(f);
  if (i === null) throw new Error(`not an invite: ${f}`);
  return i;
}

async function sealedView(k = key): Promise<Uint8Array<ArrayBuffer>> {
  const h: Header = {
    version: 1,
    algorithm: "AES-256-GCM",
    type: VIEWER_TYPE,
    encoding: "deflate-raw",
    bundle: 1,
    created: "2026-10-29T10:00:00Z",
  };
  // A copy on its own ArrayBuffer, as a Response body wants.
  return new Uint8Array(
    await seal(await deflate(new TextEncoder().encode(canonical(minimal))), h, await importKey(k), range(12)),
  );
}

function respond(answer: () => Response | Promise<Response>): RequestInit[] {
  const seen: RequestInit[] = [];
  vi.stubGlobal("fetch", (url: string, init: RequestInit) => {
    expect(url).toBe(`https://relay.example/v1/rooms/${room}/view`);
    seen.push(init);
    return Promise.resolve(answer());
  });
  return seen;
}

afterEach(() => {
  vi.unstubAllGlobals();
  document.body.replaceChildren();
  delete document.documentElement.dataset.onxState;
});

describe("invites", () => {
  it("reads what Invite.fragment writes", () => {
    const i = parseInvite(`#${fragment}`);
    expect(i?.server).toBe(server);
    expect(i?.room).toBe(room);
    expect(i?.key).toEqual(key);
    expect(i?.read).toBe(read);
    expect(i?.write).toBe(write);
    expect(parseInvite(viewOnly)?.write).toBeUndefined();
    expect(viewURL(invite(fragment))).toBe(`https://relay.example/v1/rooms/${room}/view`);
    expect(appLink(`#${fragment}`)).toBe(`opennexus://join#${fragment}`);
    // A server on this computer may be plain HTTP (tests).
    expect(parseInvite(fragment.replace(b64url(server), b64url("http://localhost:18787")))?.server).toBe("http://localhost:18787");
  });

  it("refuses anything else", () => {
    const parts = fragment.split(".");
    const swap = (i: number, v: string): string => parts.map((p, j) => (j === i ? v : p)).join(".");
    for (const bad of [
      "",
      "2",
      `1.${fragment.slice(2)}`,
      parts.slice(0, 4).join("."),
      `${fragment}.${write}`,
      swap(1, b64url("http://relay.example")),
      swap(1, b64url("javascript:alert(1)")),
      swap(1, "Y$Q"),
      swap(2, "short"),
      swap(3, b64url(range(16))),
      swap(4, read.slice(1)),
      swap(5, `${write}=`),
    ]) {
      expect(parseInvite(bad), bad).toBeNull();
    }
  });
});

describe("the session's view", () => {
  it("asks with the read capability, never credentials or a referrer", async () => {
    const sealed = await sealedView();
    const seen = respond(() => new Response(sealed));
    expect(await fetchView(invite(fragment))).toEqual(sealed);
    expect(seen[0]?.credentials).toBe("omit");
    expect(seen[0]?.referrerPolicy).toBe("no-referrer");
    expect((seen[0]?.headers as Record<string, string>).Authorization).toBe(`Bearer ${read}`);
  });

  it("says why there's nothing to show", async () => {
    const i = invite(fragment);
    respond(() => new Response("", { status: 404 }));
    expect(await fetchView(i)).toBe("none");
    respond(() => new Response("", { status: 403 }));
    expect(await fetchView(i)).toBe("refused");
    respond(() => new Response("", { status: 503 }));
    expect(await fetchView(i)).toBe("unreachable");
    vi.stubGlobal("fetch", () => Promise.reject(new TypeError("offline")));
    expect(await fetchView(i)).toBe("unreachable");
  });
});

describe("the join page", () => {
  it("offers the app and draws the view, read-only", async () => {
    const sealed = await sealedView();
    respond(() => new Response(sealed));
    await startJoin(`#${fragment}`);
    expect(document.documentElement.dataset.onxState).toBe("ready");
    const open = document.querySelector<HTMLAnchorElement>("a.join-open");
    expect(open?.getAttribute("href")).toBe(`opennexus://join#${fragment}`);
    expect([...document.querySelectorAll("a")].some((a) => a.getAttribute("href") === DOWNLOAD)).toBe(true);
    expect(document.querySelector("h1")?.textContent).toBe("You’re invited to a live session");
    expect(document.body.textContent).toContain("edit together");
    expect(JSON.parse(window.OpenNexusJoin?.text ?? "{}")).toEqual(minimal);
    expect(document.getElementById("opennexus-viewer")).not.toBeNull();
  });

  it("says when the invite is view only, and when there's no view yet", async () => {
    respond(() => new Response("", { status: 404 }));
    await startJoin(`#${viewOnly}`);
    expect(document.documentElement.dataset.onxState).toBe("none");
    expect(document.body.textContent).toContain("This invite is view only.");
    expect(document.querySelector("[role=status]")?.textContent).toBe(
      "The host hasn’t shared a view yet, or the session has ended.",
    );
  });

  it("calls a view sealed with another key damaged, and a broken invite too", async () => {
    const other = await sealedView(range(32, 11));
    respond(() => new Response(other));
    await startJoin(`#${fragment}`);
    expect(document.documentElement.dataset.onxState).toBe("damaged");
    await startJoin("#2.nope");
    expect(document.documentElement.dataset.onxState).toBe("damaged");
    expect(document.querySelector("h1")?.textContent).toBe("This invite is damaged");
  });
});
