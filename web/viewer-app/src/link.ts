// A share link's fragment (NexusFormat/Sharing.swift, ShareLinkCode):
// `1.<source>.<locator>.<key>`, the locator in base64url, the key 32 bytes in base64url or
// `pw` when the link opens with a password.

export type Source = "u" | "g";

export interface ShareCode {
  source: Source;
  /** A URL to fetch (`u`) or a gist id (`g`). */
  locator: string;
  /** Absent when the link needs a password. */
  key?: Uint8Array;
}

export const PASSWORD_MARK = "pw";

export function fromBase64URL(s: string): Uint8Array | null {
  if (!/^[A-Za-z0-9_-]*$/.test(s)) return null;
  const t = s.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (s.length % 4)) % 4);
  try {
    const bin = atob(t);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

export function parseFragment(fragment: string): ShareCode | null {
  const parts = fragment.replace(/^#/, "").split(".");
  if (parts.length !== 4 || parts[0] !== "1") return null;
  const [, source, loc, key] = parts as [string, string, string, string];
  if (source !== "u" && source !== "g") return null;
  const l = fromBase64URL(loc);
  if (l === null || l.length === 0) return null;
  let locator: string;
  try {
    locator = new TextDecoder("utf-8", { fatal: true }).decode(l);
  } catch {
    return null;
  }
  if (source === "u" && !isFetchable(locator)) return null;
  if (source === "g" && !/^[0-9a-f]{1,64}$/i.test(locator)) return null;
  if (key === PASSWORD_MARK) return { source, locator };
  const k = fromBase64URL(key);
  if (k?.length !== 32) return null;
  return { source, locator, key: k };
}

/** HTTPS anywhere; plain HTTP only on this computer (a server under test). */
export function isFetchable(s: string): boolean {
  let u: URL;
  try {
    u = new URL(s);
  } catch {
    return false;
  }
  if (u.username !== "" || u.password !== "") return false;
  if (u.protocol === "https:") return true;
  return u.protocol === "http:" && (u.hostname === "localhost" || u.hostname === "127.0.0.1" || u.hostname === "[::1]");
}
