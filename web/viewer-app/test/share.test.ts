// @vitest-environment node
import { afterEach, describe, expect, it, vi } from "vitest";
import { fetchSealed, GIST_FILE } from "../src/share";

const sealed = new Uint8Array([0x4f, 0x4e, 0x58, 0x31, 9, 8, 7]);
const b64 = Buffer.from(sealed).toString("base64");

function respond(map: Record<string, Response>): void {
  vi.stubGlobal("fetch", (url: string, init: RequestInit) => {
    expect(init.credentials).toBe("omit");
    expect(init.referrerPolicy).toBe("no-referrer");
    return Promise.resolve(map[url] ?? new Response("", { status: 404 }));
  });
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("fetching a sealed map", () => {
  it("from an address, without credentials", async () => {
    respond({ "https://maps.example/x.onx": new Response(sealed) });
    expect(await fetchSealed({ source: "u", locator: "https://maps.example/x.onx" })).toEqual(sealed);
  });

  it("treats a missing object as a link that's turned off", async () => {
    for (const status of [403, 404, 410]) {
      respond({ "https://maps.example/x.onx": new Response("", { status }) });
      await expect(fetchSealed({ source: "u", locator: "https://maps.example/x.onx" })).rejects.toMatchObject({ state: "off" });
    }
    respond({ "https://maps.example/x.onx": new Response("", { status: 500 }) });
    await expect(fetchSealed({ source: "u", locator: "https://maps.example/x.onx" })).rejects.toMatchObject({
      state: "unreachable",
    });
  });

  it("from a gist, and from its raw address when GitHub cut it short", async () => {
    respond({ "https://api.github.com/gists/abc123": Response.json({ files: { [GIST_FILE]: { content: b64, truncated: false } } }) });
    expect(await fetchSealed({ source: "g", locator: "abc123" })).toEqual(sealed);

    const raw = "https://gist.githubusercontent.com/octocat/abc123/raw/f00/opennexus-share.b64";
    respond({
      "https://api.github.com/gists/abc123": Response.json({
        files: { [GIST_FILE]: { content: b64.slice(0, 4), truncated: true, raw_url: raw } },
      }),
      [raw]: new Response(`${b64}\n`),
    });
    expect(await fetchSealed({ source: "g", locator: "abc123" })).toEqual(sealed);

    // A raw address anywhere else isn't followed.
    respond({
      "https://api.github.com/gists/abc123": Response.json({
        files: { [GIST_FILE]: { content: "", truncated: true, raw_url: "https://evil.example/x" } },
      }),
    });
    await expect(fetchSealed({ source: "g", locator: "abc123" })).rejects.toMatchObject({ state: "damaged" });
    respond({ "https://api.github.com/gists/abc123": Response.json({ files: {} }) });
    await expect(fetchSealed({ source: "g", locator: "abc123" })).rejects.toMatchObject({ state: "damaged" });
  });
});
