import Foundation

/// What the app and its network service (`OpenNexusNet.xpc`, M44) say to each other, and
/// the share link's format. The app never touches the network: it seals, then asks the
/// service to carry the sealed bytes to a destination the user configured.

/// Where share links are stored. Secrets (an S3 secret key, a GitHub token, a server's
/// upload token) live in the Keychain, never here.
public struct ShareDestination: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// An S3-compatible bucket: AWS S3, Cloudflare R2, Backblaze B2, Wasabi, MinIO.
        case s3
        /// A secret GitHub gist.
        case gist
        /// A self-hosted OpenNexus Server.
        case server
    }

    public var id: String
    public var kind: Kind
    public var name: String
    // S3-compatible
    /// The API endpoint, such as `https://s3.eu-west-1.amazonaws.com`.
    public var endpoint = ""
    public var region = "us-east-1"
    public var bucket = ""
    /// Prepended to every object's key.
    public var prefix = "opennexus/"
    public var accessKey = ""
    /// Where readers fetch objects, such as `https://pub-1234.r2.dev/`; empty for the
    /// endpoint's own path-style address.
    public var publicBase = ""
    /// `endpoint/bucket/key` (MinIO, R2, B2) rather than `bucket.endpoint/key`.
    public var pathStyle = true
    // OpenNexus Server
    public var server = ""

    public init(id: String = UUID().uuidString, kind: Kind, name: String) {
        self.id = id
        self.kind = kind
        self.name = name
    }

    /// GitHub's API, the only host a gist destination talks to.
    public static let githubAPI = "https://api.github.com"

    /// A bucket object's key: `name` under the prefix.
    public func objectKey(_ name: String) -> String {
        var p = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if !p.isEmpty { p += "/" }
        return p + name
    }

    /// The hosts this destination may reach (the service's allow-list for its jobs).
    public var hosts: [String] {
        let urls: [String] =
            switch kind {
            case .s3: [endpoint, publicBase]
            case .gist: [Self.githubAPI]
            case .server: [server]
            }
        return Array(Set(urls.compactMap { URL(string: $0)?.host()?.lowercased() })).sorted()
    }

    /// The configuration is complete enough to try.
    public var isComplete: Bool {
        switch kind {
        case .s3:
            Self.web(endpoint) && !bucket.isEmpty && !accessKey.isEmpty && (publicBase.isEmpty || Self.web(publicBase))
        case .gist: true
        case .server: Self.web(server)
        }
    }

    /// An address that's `http` to somewhere other than this Mac.
    public var hasInsecureAddress: Bool {
        let addresses: [String] =
            switch kind {
            case .s3: [endpoint, publicBase]
            case .gist: []
            case .server: [server]
            }
        return addresses.contains { URL(string: $0)?.scheme?.lowercased() == "http" && !Self.web($0) }
    }

    static func web(_ s: String) -> Bool { URL(string: s).map(secure) ?? false }

    /// `https`, or `http` to this Mac only (MinIO or a server in Docker while testing).
    /// Elsewhere plain HTTP would carry tokens in the clear, and the viewer, an https page,
    /// couldn't read from it anyway.
    public static func secure(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return false }
        return scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
    }
}

/// One thing for the service to do.
public struct NetJob: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable {
        /// Store a new object (the body); the reply says where.
        case create
        /// Replace `object`, so its link doesn't change.
        case update
        /// Delete `object`.
        case delete
        /// Check the destination works: store, read back and delete a probe.
        case test
        /// S3: allow the viewer's origin to read the bucket (its CORS rule).
        case setUpCORS
        // A sync library's bucket (M45): `object` is a key under the prefix.
        /// Read an object and its ETag (the reply's body); a missing one isn't an error.
        case get
        /// Store the body at `object`, if `ifMatch` / `ifNoneMatch` hold.
        case put
        /// Every key under `object`.
        case list
        /// Check the bucket works for sync, and whether it honours conditional writes.
        case syncTest
        // A live session's room on an OpenNexus Server (M46).
        /// Create a room: the body is the capabilities' SHA-256 (JSON); the reply's `object`
        /// is the room's id.
        case createRoom
        /// End `object`'s room (`writeSecret`: the end secret); the server deletes its data.
        case endRoom
        /// A live session's WebSocket, opened with `openSocket`: `object` is its address.
        case socket
        /// Read a share link's sealed map for Open in OpenNexus (M47d, D441): `object` is the
        /// link's locator and `source` its kind. The service reaches only the hosts the link
        /// names, worked out from the link itself; the reply's body is the sealed bytes.
        case read
    }

    public var action: Action
    /// Why, in words, for the request log ("Share link", "Test destination").
    public var purpose: String
    public var destination: ShareDestination
    /// The destination's credential: an S3 secret key, a GitHub token, or a server's upload token.
    public var secret: String
    /// Hosts the service may reach for this job: those of every configured destination.
    public var allowedHosts: [String]
    /// The stored object (update, delete): an S3 key, a gist id or a server's share id.
    public var object: String?
    /// The server's per-share write secret (update, delete).
    public var writeSecret: String?
    public var expires: Date?
    /// The viewer's origin, for `setUpCORS`.
    public var origin: String?
    /// `put`: replace only this version. `get`: answer "not modified" if it's still this one.
    public var ifMatch: String?
    /// `put`: `*` creates only. `get`: an ETag, as for `ifMatch`.
    public var ifNoneMatch: String?
    /// `read`: where the link's locator points (a URL, or a gist).
    public var source: ShareLinkCode.Source?

    public init(
        action: Action, purpose: String, destination: ShareDestination, secret: String, allowedHosts: [String],
        object: String? = nil, writeSecret: String? = nil, expires: Date? = nil, origin: String? = nil,
        ifMatch: String? = nil, ifNoneMatch: String? = nil
    ) {
        self.action = action
        self.purpose = purpose
        self.destination = destination
        self.secret = secret
        self.allowedHosts = allowedHosts
        self.object = object
        self.writeSecret = writeSecret
        self.expires = expires
        self.origin = origin
        self.ifMatch = ifMatch
        self.ifNoneMatch = ifNoneMatch
    }

    /// Reads `link`'s sealed map (D441). It has no destination of the user's: the link is
    /// what the user opened, and its hosts are the only ones the service may reach.
    public static func read(_ link: ShareLinkCode, purpose: String) -> NetJob {
        var j = NetJob(
            action: .read, purpose: purpose,
            destination: ShareDestination(id: "link", kind: link.source == .gist ? .gist : .server, name: purpose),
            secret: "", allowedHosts: [], object: link.locator)
        j.source = link.source
        return j
    }
}

/// What the service did. Every request it made is in `log`, success or not.
public struct NetReply: Codable, Equatable, Sendable {
    public var ok: Bool
    public var error: String?
    /// The created object, for later updates and deletes.
    public var object: String?
    /// Where readers fetch a created object: a URL, or a gist id.
    public var locator: String?
    public var source: ShareLinkCode.Source?
    public var writeSecret: String?
    /// What a test found, in words.
    public var detail: String?
    /// A bucket operation's answer (M45): 200, 304 (not modified), 404 (missing) or 412
    /// (a condition failed).
    public var status: Int?
    public var etag: String?
    /// `list`: keys under the prefix, without it.
    public var keys: [String]?
    /// `syncTest`: the bucket honours `If-Match` and `If-None-Match`.
    public var conditionalWrites: Bool?
    public var log: [NetLogEntry]

    public init(
        ok: Bool, error: String? = nil, object: String? = nil, locator: String? = nil,
        source: ShareLinkCode.Source? = nil, writeSecret: String? = nil, detail: String? = nil, status: Int? = nil,
        etag: String? = nil, log: [NetLogEntry] = []
    ) {
        self.ok = ok
        self.error = error
        self.object = object
        self.locator = locator
        self.source = source
        self.writeSecret = writeSecret
        self.detail = detail
        self.status = status
        self.etag = etag
        self.log = log
    }

    public static func failed(_ error: String, log: [NetLogEntry] = []) -> NetReply {
        NetReply(ok: false, error: error, log: log)
    }
}

/// One request, as the Privacy card lists it. Never a path, query or body.
public struct NetLogEntry: Codable, Equatable, Hashable, Sendable {
    public var date: Date
    public var host: String
    public var method: String
    public var purpose: String
    /// The HTTP status, or 0 when no response came (refused, offline).
    public var status: Int
    public var sent: Int
    public var received: Int

    public init(date: Date, host: String, method: String, purpose: String, status: Int, sent: Int, received: Int) {
        self.date = date
        self.host = host
        self.method = method
        self.purpose = purpose
        self.status = status
        self.sent = sent
        self.received = received
    }
}

/// The service's XPC interface: a JSON `NetJob` and the body; a JSON `NetReply` and a
/// body (what `get` read) back.
///
/// A live session's socket (M46) is a connection of its own: `openSocket` with a `.socket`
/// job, then `sendText` and `closeSocket`; what comes back arrives through the app's
/// `NetSocketEvents` on the same connection.
@objc public protocol NetServiceProtocol {
    func perform(_ job: Data, body: Data, reply: @escaping @Sendable (Data, Data) -> Void)
    func openSocket(_ job: Data)
    func sendText(_ text: String)
    func closeSocket()
}

/// The app's side of a socket connection. `log` is a JSON `NetLogEntry`.
@objc public protocol NetSocketEvents {
    func socketOpened(_ log: Data)
    func socketReceived(_ text: String)
    func socketClosed(_ reason: String?, log: Data)
}

public enum NetXPC {
    /// The service's bundle identifier, inside the app's `Contents/XPCServices`.
    public static let serviceName = "com.opennexus.OpenNexus.OpenNexusNet"
}

/// The part of a share link after `#`: `1.<source>.<locator>.<key>`. Browsers never send
/// the fragment to a server, so the key reaches only the reader's browser. The locator is
/// base64url (a URL or a gist id); the key is 32 bytes in base64url, or `pw` for a link
/// opened with a password (D333).
public struct ShareLinkCode: Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        /// Fetch this URL (an S3-compatible bucket, an OpenNexus Server).
        case url = "u"
        /// Fetch this gist through GitHub's API.
        case gist = "g"
    }

    public static let version = 1
    public static let passwordMark = "pw"

    public var source: Source
    public var locator: String
    /// Nil when the link needs a password.
    public var key: Data?

    public init(source: Source, locator: String, key: Data?) {
        self.source = source
        self.locator = locator
        self.key = key
    }

    public var fragment: String {
        "\(Self.version).\(source.rawValue).\(Data(locator.utf8).base64URL()).\(key?.base64URL() ?? Self.passwordMark)"
    }

    public init?(fragment: String) {
        let parts = fragment.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "\(Self.version)", let source = Source(rawValue: parts[1]),
            let l = Data(base64URL: parts[2]), let locator = String(data: l, encoding: .utf8), !locator.isEmpty
        else { return nil }
        self.source = source
        self.locator = locator
        if parts[3] == Self.passwordMark {
            key = nil
        } else {
            guard let k = Data(base64URL: parts[3]), k.count == 32 else { return nil }
            key = k
        }
    }

    /// The whole link on a viewer site (`https://<viewer>/s/#…`).
    public func link(viewer: String) -> String {
        Self.sharePage(viewer) + "#" + fragment
    }

    /// The viewer's share page: its address with a trailing slash, then `s/`.
    public static func sharePage(_ viewer: String) -> String {
        var v = viewer.trimmingCharacters(in: .whitespaces)
        if !v.hasSuffix("/") { v += "/" }
        return v + "s/"
    }

    /// The viewer's origin (scheme, host and port), for a bucket's CORS rule.
    public static func origin(_ viewer: String) -> String? {
        guard let u = URL(string: viewer), let scheme = u.scheme, let host = u.host() else { return nil }
        return "\(scheme)://\(host)" + (u.port.map { ":\($0)" } ?? "")
    }
}
