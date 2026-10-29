import CryptoKit
import Foundation
import NexusFormat

/// The part of an invite link after `#` (M46): `2.<server>.<room>.<key>.<read>[.<write>]`,
/// all base64url. Browsers never send a fragment to a server, so the room key reaches only
/// the people the link is given to. The read and write capabilities are random secrets;
/// the relay keeps only their SHA-256. A view-only invite has no write capability.
public struct Invite: Equatable, Sendable {
    public static let version = 2

    /// The relay's address, such as `https://relay.example.com`.
    public var server: String
    /// The relay's room id (22 base64url characters).
    public var room: String
    /// The room key (32 bytes): it seals every message.
    public var key: Data
    public var read: String
    public var write: String?

    public init(server: String, room: String, key: Data, read: String, write: String?) {
        self.server = server
        self.room = room
        self.key = key
        self.read = read
        self.write = write
    }

    public var canEdit: Bool { write != nil }
    public var symmetricKey: SymmetricKey { SymmetricKey(data: key) }

    /// The same room, view only.
    public var viewOnly: Invite {
        var v = self
        v.write = nil
        return v
    }

    public var fragment: String {
        var parts = ["\(Self.version)", Data(server.utf8).base64URL(), room, key.base64URL(), read]
        if let write { parts.append(write) }
        return parts.joined(separator: ".")
    }

    public init?(fragment: String) {
        let parts = fragment.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5 || parts.count == 6, parts[0] == "\(Self.version)",
            let s = Data(base64URL: parts[1]), let server = String(data: s, encoding: .utf8),
            let u = URL(string: server), u.host() != nil, ShareDestination.secure(u),
            Self.isID(parts[2]), let key = Data(base64URL: parts[3]), key.count == 32, Self.isSecret(parts[4])
        else { return nil }
        if parts.count == 6 {
            guard Self.isSecret(parts[5]) else { return nil }
            write = parts[5]
        }
        self.server = server
        room = parts[2]
        self.key = key
        read = parts[4]
    }

    /// Reads a pasted link: the viewer site's `…/join/#…`, `opennexus://join#…`, or the
    /// fragment alone.
    public init?(link: String) {
        let t = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let fragment = t.firstIndex(of: "#").map { String(t[t.index(after: $0)...]) } ?? t
        self.init(fragment: fragment)
    }

    /// The link on a viewer site: `<viewer>/join/#…`.
    public func link(viewer: String) -> String {
        Self.joinPage(viewer) + "#" + fragment
    }

    /// The link that opens the app directly.
    public var appLink: String { "opennexus://join#" + fragment }

    public static func joinPage(_ viewer: String) -> String {
        var v = viewer.trimmingCharacters(in: .whitespaces)
        if !v.hasSuffix("/") { v += "/" }
        return v + "join/"
    }

    /// The relay's WebSocket address for the room.
    public var socketURL: URL? {
        var base = server
        while base.hasSuffix("/") { base.removeLast() }
        guard var c = URLComponents(string: base + "/v1/rooms/" + room) else { return nil }
        c.scheme = c.scheme?.lowercased() == "http" ? "ws" : "wss"
        return c.url
    }

    /// A new room's secrets: a key, both capabilities and the host's end secret.
    public static func newSecrets() -> (key: Data, read: String, write: String, end: String) {
        (Sealed.randomBytes(32), secret(), secret(), secret())
    }

    public static func secret() -> String { Sealed.randomBytes(32).base64URL() }

    /// What the relay keeps of a capability: the SHA-256 of its text, in hex.
    public static func digest(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isID(_ s: String) -> Bool { s.count == 22 && isBase64URL(s) }
    static func isSecret(_ s: String) -> Bool { s.count == 43 && isBase64URL(s) }
    static func isBase64URL(_ s: String) -> Bool {
        s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
