// The sealed envelope (NexusFormat/Sealed.swift), opened with WebCrypto:
//
//   "ONX1" | header length (u32, big-endian) | header JSON | nonce (12) | ciphertext | tag (16)
//
// Everything before the nonce is AES-GCM's associated data. A wrong key and an altered byte
// both fail the tag check, so both read as "damaged".

export const MAGIC = new Uint8Array([0x4f, 0x4e, 0x58, 0x31]);
export const VERSION = 1;
export const ALGORITHM = "AES-256-GCM";
export const VIEWER_TYPE = "application/vnd.opennexus.viewer+json";
export const DEFLATE = "deflate-raw";
export const KDF_NAME = "PBKDF2-SHA256";
export const MAX_HEADER = 4096;
export const MAX_CONTENT = 256 * 1024 * 1024;

export interface KDF {
  iterations: number;
  salt: Uint8Array;
}

export interface Header {
  version: number;
  algorithm: string;
  type: string;
  encoding?: string;
  bundle?: number;
  created: string;
  expires?: string;
  kdf?: KDF;
}

export type SealedFailure = "damaged" | "newer";

export class SealedError extends Error {
  constructor(
    readonly kind: SealedFailure,
    message: string,
  ) {
    super(message);
  }
}

const damaged = (why: string): never => {
  throw new SealedError("damaged", why);
};

interface Parts {
  prefix: Uint8Array;
  header: Header;
  nonce: Uint8Array;
  sealed: Uint8Array;
}

function isInt(v: unknown): v is number {
  return typeof v === "number" && Number.isInteger(v);
}

function own(o: object, k: string): unknown {
  return Object.prototype.hasOwnProperty.call(o, k) ? (o as Record<string, unknown>)[k] : undefined;
}

export function base64(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function toBase64(b: Uint8Array): string {
  let s = "";
  for (const c of b) s += String.fromCharCode(c);
  return btoa(s);
}

/** Reads a header, refusing what this version can't open. */
export function readHeader(json: unknown): Header {
  if (typeof json !== "object" || json === null || Array.isArray(json)) return damaged("header");
  const version = own(json, "version");
  const type = own(json, "type");
  const created = own(json, "created");
  if (!isInt(version) || version < 1 || typeof type !== "string" || typeof created !== "string") return damaged("header");
  if (version > VERSION) throw new SealedError("newer", `envelope version ${String(version)}`);
  if (own(json, "algorithm") !== ALGORITHM) return damaged("algorithm");
  const h: Header = { version, algorithm: ALGORITHM, type, created };
  const encoding = own(json, "encoding");
  if (encoding !== undefined) {
    if (encoding !== DEFLATE) return damaged("encoding");
    h.encoding = DEFLATE;
  }
  const bundle = own(json, "bundle");
  if (bundle !== undefined) {
    if (!isInt(bundle)) return damaged("bundle");
    h.bundle = bundle;
  }
  const expires = own(json, "expires");
  if (expires !== undefined) {
    if (typeof expires !== "string") return damaged("expires");
    h.expires = expires;
  }
  const kdf = own(json, "kdf");
  if (kdf !== undefined) {
    if (typeof kdf !== "object" || kdf === null || own(kdf, "name") !== KDF_NAME) return damaged("kdf");
    const n = own(kdf, "iterations");
    const salt = own(kdf, "salt");
    if (!isInt(n) || n < 1 || n > 10_000_000 || typeof salt !== "string") return damaged("kdf");
    let s: Uint8Array;
    try {
      s = base64(salt);
    } catch {
      return damaged("salt");
    }
    if (s.length === 0) return damaged("salt");
    h.kdf = { iterations: n, salt: s };
  }
  return h;
}

export function parts(bytes: Uint8Array): Parts {
  if (bytes.length < 8 || MAGIC.some((m, i) => bytes[i] !== m)) return damaged("not an envelope");
  const length = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(4);
  const end = 8 + length;
  if (length === 0 || length > MAX_HEADER || bytes.length < end + 12 + 16) return damaged("short");
  let json: unknown;
  try {
    json = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes.subarray(8, end)));
  } catch {
    return damaged("header JSON");
  }
  return {
    prefix: bytes.subarray(0, end),
    header: readHeader(json),
    nonce: bytes.subarray(end, end + 12),
    sealed: bytes.subarray(end + 12),
  };
}

export function header(bytes: Uint8Array): Header {
  return parts(bytes).header;
}

/** `ArrayBuffer`-backed copies, as WebCrypto's typings want. */
function buf(b: Uint8Array): Uint8Array<ArrayBuffer> {
  const out = new Uint8Array(b.length);
  out.set(b);
  return out;
}

export async function importKey(raw: Uint8Array): Promise<CryptoKey> {
  if (raw.length !== 32) return damaged("key length");
  return crypto.subtle.importKey("raw", buf(raw), "AES-GCM", false, ["encrypt", "decrypt"]);
}

/** PBKDF2-SHA256 over the password's UTF-8, as the app derives it. */
export async function passwordKey(password: string, kdf: KDF): Promise<CryptoKey> {
  const base = await crypto.subtle.importKey("raw", new TextEncoder().encode(password), "PBKDF2", false, ["deriveKey"]);
  return crypto.subtle.deriveKey(
    { name: "PBKDF2", hash: "SHA-256", salt: buf(kdf.salt), iterations: kdf.iterations },
    base,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"],
  );
}

/**
 * The same key's 32 bytes, for the page to hand the app with Open in OpenNexus (M47d) once
 * the password has opened the map, so the app never asks for the password again.
 */
export async function passwordKeyBytes(password: string, kdf: KDF): Promise<Uint8Array> {
  const base = await crypto.subtle.importKey("raw", new TextEncoder().encode(password), "PBKDF2", false, ["deriveBits"]);
  const bits = await crypto.subtle.deriveBits({ name: "PBKDF2", hash: "SHA-256", salt: buf(kdf.salt), iterations: kdf.iterations }, base, 256);
  return new Uint8Array(bits);
}

/** The content as sealed (still encoded). */
export async function open(bytes: Uint8Array, key: CryptoKey): Promise<{ header: Header; content: Uint8Array }> {
  const p = parts(bytes);
  try {
    const plain = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: buf(p.nonce), additionalData: buf(p.prefix), tagLength: 128 },
      key,
      buf(p.sealed),
    );
    return { header: p.header, content: new Uint8Array(plain) };
  } catch {
    return damaged("tag");
  }
}

async function pump(data: Uint8Array, stream: TransformStream<BufferSource, Uint8Array>, limit: number): Promise<Uint8Array> {
  const writer = stream.writable.getWriter();
  // The reading side reports bad data and stops at the limit; the writing side then fails
  // too, which isn't news (and mustn't be an unhandled rejection).
  const written = writer
    .write(buf(data))
    .then(() => writer.close())
    .catch(() => undefined);
  const chunks: Uint8Array[] = [];
  let total = 0;
  const reader = stream.readable.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > limit) {
      await reader.cancel();
      return damaged("too large");
    }
    chunks.push(value);
  }
  await written;
  const out = new Uint8Array(total);
  let at = 0;
  for (const c of chunks) {
    out.set(c, at);
    at += c.length;
  }
  return out;
}

/** Raw DEFLATE, bounded (a deflate bomb is "damaged"). */
export async function inflate(data: Uint8Array, limit = MAX_CONTENT): Promise<Uint8Array> {
  try {
    return await pump(data, new DecompressionStream(DEFLATE), limit);
  } catch (e) {
    if (e instanceof SealedError) throw e;
    return damaged("deflate");
  }
}

export async function deflate(data: Uint8Array): Promise<Uint8Array> {
  return pump(data, new CompressionStream(DEFLATE), Number.MAX_SAFE_INTEGER);
}

/** A sealed viewer bundle's JSON text. */
export async function openBundle(bytes: Uint8Array, key: CryptoKey): Promise<{ header: Header; text: string }> {
  const { header, content } = await open(bytes, key);
  if (header.type !== VIEWER_TYPE) return damaged("type");
  if (header.bundle !== undefined && header.bundle > 1) throw new SealedError("newer", `bundle version ${String(header.bundle)}`);
  const raw = header.encoding === DEFLATE ? await inflate(content) : content;
  try {
    return { header, text: new TextDecoder("utf-8", { fatal: true }).decode(raw) };
  } catch {
    return damaged("UTF-8");
  }
}

// Sealing: only for the shared test vectors (the viewer never seals).

/** The app's canonical compact JSON: keys sorted by code point, integers without a point. */
export function canonical(v: unknown): string {
  if (v === null || typeof v === "boolean" || typeof v === "number" || typeof v === "string") return JSON.stringify(v);
  if (Array.isArray(v)) return `[${v.map(canonical).join(",")}]`;
  const o = v as Record<string, unknown>;
  const keys = Object.keys(o).sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonical(o[k])}`).join(",")}}`;
}

export function headerJSON(h: Header): Record<string, unknown> {
  const o: Record<string, unknown> = { version: h.version, algorithm: h.algorithm, type: h.type, created: h.created };
  if (h.encoding !== undefined) o.encoding = h.encoding;
  if (h.bundle !== undefined) o.bundle = h.bundle;
  if (h.expires !== undefined) o.expires = h.expires;
  if (h.kdf !== undefined) o.kdf = { name: KDF_NAME, iterations: h.kdf.iterations, salt: toBase64(h.kdf.salt) };
  return o;
}

export async function seal(content: Uint8Array, h: Header, key: CryptoKey, nonce: Uint8Array): Promise<Uint8Array> {
  const json = new TextEncoder().encode(canonical(headerJSON(h)));
  const prefix = new Uint8Array(8 + json.length);
  prefix.set(MAGIC);
  new DataView(prefix.buffer).setUint32(4, json.length);
  prefix.set(json, 8);
  const sealed = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv: buf(nonce), additionalData: buf(prefix), tagLength: 128 }, key, buf(content)),
  );
  const out = new Uint8Array(prefix.length + 12 + sealed.length);
  out.set(prefix);
  out.set(nonce, prefix.length);
  out.set(sealed, prefix.length + 12);
  return out;
}
