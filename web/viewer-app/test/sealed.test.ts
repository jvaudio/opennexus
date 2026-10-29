// @vitest-environment node
// The envelope against the Swift implementation (Tests/NexusFormatTests/SealedTests.swift):
// the same inputs seal to the same bytes, and each side opens what the other sealed and
// deflated. `npm run vectors` rewrites both sides' files.

import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { describe, expect, it } from "vitest";
import {
  canonical,
  deflate,
  header,
  importKey,
  inflate,
  open,
  openBundle,
  passwordKey,
  seal,
  SealedError,
  toBase64,
  VIEWER_TYPE,
  type Header,
} from "../src/sealed";

const here = import.meta.dirname;
const fromSwift = path.join(here, "sealed-by-swift.onx");
const fromBrowser = path.resolve(here, "../../../Tests/NexusFormatTests/Fixtures/sealed-by-browser.onx");

/** `SealedTests.vector`: text/plain, no encoding, created 2026-10-26T07:33:20Z, key 0…31, nonce 0…11. */
const VECTOR =
  "T05YMQAAAFx7ImFsZ29yaXRobSI6IkFFUy0yNTYtR0NNIiwiY3JlYXRlZCI6IjIwMjYtMTAtMjZUMDc6MzM6MjBaIiwidHlwZSI6InRleHQvcGxhaW4iLCJ2ZXJzaW9uIjoxfQABAgMEBQYHCAkKCwhys3WLgLpu/n3GmuA+D1R71h4hA290CdU=";

/** `SealedTests.bundle`. */
const BUNDLE = {
  format: "opennexus-viewer",
  version: 1,
  title: "Launch plan",
  canvases: [{ id: "c1", title: "Pricing tiers" }],
};

const range = (n: number): Uint8Array => Uint8Array.from({ length: n }, (_, i) => i);
const created = "2026-10-26T07:33:20Z";

async function sealBundle(key: CryptoKey, h: Partial<Header> = {}): Promise<Uint8Array> {
  const content = await deflate(new TextEncoder().encode(canonical(BUNDLE)));
  const full: Header = { version: 1, algorithm: "AES-256-GCM", type: VIEWER_TYPE, encoding: "deflate-raw", bundle: 1, created, ...h };
  return seal(content, full, key, crypto.getRandomValues(new Uint8Array(12)));
}

describe("the sealed envelope", () => {
  it("seals the shared vector to Swift's bytes", async () => {
    const key = await importKey(range(32));
    const h: Header = { version: 1, algorithm: "AES-256-GCM", type: "text/plain", created };
    const sealed = await seal(new TextEncoder().encode("OpenNexus"), h, key, range(12));
    expect(toBase64(sealed)).toBe(VECTOR);
    const opened = await open(sealed, key);
    expect(new TextDecoder().decode(opened.content)).toBe("OpenNexus");
  });

  it("opens what Swift sealed and deflated, and writes its own for Swift", async () => {
    const key = await importKey(range(32));
    if (process.env.NEXUS_WRITE_VECTORS === "1") writeFileSync(fromBrowser, await sealBundle(key));
    const swift = await openBundle(new Uint8Array(readFileSync(fromSwift)), key);
    expect(JSON.parse(swift.text)).toEqual(BUNDLE);
    expect(swift.header.bundle).toBe(1);
    const ours = await openBundle(new Uint8Array(readFileSync(fromBrowser)), key);
    expect(JSON.parse(ours.text)).toEqual(BUNDLE);
  });

  it("fails a wrong key and any altered byte as damaged", async () => {
    const key = await importKey(range(32));
    const sealed = await sealBundle(key);
    await expect(openBundle(sealed, await importKey(range(32).reverse()))).rejects.toMatchObject({ kind: "damaged" });
    const end = 8 + (sealed[7] ?? 0);
    for (const i of [0, 5, 9, end - 2, end, end + 12, sealed.length >> 1, sealed.length - 1]) {
      const d = sealed.slice();
      d[i] = (d[i] ?? 0) ^ 1;
      await expect(openBundle(d, key), `byte ${String(i)}`).rejects.toBeInstanceOf(SealedError);
    }
    for (const n of [0, 4, 8, end + 11]) {
      await expect(openBundle(sealed.slice(0, n), key)).rejects.toMatchObject({ kind: "damaged" });
    }
  });

  it("says when a newer OpenNexus made it", async () => {
    const key = await importKey(range(32));
    await expect(openBundle(await sealBundle(key, { bundle: 2 }), key)).rejects.toMatchObject({ kind: "newer" });
    const newer = await seal(new Uint8Array([1]), { version: 3, algorithm: "AES-256-GCM", type: "x", created }, key, range(12));
    expect(() => header(newer)).toThrow(expect.objectContaining({ kind: "newer" }) as Error);
  });

  it("derives password keys as the app does", async () => {
    const salt = crypto.getRandomValues(new Uint8Array(16));
    const kdf = { iterations: 1000, salt };
    const sealed = await sealBundle(await passwordKey("tiger lily", kdf), { kdf });
    const h = header(sealed);
    expect(h.kdf?.iterations).toBe(1000);
    expect(h.kdf?.salt).toEqual(salt);
    await expect(openBundle(sealed, await passwordKey("tiger lilly", kdf))).rejects.toMatchObject({ kind: "damaged" });
    expect(JSON.parse((await openBundle(sealed, await passwordKey("tiger lily", kdf))).text)).toEqual(BUNDLE);
    // PBKDF2-HMAC-SHA256's published vector (P = "password", S = "salt", c = 4096).
    const bits = await crypto.subtle.deriveBits(
      { name: "PBKDF2", hash: "SHA-256", salt: new TextEncoder().encode("salt"), iterations: 4096 },
      await crypto.subtle.importKey("raw", new TextEncoder().encode("password"), "PBKDF2", false, ["deriveBits"]),
      256,
    );
    expect(Buffer.from(bits).toString("hex")).toBe("c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a");
  });

  it("bounds inflating", async () => {
    const big = new Uint8Array(1 << 20).fill(65);
    const packed = await deflate(big);
    expect(packed.length).toBeLessThan(4096);
    expect(await inflate(packed)).toEqual(big);
    await expect(inflate(packed, 1 << 19)).rejects.toMatchObject({ kind: "damaged" });
    await expect(inflate(new Uint8Array([0xff, 0xff, 0xff]))).rejects.toMatchObject({ kind: "damaged" });
  });

  it("writes canonical JSON as the app does", () => {
    expect(canonical({ b: 1, a: [true, null, "é\"\\"], A: { z: 2.5 } })).toBe('{"A":{"z":2.5},"a":[true,null,"é\\"\\\\"],"b":1}');
  });
});
