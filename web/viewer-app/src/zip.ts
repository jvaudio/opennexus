// A zip archive's entries (M47d): enough of the format for a zipped `.nexus` package, as
// Finder, Files and GitHub make them. Stored and deflated entries, read with the browser's
// DecompressionStream. No Zip64, encryption or archives split across disks.

export class ZipError extends Error {}

export interface ZipEntry {
  name: string;
  /** 0 stored, 8 deflated. */
  method: number;
  compressedSize: number;
  size: number;
  /** Where the entry's local header starts. */
  offset: number;
}

/** Inflated entries larger than this together are refused (a zip bomb). */
export const MAX_TOTAL = 256 * 1024 * 1024;

const EOCD = 0x06054b50;
const CENTRAL = 0x02014b50;
const LOCAL = 0x04034b50;

/** The archive's files (not its folders, nor macOS's `__MACOSX` resource forks). */
export function entries(data: Uint8Array): ZipEntry[] {
  const v = new DataView(data.buffer, data.byteOffset, data.byteLength);
  // The end record is the last thing in the file, before a comment of up to 64 KB.
  let end = -1;
  for (let i = data.length - 22; i >= Math.max(0, data.length - 22 - 0xffff); i--) {
    if (v.getUint32(i, true) === EOCD) {
      end = i;
      break;
    }
  }
  if (end < 0) throw new ZipError("not a zip archive");
  const count = v.getUint16(end + 10, true);
  const size = v.getUint32(end + 12, true);
  let p = v.getUint32(end + 16, true);
  if (count === 0xffff || size === 0xffffffff || p === 0xffffffff) throw new ZipError("Zip64 archives aren’t supported");
  if (p + size > end) throw new ZipError("the archive is damaged");
  const decoder = new TextDecoder();
  const out: ZipEntry[] = [];
  let total = 0;
  for (let n = 0; n < count; n++) {
    if (p + 46 > end || v.getUint32(p, true) !== CENTRAL) throw new ZipError("the archive is damaged");
    const flags = v.getUint16(p + 8, true);
    const method = v.getUint16(p + 10, true);
    const compressedSize = v.getUint32(p + 20, true);
    const uncompressed = v.getUint32(p + 24, true);
    const nameLength = v.getUint16(p + 28, true);
    const extra = v.getUint16(p + 30, true);
    const comment = v.getUint16(p + 32, true);
    const offset = v.getUint32(p + 42, true);
    const name = decoder.decode(data.subarray(p + 46, p + 46 + nameLength));
    p += 46 + nameLength + extra + comment;
    if (name.endsWith("/") || name.startsWith("__MACOSX/")) continue;
    if ((flags & 1) !== 0) throw new ZipError("encrypted archives aren’t supported");
    if (method !== 0 && method !== 8) throw new ZipError(`“${name}” is compressed in a way this viewer can’t read`);
    if (compressedSize === 0xffffffff || uncompressed === 0xffffffff || offset === 0xffffffff) {
      throw new ZipError("Zip64 archives aren’t supported");
    }
    total += uncompressed;
    if (total > MAX_TOTAL) throw new ZipError("the archive is too large to open here");
    out.push({ name, method, compressedSize, size: uncompressed, offset });
  }
  return out;
}

/** One entry's bytes, inflated. */
export async function read(data: Uint8Array, e: ZipEntry): Promise<Uint8Array> {
  const v = new DataView(data.buffer, data.byteOffset, data.byteLength);
  if (e.offset + 30 > data.length || v.getUint32(e.offset, true) !== LOCAL) throw new ZipError("the archive is damaged");
  const start = e.offset + 30 + v.getUint16(e.offset + 26, true) + v.getUint16(e.offset + 28, true);
  if (start + e.compressedSize > data.length) throw new ZipError("the archive is damaged");
  const raw = data.subarray(start, start + e.compressedSize);
  const out = e.method === 0 ? raw.slice() : await inflate(raw, e.size);
  if (out.length !== e.size) throw new ZipError("the archive is damaged");
  return out;
}

async function inflate(raw: Uint8Array, size: number): Promise<Uint8Array> {
  const stream = new Blob([raw as BlobPart]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
  const reader = stream.getReader();
  const out = new Uint8Array(size);
  let n = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      // More than the entry says it holds: stop before it fills memory.
      if (n + value.length > size) throw new ZipError("the archive is damaged");
      out.set(value, n);
      n += value.length;
    }
  } catch (e) {
    await reader.cancel().catch(() => undefined);
    throw e instanceof ZipError ? e : new ZipError("the archive is damaged");
  }
  return out.subarray(0, n);
}
