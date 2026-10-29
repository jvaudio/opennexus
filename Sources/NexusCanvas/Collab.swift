import AppKit
import CryptoKit
import Foundation
import NexusCore
import NexusFormat
import NexusReplica
import Observation

/// Live co-editing (M46): a document's session on an OpenNexus Server. The replica
/// (`NexusReplica`) does the merging; this binds it to a `DocumentStore`, keeps sessions
/// across launches, and reaches the relay through `OpenNexusNet.xpc` like every other
/// network job (D313).

// MARK: The way to the relay

/// A session's socket through the network service: an XPC connection of its own.
public struct XPCRoomConnector: RoomConnector {
    public var purpose: String
    public var onLog: @Sendable ([NetLogEntry]) -> Void

    public init(purpose: String, onLog: @escaping @Sendable ([NetLogEntry]) -> Void) {
        self.purpose = purpose
        self.onLog = onLog
    }

    public func open(_ url: URL, events: @escaping @Sendable (SocketEvent) -> Void) -> any RoomSocket {
        XPCSocket(url: url, purpose: purpose, onLog: onLog, events: events)
    }
}

final class XPCSocket: NSObject, RoomSocket, NetSocketEvents, @unchecked Sendable {
    let connection = NSXPCConnection(serviceName: NetXPC.serviceName)
    let events: @Sendable (SocketEvent) -> Void
    let onLog: @Sendable ([NetLogEntry]) -> Void
    let lock = NSLock()
    var finished = false

    init(
        url: URL, purpose: String, onLog: @escaping @Sendable ([NetLogEntry]) -> Void,
        events: @escaping @Sendable (SocketEvent) -> Void
    ) {
        self.events = events
        self.onLog = onLog
        super.init()
        connection.remoteObjectInterface = NSXPCInterface(with: NetServiceProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: NetSocketEvents.self)
        connection.exportedObject = self
        connection.interruptionHandler = { [weak self] in self?.finish(Loc.t("The network service stopped.")) }
        connection.invalidationHandler = { [weak self] in self?.finish(nil) }
        connection.resume()
        // The socket may reach only the session's own server: the invite's.
        var d = ShareDestination(id: "session", kind: .server, name: url.host() ?? "")
        d.server = url.absoluteString
        let job = NetJob(
            action: .socket, purpose: purpose, destination: d, secret: "",
            allowedHosts: [url.host()?.lowercased() ?? ""], object: url.absoluteString)
        guard let data = try? JSONEncoder().encode(job) else {
            finish(Loc.t("The request couldn’t be encoded."))
            return
        }
        proxy?.openSocket(data)
    }

    var proxy: (any NetServiceProtocol)? {
        connection.remoteObjectProxyWithErrorHandler { [weak self] e in self?.finish(e.localizedDescription) }
            as? any NetServiceProtocol
    }

    func send(_ text: String) { proxy?.sendText(text) }

    func close() {
        proxy?.closeSocket()
        finish(nil)
    }

    func socketOpened(_ log: Data) {
        if let e = try? JSONDecoder().decode(NetLogEntry.self, from: log) { onLog([e]) }
        events(.opened)
    }

    func socketReceived(_ text: String) { events(.text(text)) }

    func socketClosed(_ reason: String?, log: Data) {
        if let e = try? JSONDecoder().decode(NetLogEntry.self, from: log) { onLog([e]) }
        finish(reason)
    }

    func finish(_ why: String?) {
        let first = lock.withLock {
            defer { finished = true }
            return !finished
        }
        guard first else { return }
        events(.closed(why))
        connection.invalidate()
    }
}

// MARK: Records

/// What's kept about a session between launches (in the container, by document id). The
/// invite and the end secret are in the Keychain.
public struct CollabRecord: Codable, Equatable, Sendable {
    public var documentID: String
    public var server: String
    public var room: String
    public var host: Bool
    public var replica: String
    public var saved: RoomClient.Saved
    public var started: Date
}

struct CollabSecrets: Codable {
    var fragment: String
    var end: String?
}

// MARK: The coordinator

/// Starts, joins, resumes and ends sessions. One session per document.
@MainActor
@Observable
public final class CollabCenter {
    public static let shared = CollabCenter(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "OpenNexus/Collab"))

    @ObservationIgnored let directory: URL?
    @ObservationIgnored public var share: ShareCenter
    @ObservationIgnored public var prefs: Preferences
    /// How sockets reach a relay (tests use one in memory).
    @ObservationIgnored public var connector: (any RoomConnector)?
    /// How long a session waits between saves of its replica.
    @ObservationIgnored public var saveDelay = Duration.seconds(1)
    public private(set) var sessions: [String: CollabSession] = [:]

    public init(directory: URL?, share: ShareCenter = .shared, prefs: Preferences = .shared) {
        self.directory = directory
        self.share = share
        self.prefs = prefs
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case networkOff
        case noServer
        case noCredential(String)
        case badInvite
        case failed(String)

        public var description: String {
            switch self {
            case .networkOff:
                Loc.t(
                    "Live sessions use the network, which is off. Turn on “Use the network” and “Live co-editing” in Settings › Privacy & Data."
                )
            case .noServer: Loc.t("Live sessions need an OpenNexus Server. Add one in Settings › Sharing.")
            case .noCredential(let name): Loc.f("%@ has no upload token saved. Edit it in Settings › Sharing.", name)
            case .badInvite: Loc.t("That isn’t an OpenNexus invite link.")
            case .failed(let why): why
            }
        }
    }

    public var networkOn: Bool { prefs.bool("network.enabled") && prefs.bool("network.collab") }
    public var servers: [ShareDestination] { share.store.destinations.filter { $0.kind == .server } }

    /// Your name: Settings › Editing › Comment author, or this Mac's account name.
    public var myName: String {
        let n = prefs.string("editing.commentAuthor").trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? NSFullUserName() : n
    }

    func roomConnector() -> any RoomConnector {
        if let connector { return connector }
        let log = share.log
        return XPCRoomConnector(purpose: Loc.t("Live session")) { entries in
            Task { @MainActor in log.append(entries) }
        }
    }

    // MARK: Starting and joining

    /// Creates a room on `server`, then connects with the whole document as its first batch.
    public func start(store: DocumentStore, documentID: String, server: ShareDestination) async throws
        -> CollabSession
    {
        guard networkOn else { throw Failure.networkOff }
        guard let token = share.credential(server) else { throw Failure.noCredential(server.name) }
        let s = Invite.newSecrets()
        let body: JSONValue = .object([
            "read": .string(Invite.digest(s.read)), "write": .string(Invite.digest(s.write)),
            "end": .string(Invite.digest(s.end)),
        ])
        let job = NetJob(
            action: .createRoom, purpose: Loc.t("Live session"), destination: server, secret: token,
            allowedHosts: server.hosts)
        let reply = await share.transport.perform(job, body: Data(CanonicalJSON.compact(body).utf8))
        share.log.append(reply.log)
        guard reply.ok, let room = reply.object else {
            throw Failure.failed(reply.error ?? Loc.t("The server didn’t create the session."))
        }
        let invite = Invite(server: server.server, room: room, key: s.key, read: s.read, write: s.write)
        let (replica, seed) = Replica.seed(store.model, id: ReplicaID.make())
        let session = CollabSession(
            center: self, documentID: documentID, invite: invite, endSecret: s.end, isHost: true, replica: replica,
            saved: .init())
        share.secrets.setSecret(
            (try? JSONEncoder().encode(CollabSecrets(fragment: invite.fragment, end: s.end))) ?? Data(),
            Self.account(documentID))
        sessions[documentID] = session
        session.bind(store)
        session.client.send(seed)
        session.client.start()
        session.saveNow()
        return session
    }

    /// Joins from an invite link. The session's document arrives with its first welcome
    /// (`onReady`); the app then opens a copy and binds it.
    public func join(_ link: String) throws -> CollabSession {
        guard networkOn else { throw Failure.networkOff }
        guard let invite = Invite(link: link) else { throw Failure.badInvite }
        // Already in it here: the same window.
        if let s = sessions.values.first(where: { $0.invite.room == invite.room }) { return s }
        let documentID = UUID().uuidString
        let session = CollabSession(
            center: self, documentID: documentID, invite: invite, endSecret: nil, isHost: false,
            replica: Replica(id: ReplicaID.make()), saved: .init())
        share.secrets.setSecret(
            (try? JSONEncoder().encode(CollabSecrets(fragment: invite.fragment, end: nil))) ?? Data(),
            Self.account(documentID))
        sessions[documentID] = session
        session.client.start()
        return session
    }

    /// A document opened that was in a session: reconnect, sending what changed offline.
    @discardableResult
    public func resume(store: DocumentStore, documentID: String) -> CollabSession? {
        if let s = sessions[documentID] {
            // A joined session's copy opening: it catches up with what came since it was written.
            if s.store == nil { s.adopt(store) }
            return s
        }
        guard networkOn, let record = record(documentID),
            let data = share.secrets.secret(Self.account(documentID)),
            let secrets = try? JSONDecoder().decode(CollabSecrets.self, from: data),
            let invite = Invite(fragment: secrets.fragment)
        else { return nil }
        var saved = record.saved
        let replica: Replica
        let lost: Bool
        if let d = try? Data(contentsOf: file(documentID, "replica")), let r = try? Replica(decoding: d) {
            replica = r
            lost = false
        } else {
            // The replica is lost: start empty and take the session's state again when it arrives.
            replica = Replica(id: record.replica)
            saved.lastSeq = 0
            saved.outbox = []
            lost = true
        }
        let session = CollabSession(
            center: self, documentID: documentID, invite: invite, endSecret: secrets.end, isHost: record.host,
            replica: replica, saved: saved)
        sessions[documentID] = session
        if lost {
            session.bind(store)
            session.pullOnLive = true
        } else {
            session.adopt(store)
        }
        session.client.start()
        return session
    }

    /// Ends the session for everyone (host) and deletes what the server kept.
    public func end(_ session: CollabSession) async {
        if let secret = session.endSecret, let server = servers.first(where: { $0.server == session.invite.server }) {
            var job = NetJob(
                action: .endRoom, purpose: Loc.t("End live session"), destination: server, secret: "",
                allowedHosts: server.hosts, object: session.invite.room)
            job.writeSecret = secret
            let reply = await share.transport.perform(job, body: Data())
            share.log.append(reply.log)
        } else if let secret = session.endSecret {
            // The server was removed from Settings: reach it from the invite.
            var d = ShareDestination(id: "session", kind: .server, name: "")
            d.server = session.invite.server
            var job = NetJob(
                action: .endRoom, purpose: Loc.t("End live session"), destination: d, secret: "", allowedHosts: d.hosts,
                object: session.invite.room)
            job.writeSecret = secret
            share.log.append(await share.transport.perform(job, body: Data()).log)
        }
        session.client.leave()
        forget(session)
    }

    /// The document closed: the session waits on disk until it opens again.
    public func suspend(_ documentID: String) {
        guard let s = sessions[documentID] else { return }
        s.saveTask?.cancel()
        s.saveTask = nil
        save(s)
        s.client.leave()
        s.unbind()
        sessions[documentID] = nil
    }

    /// Leaves the session; the document stays as it is, on its own.
    public func leave(_ session: CollabSession) {
        session.client.leave()
        forget(session)
    }

    func forget(_ session: CollabSession) {
        session.unbind()
        sessions[session.documentID] = nil
        share.secrets.deleteSecret(Self.account(session.documentID))
        for ext in ["json", "replica"] { try? FileManager.default.removeItem(at: file(session.documentID, ext)) }
    }

    // MARK: Files

    static func account(_ documentID: String) -> String { "collab:\(documentID)" }

    func file(_ documentID: String, _ ext: String) -> URL {
        (directory ?? FileManager.default.temporaryDirectory).appending(path: "\(documentID).\(ext)")
    }

    public func record(_ documentID: String) -> CollabRecord? {
        guard directory != nil, let d = try? Data(contentsOf: file(documentID, "json")) else { return nil }
        return try? ShareStore.decoder.decode(CollabRecord.self, from: d)
    }

    func save(_ s: CollabSession) {
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let r = CollabRecord(
            documentID: s.documentID, server: s.invite.server, room: s.invite.room, host: s.isHost,
            replica: s.client.replica.id, saved: s.client.saved, started: s.started)
        if let d = try? ShareStore.encoder.encode(r) { try? d.write(to: file(s.documentID, "json"), options: .atomic) }
        if let d = try? s.client.replica.encoded() { try? d.write(to: file(s.documentID, "replica"), options: .atomic) }
    }
}

// MARK: A session

/// One document's live session: its client, the people in it, and the store it's bound to.
@MainActor
@Observable
public final class CollabSession: CollabBinding {
    public struct Person: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var colour: String
        public var presence: Presence?
    }

    public let documentID: String
    public let invite: Invite
    public let isHost: Bool
    @ObservationIgnored let endSecret: String?
    @ObservationIgnored public let client: RoomClient
    @ObservationIgnored weak var center: CollabCenter?
    @ObservationIgnored public private(set) weak var store: DocumentStore?
    @ObservationIgnored let started = Date()
    public private(set) var status: RoomClient.Status = .connecting
    public private(set) var people: [Person] = []
    public private(set) var role: RoomClient.Role?
    /// The relay turned an edit down (a view-only invite): its words, once.
    public private(set) var refusal: String?

    /// The first document arrived (joining): the app opens a copy and binds it.
    @ObservationIgnored public var onReady: ((DocumentModel) -> Void)?
    /// Words for VoiceOver: joins, leaves, and who is editing the focused topic.
    @ObservationIgnored public var announce: ((String) -> Void)?
    /// Someone else's edit was applied (the document marks itself edited).
    @ObservationIgnored public var onRemoteChange: (() -> Void)?
    /// Presence changed: overlays redraw.
    @ObservationIgnored public var onPresenceChange: (() -> Void)?
    /// The host ended the session (or the invite stopped working): why.
    @ObservationIgnored public var onEnded: ((String) -> Void)?
    /// An edit was turned away (view only, here or by the relay): why.
    @ObservationIgnored public var onRefused: ((String) -> Void)?
    @ObservationIgnored var saveTask: Task<Void, Never>?
    @ObservationIgnored var readySent = false
    /// The replica was lost: the store takes the session's state once it arrives.
    @ObservationIgnored var pullOnLive = false
    /// The join page's read-only view (the host's): the document as a viewer bundle. Sent
    /// when the session goes live and at most every `viewDelay` while it changes.
    @ObservationIgnored public var makeView: (() -> JSONValue)?
    @ObservationIgnored public var viewDelay = Duration.seconds(30)
    @ObservationIgnored var viewTask: Task<Void, Never>?

    init(
        center: CollabCenter, documentID: String, invite: Invite, endSecret: String?, isHost: Bool, replica: Replica,
        saved: RoomClient.Saved
    ) {
        self.center = center
        self.documentID = documentID
        self.invite = invite
        self.endSecret = endSecret
        self.isHost = isHost
        client = RoomClient(invite: invite, replica: replica, saved: saved, connector: center.roomConnector())
        client.onEvent = { [weak self] e in self?.handle(e) }
        client.onSave = { [weak self] in self?.scheduleSave() }
    }

    public var canEdit: Bool { client.canEdit }

    /// "Live · 3 people", "Reconnecting…", "Offline · changes wait".
    public var statusText: String {
        switch status {
        case .connecting: return Loc.t("Connecting…")
        case .live:
            let n = people.count + 1
            return Loc.f("Live · %@", Loc.n("%lld person", "%lld people", n))
        case .reconnecting:
            return client.saved.outbox.isEmpty ? Loc.t("Reconnecting…") : Loc.t("Offline · changes wait")
        case .ended: return Loc.t("Session ended")
        case .failed(let why): return why
        case .left: return Loc.t("Left the session")
        }
    }

    // MARK: Binding

    /// Starts editing `store` in the session: new ids carry this replica's suffix, and undo
    /// history from before the session is cleared (the app clears its own).
    func bind(_ store: DocumentStore) {
        self.store = store
        store.collab = self
        store.updateDocument { $0.idSuffix = client.replica.idSuffix }
        client.clearHistory()
    }

    /// Binds a document opened from its file. The replica is the session's truth: it's saved
    /// a second after every change, the file less often, so the replica's state replaces the
    /// file's where they differ (outside undo).
    func adopt(_ store: DocumentStore) {
        bind(store)
        pullReplica()
    }

    /// Makes the store's canvases, tab order, theme and assets the replica's.
    func pullReplica() {
        guard let store else { return }
        let doc = client.replica.doc
        let patch = store.model.canvasSetPatch(to: doc, focus: store.model.canvasOrder.first ?? "c1", actionName: "")
        let missing = doc.assets.filter { store.model.assets[$0.key] == nil }
        if !missing.isEmpty { store.updateDocument { $0.assets.merge(missing) { a, _ in a } } }
        if !patch.isEmpty {
            store.applyRemote(patch)
            onRemoteChange?()
        }
    }

    func unbind() {
        viewTask?.cancel()
        viewTask = nil
        guard let store else { return }
        if store.collab === self { store.collab = nil }
        store.updateDocument { $0.idSuffix = "" }
        self.store = nil
        saveTask?.cancel()
    }

    /// A local commit: its ops go out.
    public func committed(_ patch: Patch, store: DocumentStore) {
        client.record(patch, assets: store.model.assets)
        scheduleView()
    }

    public var allowsEdits: Bool { client.canEdit }

    public func refused(_ patch: Patch) {
        onRefused?(Loc.t("This session is view only: your changes aren’t kept"))
    }

    // MARK: Undo

    /// Undoes this participant's last edit, selectively; false when there's nothing to undo.
    @discardableResult
    public func undo() -> Bool { apply(client.undo(), kind: .undone) }

    @discardableResult
    public func redo() -> Bool { apply(client.redo(), kind: .redone) }

    func apply(_ step: Replica.Step?, kind: DocumentStore.ChangeKind) -> Bool {
        guard let step, let store else { return false }
        if !step.changes.assets.isEmpty { store.updateDocument { $0.assets.merge(step.changes.assets) { a, _ in a } } }
        for p in step.changes.patches { store.applyFromUndo(p, kind: kind) }
        return true
    }

    // MARK: Events

    func handle(_ e: RoomClient.Event) {
        switch e {
        case .status(let s):
            status = s
            role = client.role
            if s == .live, pullOnLive {
                pullOnLive = false
                pullReplica()
            }
            if s == .live { sendViewNow() }
            readyIfPossible()
            switch s {
            case .ended:
                onEnded?(Loc.t("The host ended the live session. This copy is yours to keep."))
                center?.forget(self)
            case .failed(let why):
                onEnded?(why)
                center?.forget(self)
            default: break
            }
        case .changes(let c):
            guard let store else { return readyIfPossible() }
            if !c.assets.isEmpty { store.updateDocument { $0.assets.merge(c.assets) { a, _ in a } } }
            for p in c.patches { store.applyRemote(p) }
            onRemoteChange?()
            scheduleView()
        case .joined:
            refreshPeople()
        case .left(_, let p):
            if let p { announce?(Loc.f("%@ left", p.name)) }
            refreshPeople()
        case .presence(let m, let p):
            let known = people.first { $0.id == m }?.presence != nil
            refreshPeople()
            if !known { announce?(Loc.f("%@ joined", p.name)) }
            onPresenceChange?()
        case .refused(let why):
            refusal = why
            onRefused?(why)
        }
    }

    /// Joining: once live with a document to show (the host's first batch may come later).
    func readyIfPossible() {
        guard !readySent, store == nil, status == .live, !client.replica.doc.canvases.isEmpty else { return }
        readySent = true
        var doc = client.replica.doc
        doc.manifestExtra["documentID"] = .string(documentID)
        doc.idSuffix = ""
        onReady?(doc)
    }

    func refreshPeople() {
        var out: [Person] = client.people.map {
            Person(id: $0.key, name: $0.value.name, colour: $0.value.colour, presence: $0.value)
        }
        for m in client.unnamed where client.people[m] == nil {
            out.append(Person(id: m, name: Loc.t("Joining…"), colour: "#8a8a8e", presence: nil))
        }
        people = out.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        onPresenceChange?()
    }

    /// Where this participant is (the canvas sends it whenever it changes; at most ten a second leave).
    public func setPresence(canvas: CanvasID, selection: [NodeID], editing: NodeID?, viewport: CGRect?) {
        let me = Presence(
            replica: client.replica.id, name: center?.myName ?? "", canvas: canvas.rawValue,
            selection: selection.map(\.rawValue), editing: editing?.rawValue,
            viewport: viewport.map { [$0.minX, $0.minY, $0.width, $0.height] })
        client.setPresence(me)
    }

    /// The other people editing this topic now.
    public func editors(of node: NodeID, on canvas: CanvasID) -> [Person] {
        people.filter { $0.presence?.canvas == canvas.rawValue && $0.presence?.editing == node.rawValue }
    }

    // MARK: Saving

    func scheduleSave() {
        guard saveTask == nil, let center else { return }
        let delay = center.saveDelay
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.saveTask = nil
            self.saveNow()
        }
    }

    public func saveNow() {
        guard store != nil || client.saved.lastSeq > 0 else { return }
        center?.save(self)
    }

    /// The join page's view, sealed with the session's key (the relay can't read it).
    public func sendViewNow() {
        viewTask?.cancel()
        viewTask = nil
        guard isHost, let bundle = makeView?(),
            let data = try? Sealed.seal(bundle: bundle, header: Sealed.Header(), key: invite.symmetricKey)
        else { return }
        client.sendView(data)
    }

    func scheduleView() {
        guard isHost, makeView != nil, viewTask == nil else { return }
        let delay = viewDelay
        viewTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.viewTask = nil
            self.sendViewNow()
        }
    }
}
