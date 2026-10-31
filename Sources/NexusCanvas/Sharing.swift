import CryptoKit
import Foundation
import NexusCore
import NexusFormat
import NexusInterchange
import NexusReplica
import NexusScene
import Observation

/// Share links (M44): the app seals a viewer bundle, then hands the sealed bytes to
/// `OpenNexusNet.xpc`, the one process allowed to use the network (D313). Destinations and
/// link records live in the app's container, their secrets in the Keychain, and nothing is
/// written into the document.

// MARK: The way to the network

public protocol ShareTransport: Sendable {
    func perform(_ job: NetJob, body: Data) async -> NetReply
    /// The reply and the bytes a sync `get` read (M45).
    func exchange(_ job: NetJob, body: Data) async -> (reply: NetReply, body: Data)
}

extension ShareTransport {
    public func exchange(_ job: NetJob, body: Data) async -> (reply: NetReply, body: Data) {
        (await perform(job, body: body), Data())
    }
}

/// The way to the network an app supplies where NexusCanvas has none of its own: on iOS,
/// `NexusNet` in the app's process (M47b), behind the same switches and request log.
@MainActor
public protocol NetworkProvider {
    func transport() -> any ShareTransport
    func connector(purpose: String, log: NetworkLog) -> any RoomConnector
}

/// What the network centres are built with on this platform (M47a): on the Mac, the
/// `OpenNexusNet.xpc` service. Elsewhere the provider the app installs (M47b); without
/// one, requests fail and sockets close at once. Secrets are in the Keychain on both.
@MainActor
public enum PlatformNetwork {
    public static var provider: (any NetworkProvider)?

    static func transport() -> any ShareTransport {
        #if os(macOS)
        XPCShareTransport()
        #else
        provider?.transport() ?? NoNetwork()
        #endif
    }

    static func secrets(service: String = "org.opennexus.sharing") -> any SecretStore {
        KeychainSecrets(service: service)
    }

    static func connector(purpose: String, log: NetworkLog) -> any RoomConnector {
        #if os(macOS)
        XPCRoomConnector(purpose: purpose) { entries in
            Task { @MainActor in log.append(entries) }
        }
        #else
        provider?.connector(purpose: purpose, log: log) ?? NoNetwork()
        #endif
    }
}

/// No way to the network: every request fails and every socket closes.
struct NoNetwork: ShareTransport, RoomConnector {
    static let why = "This device has no way to the network yet."

    func perform(_ job: NetJob, body: Data) async -> NetReply { .failed(Self.why) }

    func open(_ url: URL, events: @escaping @Sendable (SocketEvent) -> Void) -> any RoomSocket {
        events(.closed(Self.why))
        return Closed()
    }

    final class Closed: RoomSocket {
        func send(_ text: String) {}
        func close() {}
    }
}

// MARK: Secrets

/// Destination credentials and link keys.
public protocol SecretStore: Sendable {
    func secret(_ account: String) -> Data?
    func setSecret(_ data: Data, _ account: String)
    func deleteSecret(_ account: String)
}

/// Secrets in memory (tests).
public final class MemorySecrets: SecretStore, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()
    public init() {}
    public var accounts: [String] { lock.withLock { items.keys.sorted() } }
    public func secret(_ account: String) -> Data? { lock.withLock { items[account] } }
    public func setSecret(_ data: Data, _ account: String) { lock.withLock { items[account] = data } }
    public func deleteSecret(_ account: String) { _ = lock.withLock { items.removeValue(forKey: account) } }
}

// MARK: Records

/// What a link holds: the export's scope.
public struct ShareScope: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case document, canvas, branch, zone }
    public var kind: Kind
    public var canvas: String?
    /// The branch's topic or the zone.
    public var item: String?
    /// Its name when shared, for lists.
    public var title: String

    public init(kind: Kind, canvas: String? = nil, item: String? = nil, title: String) {
        self.kind = kind
        self.canvas = canvas
        self.item = item
        self.title = title
    }
}

/// A link someone made: enough to show, copy, update and revoke it. The key isn't here
/// (it's in the Keychain), so the record alone can't open the map.
public struct ShareRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// The document's name and file path when shared (the path matches "Update when I save").
    public var document: String
    public var path: String?
    public var scope: ShareScope
    public var notes = true
    public var comments = true
    public var attachments = false
    public var expanded = true
    public var mask = false
    public var theme: String?
    public var destination: String
    public var object = ""
    public var locator = ""
    public var source = ShareLinkCode.Source.url
    public var created = Date()
    public var updated = Date()
    public var expires: Date?
    public var password = false
    public var autoUpdate = false

    public init(id: String = UUID().uuidString, document: String, path: String?, scope: ShareScope, destination: String)
    {
        self.id = id
        self.document = document
        self.path = path
        self.scope = scope
        self.destination = destination
    }

    public func isExpired(_ now: Date = Date()) -> Bool { expires.map { $0 <= now } ?? false }

    var keyAccount: String { "link:\(id)" }
}

/// A link's secrets: its key (for a password link, the key the password derives, so
/// Update needn't ask again), the KDF, and the server's write secret.
struct LinkSecrets: Codable {
    var key: Data
    var iterations: Int?
    var salt: Data?
    var writeSecret: String?

    var kdf: Sealed.KDF? {
        guard let iterations, let salt else { return nil }
        return Sealed.KDF(iterations: iterations, salt: salt)
    }
}

// MARK: Store

/// Destinations and links, in one JSON file in the app's container.
@MainActor
@Observable
public final class ShareStore {
    public private(set) var destinations: [ShareDestination] = []
    public private(set) var links: [ShareRecord] = []
    @ObservationIgnored let file: URL?

    struct Saved: Codable {
        var destinations: [ShareDestination]
        var links: [ShareRecord]
    }

    /// `file` nil keeps everything in memory.
    public init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file), let s = try? Self.decoder.decode(Saved.self, from: data) {
            destinations = s.destinations
            links = s.links
        }
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    func save() {
        guard let file, let data = try? Self.encoder.encode(Saved(destinations: destinations, links: links)) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic])
    }

    public func destination(_ id: String) -> ShareDestination? { destinations.first { $0.id == id } }

    func put(_ d: ShareDestination) {
        if let i = destinations.firstIndex(where: { $0.id == d.id }) {
            destinations[i] = d
        } else {
            destinations.append(d)
        }
        save()
    }

    func removeDestination(_ id: String) {
        destinations.removeAll { $0.id == id }
        save()
    }

    func put(_ r: ShareRecord) {
        if let i = links.firstIndex(where: { $0.id == r.id }) { links[i] = r } else { links.insert(r, at: 0) }
        save()
    }

    func removeLink(_ id: String) {
        links.removeAll { $0.id == id }
        save()
    }
}

// MARK: Request log

/// Every request the network service made (the Privacy card's log, D313 rule 4): time,
/// host, method, purpose, status and bytes. Kept for 30 days.
@MainActor
@Observable
public final class NetworkLog {
    public private(set) var entries: [NetLogEntry] = []
    @ObservationIgnored let file: URL?
    public static let keepDays = 30

    public init(file: URL?) {
        self.file = file
        if let file, let data = try? Data(contentsOf: file),
            let e = try? ShareStore.decoder.decode([NetLogEntry].self, from: data)
        {
            entries = e
        }
    }

    public func append(_ new: [NetLogEntry], now: Date = Date()) {
        guard !new.isEmpty else { return }
        let cutoff = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        entries = (entries + new).filter { $0.date >= cutoff }
        guard let file, let data = try? ShareStore.encoder.encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: [.atomic])
    }

    public func recent(days: Int = 7, now: Date = Date()) -> [NetLogEntry] {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        return entries.filter { $0.date >= cutoff }
    }

    /// The log as CSV, for Export Log….
    public func csv() -> String {
        var out = "time,host,method,purpose,status,bytes sent,bytes received\n"
        for e in entries {
            let purpose =
                e.purpose.contains(",") || e.purpose.contains("\"")
                ? "\"" + e.purpose.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : e.purpose
            out += "\(Sealed.timestamp(e.date)),\(e.host),\(e.method),\(purpose),\(e.status),\(e.sent),\(e.received)\n"
        }
        return out
    }
}

// MARK: The coordinator

/// Creates, updates and revokes links; tests and sets up destinations. Every network job
/// goes through `run`, which refuses while the network is off and logs what the service did.
@MainActor
@Observable
public final class ShareCenter {
    public static let shared = ShareCenter(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "OpenNexus/Sharing"))

    public let store: ShareStore
    public let log: NetworkLog
    @ObservationIgnored public var secrets: any SecretStore
    @ObservationIgnored public var transport: any ShareTransport
    @ObservationIgnored public var prefs: Preferences
    /// Jobs in flight (the sheets show progress).
    public private(set) var busy = 0

    public init(
        store: ShareStore, log: NetworkLog, secrets: any SecretStore, transport: any ShareTransport,
        prefs: Preferences = .shared
    ) {
        self.store = store
        self.log = log
        self.secrets = secrets
        self.transport = transport
        self.prefs = prefs
    }

    convenience init(directory: URL?) {
        self.init(
            store: ShareStore(file: directory?.appending(path: "sharing.json")),
            log: NetworkLog(file: directory?.appending(path: "network-log.json")), secrets: PlatformNetwork.secrets(),
            transport: PlatformNetwork.transport())
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case networkOff
        case noDestination
        case noCredential(String)
        case failed(String)

        public var description: String {
            switch self {
            case .networkOff:
                Loc.t("Share links use the network, which is off. Turn it on in Settings › Privacy & Data.")
            case .noDestination: Loc.t("Add a place to store links in Settings › Sharing.")
            case .noCredential(let name): Loc.f("%@ has no credential saved. Edit it in Settings › Sharing.", name)
            case .failed(let why): why
            }
        }
    }

    /// The master switch and the feature's own (both off on a fresh install).
    public var networkOn: Bool { prefs.bool("network.enabled") && prefs.bool("network.sharing") }

    /// Where readers open links (Settings › Sharing › Viewer address).
    public var viewer: String {
        let v = prefs.string("sharing.viewerAddress").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? Self.defaultViewer : v
    }

    public static let defaultViewer = "https://jvaudio.github.io/opennexus/"

    /// The service's allow-list: the hosts of every configured destination.
    public var allowedHosts: [String] { Array(Set(store.destinations.flatMap(\.hosts))).sorted() }

    // MARK: Destinations

    public func credential(_ d: ShareDestination) -> String? {
        secrets.secret("dest:\(d.id)").flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Saves a destination; a nil `secret` keeps the one already saved.
    public func saveDestination(_ d: ShareDestination, secret: String?) {
        if let secret { secrets.setSecret(Data(secret.utf8), "dest:\(d.id)") }
        store.put(d)
    }

    /// Removes a destination and its credential. Its links stay listed, but can no longer be
    /// updated or revoked from here.
    public func removeDestination(_ id: String) {
        secrets.deleteSecret("dest:\(id)")
        store.removeDestination(id)
    }

    public func test(_ d: ShareDestination) async -> NetReply {
        await run(job(.test, d, purpose: Loc.t("Test destination"), origin: ShareLinkCode.origin(viewer)), body: Data())
    }

    public func setUpCORS(_ d: ShareDestination) async -> NetReply {
        await run(job(.setUpCORS, d, purpose: Loc.t("Set up CORS"), origin: ShareLinkCode.origin(viewer)), body: Data())
    }

    func job(_ action: NetJob.Action, _ d: ShareDestination, purpose: String, origin: String? = nil) -> NetJob {
        NetJob(
            action: action, purpose: purpose, destination: d, secret: credential(d) ?? "", allowedHosts: allowedHosts,
            origin: origin)
    }

    func run(_ job: NetJob, body: Data) async -> NetReply {
        guard networkOn else { return .failed(Failure.networkOff.description) }
        // A server's shares are changed with their own write secret, not the upload token.
        let usesWriteSecret = job.destination.kind == .server && (job.action == .update || job.action == .delete)
        if !usesWriteSecret, job.secret.isEmpty {
            return .failed(Failure.noCredential(job.destination.name).description)
        }
        busy += 1
        defer { busy -= 1 }
        let reply = await transport.perform(job, body: body)
        log.append(reply.log)
        return reply
    }

    // MARK: Links

    /// Seals `bundle` and stores it at `record.destination`; the record comes back with
    /// where it went. A password replaces the key in the link.
    public func create(_ bundle: JSONValue, record: ShareRecord, password: String?) async throws -> ShareRecord {
        guard networkOn else { throw Failure.networkOff }
        guard let d = store.destination(record.destination) else { throw Failure.noDestination }
        var r = record
        let s = try await secrets(password: password)
        r.password = s.kdf != nil
        let body = try Self.seal(bundle, s, expires: r.expires)
        var j = job(.create, d, purpose: Loc.t("Share link"))
        j.expires = r.expires
        let reply = await run(j, body: body)
        guard reply.ok, let object = reply.object, let locator = reply.locator, let source = reply.source else {
            throw Failure.failed(reply.error ?? Loc.t("The destination didn’t say where it stored the link."))
        }
        r.object = object
        r.locator = locator
        r.source = source
        r.created = Date()
        r.updated = r.created
        var saved = s
        saved.writeSecret = reply.writeSecret
        if let data = try? JSONEncoder().encode(saved) { secrets.setSecret(data, r.keyAccount) }
        store.put(r)
        return r
    }

    /// Re-publishes to the same place with the same key, so the link doesn't change.
    public func update(_ record: ShareRecord, bundle: JSONValue) async throws {
        guard networkOn else { throw Failure.networkOff }
        guard let d = store.destination(record.destination) else { throw Failure.noDestination }
        guard let s = linkSecrets(record) else {
            throw Failure.failed(Loc.t("This link’s key is missing from the Keychain."))
        }
        let body = try Self.seal(bundle, s, expires: record.expires)
        var j = job(.update, d, purpose: Loc.t("Update share link"))
        j.object = record.object
        j.writeSecret = s.writeSecret
        j.expires = record.expires
        let reply = await run(j, body: body)
        guard reply.ok else { throw Failure.failed(reply.error ?? "") }
        var r = record
        r.updated = Date()
        store.put(r)
    }

    /// Deletes the stored object, then the record and its key.
    public func revoke(_ record: ShareRecord) async throws {
        guard networkOn else { throw Failure.networkOff }
        if let d = store.destination(record.destination) {
            var j = job(.delete, d, purpose: Loc.t("Revoke share link"))
            j.object = record.object
            j.writeSecret = linkSecrets(record)?.writeSecret
            let reply = await run(j, body: Data())
            guard reply.ok else { throw Failure.failed(reply.error ?? "") }
        }
        forget(record)
    }

    /// Drops a record and its key without touching the destination (its object is gone, or
    /// its destination was removed).
    public func forget(_ record: ShareRecord) {
        secrets.deleteSecret(record.keyAccount)
        store.removeLink(record.id)
    }

    public func setAutoUpdate(_ record: ShareRecord, _ on: Bool) {
        var r = record
        r.autoUpdate = on
        store.put(r)
    }

    /// Expired links' objects are deleted when the network is on (a bucket or gist keeps
    /// them otherwise; the viewer refuses them either way, from the sealed header).
    public func sweepExpired(now: Date = Date()) async {
        guard networkOn else { return }
        for r in store.links where r.isExpired(now) { try? await revoke(r) }
    }

    /// The link to give out: the viewer, then the fragment with the key.
    public func link(_ record: ShareRecord) -> String? {
        let s = linkSecrets(record)
        guard record.password || s != nil else { return nil }
        let code = ShareLinkCode(source: record.source, locator: record.locator, key: record.password ? nil : s?.key)
        return code.link(viewer: viewer)
    }

    func linkSecrets(_ r: ShareRecord) -> LinkSecrets? {
        secrets.secret(r.keyAccount).flatMap { try? JSONDecoder().decode(LinkSecrets.self, from: $0) }
    }

    /// A fresh random key, or the key a password derives (off the main thread: PBKDF2 at
    /// 600,000 rounds takes a moment).
    func secrets(password: String?) async throws -> LinkSecrets {
        guard let password, !password.isEmpty else {
            return LinkSecrets(key: Sealed.randomBytes(32))
        }
        let kdf = Sealed.KDF.random()
        let key = await Task.detached { Sealed.key(password: password, kdf: kdf) }.value
        return LinkSecrets(key: key.withUnsafeBytes { Data($0) }, iterations: kdf.iterations, salt: kdf.salt)
    }

    static func seal(_ bundle: JSONValue, _ s: LinkSecrets, expires: Date?) throws -> Data {
        try Sealed.seal(
            bundle: bundle, header: Sealed.Header(expires: expires, kdf: s.kdf), key: SymmetricKey(data: s.key))
    }

    // MARK: Open in OpenNexus (M47d, D441)

    /// The code in what the user opened: `opennexus://view#…`, a share page's link, or the
    /// part after its `#`.
    public static func linkCode(_ text: String) -> ShareLinkCode? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fragment = t.firstIndex(of: "#").map { String(t[t.index(after: $0)...]) } ?? t
        return ShareLinkCode(fragment: fragment)
    }

    /// Reads and opens a share link someone sent: the map it carries, as the viewer site
    /// opens it. The network service reaches only the link's own hosts, behind both switches,
    /// and logs every request. A password link needs the key its password derives, which the
    /// viewer site's Open in OpenNexus puts in the link.
    public func openLink(_ text: String, now: Date = Date()) async throws -> JSONValue {
        guard let code = Self.linkCode(text) else {
            throw Failure.failed(Loc.t("This isn’t a share link, or part of it is missing."))
        }
        guard networkOn else { throw Failure.networkOff }
        guard let key = code.key else {
            throw Failure.failed(
                Loc.t(
                    "This link opens with a password. Open it in your browser, enter the password, then choose Open in OpenNexus."
                ))
        }
        busy += 1
        defer { busy -= 1 }
        let (reply, sealed) = await transport.exchange(
            NetJob.read(code, purpose: Loc.t("Open share link")), body: Data())
        log.append(reply.log)
        guard reply.ok else {
            if let status = reply.status, [403, 404, 410].contains(status) {
                throw Failure.failed(Loc.t("This link is turned off. Ask whoever shared it for a new link."))
            }
            throw Failure.failed(Loc.f("Couldn’t read the link: %@", reply.error ?? ""))
        }
        let opened: (header: Sealed.Header, bundle: JSONValue)
        do {
            opened = try Sealed.openBundle(sealed, key: SymmetricKey(data: key))
        } catch Sealed.SealError.newer {
            throw Failure.failed(
                Loc.t("This map was shared from a newer version of OpenNexus. Update OpenNexus to open it."))
        } catch {
            throw Failure.failed(Loc.t("This link is damaged: part of it is missing or was changed."))
        }
        if let e = opened.header.expires, (Sealed.date(e) ?? .distantPast) <= now {
            throw Failure.failed(Loc.t("This link has expired. Ask whoever shared it for a new link."))
        }
        return opened.bundle
    }

    /// The link's map as a new document's content, with its import report (File › Import…'s).
    public func importLink(_ text: String) async throws -> Imported {
        let bundle = try await openLink(text)
        let title = bundle["title"]?.stringValue ?? ""
        return try ViewerBundleImport.parse(
            bundle, name: title.isEmpty ? Loc.t("Shared map") : title, done: Array(Set([Loc.t("Done"), "Done"])),
            localized: { Loc.t($0) })
    }
}
