// @vitest-environment node
import { describe, expect, it } from "vitest";
import { entries, read, ZipError } from "../src/zip";
import { zip } from "./zipwriter";

/** The value, which the test expects to be there. */
function must<T>(v: T | null | undefined): T {
  if (v === null || v === undefined) throw new Error("expected a value");
  return v;
}

const text = (b: Uint8Array): string => new TextDecoder().decode(b);

describe("the zip reader", () => {
  it("reads stored and deflated entries, skipping folders and macOS's resource forks", async () => {
    const big = "OpenNexus ".repeat(2000);
    const z = zip(
      [
        { name: "Plan.nexus/" },
        { name: "Plan.nexus/manifest.json", data: '{"format":"opennexus"}' },
        { name: "Plan.nexus/canvases/c1.json", data: big, deflate: true },
        { name: "__MACOSX/Plan.nexus/._manifest.json", data: "fork" },
      ],
      "made by a test",
    );
    const list = entries(z);
    expect(list.map((e) => e.name)).toEqual(["Plan.nexus/manifest.json", "Plan.nexus/canvases/c1.json"]);
    expect(list[1]?.method).toBe(8);
    expect(text(await read(z, must(list[0])))).toBe('{"format":"opennexus"}');
    expect(text(await read(z, must(list[1])))).toBe(big);
  });

  it("refuses what it can't read, saying why", () => {
    expect(() => entries(new TextEncoder().encode("not a zip at all, just words"))).toThrow(/not a zip/);
    expect(() => entries(zip([{ name: "a", data: "x", flags: 1 }]))).toThrow(/encrypted/);
    expect(() => entries(zip([{ name: "a.bin", data: "x", method: 12 }]))).toThrow(/compressed in a way/);
    expect(() => entries(zip([{ name: "a", data: "x", size: 300 * 1024 * 1024 }]))).toThrow(/too large/);
  });

  it("finds damage: a cut archive, and an entry that inflates past its size", async () => {
    const z = zip([{ name: "a.json", data: "{}".repeat(500), deflate: true }]);
    const e = must(entries(z)[0]);
    await expect(read(z.subarray(0, 40), e)).rejects.toBeInstanceOf(ZipError);
    await expect(read(z, { ...e, size: 10 })).rejects.toThrow(/damaged/);
    await expect(read(z, { ...e, offset: 3 })).rejects.toThrow(/damaged/);
    const garbage = zip([{ name: "b", data: "this isn't deflate data", method: 8 }]);
    await expect(read(garbage, must(entries(garbage)[0]))).rejects.toBeInstanceOf(ZipError);
  });
});
