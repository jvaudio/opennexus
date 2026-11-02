// A small zip writer for the tests: stored or deflated entries, as Finder and Files make them.
import { deflateRawSync } from "node:zlib";

export interface Entry {
  name: string;
  data?: Uint8Array | string;
  deflate?: boolean;
  /** General purpose flags (bit 0: encrypted). */
  flags?: number;
  /** Overrides the method written (12 is bzip2). */
  method?: number;
  /** Overrides the uncompressed size written. */
  size?: number;
}

export function zip(entries: Entry[], comment = ""): Uint8Array {
  const enc = new TextEncoder();
  const locals: Uint8Array[] = [];
  const centrals: Uint8Array[] = [];
  let offset = 0;
  for (const e of entries) {
    const name = enc.encode(e.name);
    const raw = typeof e.data === "string" ? enc.encode(e.data) : (e.data ?? new Uint8Array());
    const body = e.deflate === true ? new Uint8Array(deflateRawSync(raw)) : raw;
    const method = e.method ?? (e.deflate === true ? 8 : 0);
    const size = e.size ?? raw.length;
    const local = new Uint8Array(30 + name.length + body.length);
    const lv = new DataView(local.buffer);
    lv.setUint32(0, 0x04034b50, true);
    lv.setUint16(6, e.flags ?? 0, true);
    lv.setUint16(8, method, true);
    lv.setUint32(18, body.length, true);
    lv.setUint32(22, size, true);
    lv.setUint16(26, name.length, true);
    local.set(name, 30);
    local.set(body, 30 + name.length);
    const central = new Uint8Array(46 + name.length);
    const cv = new DataView(central.buffer);
    cv.setUint32(0, 0x02014b50, true);
    cv.setUint16(8, e.flags ?? 0, true);
    cv.setUint16(10, method, true);
    cv.setUint32(20, body.length, true);
    cv.setUint32(24, size, true);
    cv.setUint16(28, name.length, true);
    cv.setUint32(42, offset, true);
    central.set(name, 46);
    locals.push(local);
    centrals.push(central);
    offset += local.length;
  }
  const dirSize = centrals.reduce((n, c) => n + c.length, 0);
  const note = enc.encode(comment);
  const end = new Uint8Array(22 + note.length);
  const ev = new DataView(end.buffer);
  ev.setUint32(0, 0x06054b50, true);
  ev.setUint16(8, entries.length, true);
  ev.setUint16(10, entries.length, true);
  ev.setUint32(12, dirSize, true);
  ev.setUint32(16, offset, true);
  ev.setUint16(20, note.length, true);
  end.set(note, 22);
  const out = new Uint8Array(offset + dirSize + end.length);
  let p = 0;
  for (const part of [...locals, ...centrals, end]) {
    out.set(part, p);
    p += part.length;
  }
  return out;
}
