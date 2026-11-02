// A live session's invite (NexusReplica/Invite.swift): `2.<server>.<room>.<key>.<read>[.<write>]`,
// the server's address in base64url, the room's id (22 base64url characters), the session's
// key (32 bytes) and each capability (32 bytes, 43 base64url characters). Without the write
// capability the invite is view only.

import { fromBase64URL, isFetchable } from "./link";

export interface Invite {
  server: string;
  room: string;
  key: Uint8Array;
  read: string;
  write?: string;
}

const ID = /^[A-Za-z0-9_-]{22}$/;
const SECRET = /^[A-Za-z0-9_-]{43}$/;

export function parseInvite(fragment: string): Invite | null {
  const t = fragment.replace(/^#/, "");
  const parts = t.split(".");
  if ((parts.length !== 5 && parts.length !== 6) || parts[0] !== "2") return null;
  const [, s, room, k, read, write] = parts as [string, string, string, string, string, string | undefined];
  const bytes = fromBase64URL(s);
  if (bytes === null || bytes.length === 0) return null;
  let server: string;
  try {
    server = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return null;
  }
  if (!isFetchable(server) || !ID.test(room) || !SECRET.test(read)) return null;
  const key = fromBase64URL(k);
  if (key?.length !== 32) return null;
  if (write !== undefined && !SECRET.test(write)) return null;
  return write === undefined ? { server, room, key, read } : { server, room, key, read, write };
}

/** Where the host's sealed view of the session is (read with the read capability). */
export function viewURL(i: Invite): string {
  return `${i.server.replace(/\/+$/, "")}/v1/rooms/${i.room}/view`;
}

/** The link that opens the app on this Mac with the same invite. */
export function appLink(fragment: string): string {
  return `opennexus://join#${fragment.replace(/^#/, "")}`;
}
