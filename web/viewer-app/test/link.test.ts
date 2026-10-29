import { describe, expect, it } from "vitest";
import { isFetchable, parseFragment } from "../src/link";

const b64url = (s: string): string => Buffer.from(s).toString("base64url");
const key = Buffer.from(Uint8Array.from({ length: 32 }, (_, i) => (i * 7) & 0xff)).toString("base64url");

describe("share link fragments", () => {
  it("reads what ShareLinkCode writes", () => {
    const url = "https://pub-1.r2.dev/opennexus/a b?.onx";
    const code = parseFragment(`#1.u.${b64url(url)}.${key}`);
    expect(code?.source).toBe("u");
    expect(code?.locator).toBe(url);
    expect(code?.key?.length).toBe(32);
    expect(parseFragment(`1.g.${b64url("aa5a315d61ae9438b18d")}.pw`)).toEqual({ source: "g", locator: "aa5a315d61ae9438b18d" });
  });

  it("refuses anything else", () => {
    const u = b64url("https://maps.example/x.onx");
    for (const bad of [
      "",
      "1.u",
      `2.u.${u}.pw`,
      `1.x.${u}.pw`,
      "1.u..pw",
      `1.u.${u}.short`,
      `1.u.${u}.${key}=`,
      "1.u.Y$Q.pw",
      `1.u.${u}.pw.extra`,
      `1.u.${b64url("javascript:alert(1)")}.pw`,
      `1.u.${b64url("http://maps.example/x")}.pw`,
      `1.u.${b64url("https://user:pw@maps.example/x")}.pw`,
      `1.g.${b64url("../user")}.pw`,
    ]) {
      expect(parseFragment(bad), bad).toBeNull();
    }
  });

  it("fetches HTTPS, or HTTP on this computer only", () => {
    expect(isFetchable("https://maps.example/x")).toBe(true);
    expect(isFetchable("http://localhost:9000/b/x")).toBe(true);
    expect(isFetchable("http://127.0.0.1:8787/v1/shares/x")).toBe(true);
    expect(isFetchable("http://192.168.1.4/x")).toBe(false);
    expect(isFetchable("file:///etc/passwd")).toBe(false);
    expect(isFetchable("data:text/plain,x")).toBe(false);
  });
});
