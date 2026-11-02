import CryptoKit
import Foundation
import NexusCore
import NexusFormat

/// A socket to a room's relay, however it gets there: the network service over XPC in the
/// app, NexusNet directly in tools and live tests, or an in-memory relay in unit tests.
public protocol RoomSocket: AnyObject, Sendable {
    func send(_ text: String)
    func close()
}

public enum SocketEvent: Equatable, Sendable {
    case opened
    case text(String)
    /// The socket closed or failed (why, if known). Nothing more comes after it.
    case closed(String?)
}

public protocol RoomConnector: Sendable {
    /// Opens a socket; `events` may be called on any thread, in order.
    func open(_ url: URL, events: @escaping @Sendable (SocketEvent) -> Void) -> any RoomSocket
}

/// One participant's connection to a room (M46): it keeps the replica, sends local edits as
/// sealed op batches, applies everyone else's, and survives the network going away. Every
/// batch waits in the outbox until the relay acknowledges it; after a reconnect the outbox
/// goes again (ops are idempotent, so a batch that arrives twice does no harm).
@MainActor
public final class RoomClient {
    public enum Role: String, Sendable { case edit, view }

    public enum Status: Equatable, Sendable {
        case connecting
        case live
        /// Waiting to try again; local changes wait in the outbox.
        case reconnecting
        /// The host ended the session.
        case ended
        /// The relay refused the invite (wrong capability, or the room is gone): no retries.
        case failed(String)
        /// This client left.
        case left
    }

    public enum Event: Sendable {
        case status(Status)
        /// Someone else's edits, already applied to the replica; the app applies the
        /// patches outside undo.
        case changes(Replica.Changes)
        case joined(member: String)
        case left(member: String, Presence?)
        case presence(member: String, Presence)
        /// The relay turned something down (a view-only participant's edit, a message too
        /// large): its words.
        case refused(String)
    }

    /// What survives a restart besides the replica: the relay sequence applied so far and
    /// the batches not yet acknowledged.
    public struct Saved: Codable, Equatable, Sendable {
        public var lastSeq = 0
        public var nextBatch = 1
        public var outbox: [Outgoing] = []
        public init() {}
    }

    public struct Outgoing: Codable, Equatable, Sendable {
        public var id: Int
        public var data: Data
    }

    public let invite: Invite
    public internal(set) var replica: Replica
    public private(set) var status: Status = .connecting
    public private(set) var role: Role?
    public private(set) var member: String?
    /// Everyone else here, by member id, with their latest presence.
    public private(set) var people: [String: Presence] = [:]
    /// Members who haven't sent a presence yet.
    public private(set) var unnamed: Set<String> = []
    public private(set) var saved: Saved
    public var onEvent: ((Event) -> Void)?
    /// The replica or `saved` changed: time to persist (the app debounces).
    public var onSave: (() -> Void)?

    let connector: any RoomConnector
    let sleep: @Sendable (Duration) async throws -> Void
    let key: SymmetricKey
    var socket: (any RoomSocket)?
    var generation = 0
    var attempt = 0
    var stopped = false
    var presence: Presence?
    var presenceSent: ContinuousClock.Instant?
    var presenceTask: Task<Void, Never>?
    var retryTask: Task<Void, Never>?

    /// Presence goes out at most this often.
    public static let presenceInterval = Duration.milliseconds(100)

    public init(
        invite: Invite, replica: Replica, saved: Saved = Saved(), connector: any RoomConnector,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.invite = invite
        self.replica = replica
        self.saved = saved
        self.connector = connector
        self.sleep = sleep
        key = invite.symmetricKey
    }

    public var canEdit: Bool { role == .edit || (role == nil && invite.canEdit) }

    // MARK: Connecting

    public func start() {
        stopped = false
        connect()
    }

    /// Leaves the room (the session goes on for everyone else).
    public func leave() {
        stopped = true
        retryTask?.cancel()
        presenceTask?.cancel()
        generation += 1
        socket?.close()
        socket = nil
        setStatus(.left)
    }

    func connect() {
        generation += 1
        let g = generation
        guard let url = invite.socketURL else { return setStatus(.failed("The invite’s server address isn’t valid.")) }
        if status != .reconnecting { setStatus(.connecting) }
        let (stream, cont) = AsyncStream<SocketEvent>.makeStream()
        socket = connector.open(url) { e in
            cont.yield(e)
            if case .closed = e { cont.finish() }
        }
        Task { @MainActor [weak self] in
            for await e in stream {
                guard let self, self.generation == g else { return }
                self.handle(e)
            }
        }
    }

    /// 0.5 s, doubling, at most 30 s.
    public static func backoff(_ attempt: Int) -> Duration {
        .milliseconds(Int(min(30_000, 500 * pow(2, Double(min(attempt, 16))))))
    }

    func handle(_ e: SocketEvent) {
        switch e {
        case .opened:
            send(.hello(cap: invite.write ?? invite.read, since: saved.lastSeq))
        case .text(let t):
            guard let f = RelayFrame(text: t) else { return }
            handle(f)
        case .closed:
            socket = nil
            guard !stopped, status != .ended, !isFailed else { return }
            setStatus(.reconnecting)
            let delay = Self.backoff(attempt)
            attempt += 1
            let g = generation
            retryTask = Task { @MainActor [weak self, sleep] in
                try? await sleep(delay)
                guard let self, !Task.isCancelled, !self.stopped, self.generation == g else { return }
                self.connect()
            }
        }
    }

    var isFailed: Bool {
        if case .failed = status { true } else { false }
    }

    func handle(_ f: RelayFrame) {
        switch f {
        case .welcome(let w):
            role = w.role
            member = w.member
            people = [:]
            unnamed = Set(w.members.filter { $0 != w.member })
            var ops: [Op] = []
            if let s = w.snapshot, let o = try? RoomSeal.openSnapshot(s.data, key: key) { ops += o }
            for b in w.ops { ops += (try? RoomSeal.openOps(b.data, key: key)) ?? [] }
            if !ops.isEmpty { deliver(replica.receive(ops)) }
            saved.lastSeq = max(saved.lastSeq, w.seq)
            attempt = 0
            setStatus(.live)
            for b in saved.outbox { send(.ops(id: b.id, data: b.data)) }
            if presence != nil { sendPresenceSoon(now: true) }
            onSave?()
        case .ops(let s):
            if let ops = try? RoomSeal.openOps(s.data, key: key) { deliver(replica.receive(ops)) }
            saved.lastSeq = max(saved.lastSeq, s.seq)
            onSave?()
        case .ack(let id, let seq):
            saved.outbox.removeAll { $0.id == id }
            saved.lastSeq = max(saved.lastSeq, seq)
            onSave?()
        case .presence(let m, let data):
            guard m != member, let p = try? RoomSeal.openPresence(data, key: key) else { return }
            unnamed.remove(m)
            people[m] = p
            onEvent?(.presence(member: m, p))
        case .joined(let m):
            guard m != member else { return }
            unnamed.insert(m)
            onEvent?(.joined(member: m))
            // So the newcomer sees us straight away.
            if presence != nil { sendPresenceSoon() }
        case .left(let m):
            unnamed.remove(m)
            let p = people.removeValue(forKey: m)
            onEvent?(.left(member: m, p))
        case .snapshot:
            sendSnapshot()
        case .ended:
            stopped = true
            setStatus(.ended)
            socket?.close()
        case .error(let code, let message):
            switch code {
            case "unauthorized", "not-found":
                stopped = true
                setStatus(.failed(message))
                socket?.close()
            default:
                onEvent?(.refused(message))
            }
        }
    }

    func deliver(_ changes: Replica.Changes) {
        if !changes.isEmpty { onEvent?(.changes(changes)) }
    }

    func setStatus(_ s: Status) {
        guard status != s else { return }
        status = s
        onEvent?(.status(s))
    }

    func send(_ f: ClientFrame) {
        guard let socket else { return }
        socket.send(f.text)
    }

    // MARK: Local edits

    /// Records a local edit the app has applied and sends its ops. Returns them (empty for
    /// an edit that changed nothing shared).
    @discardableResult
    public func record(_ patch: Patch, assets: [String: Data] = [:]) -> [Op] {
        let ops = replica.record(patch, assets: assets)
        enqueue(ops)
        return ops
    }

    public var canUndo: Bool { replica.canUndo }
    public var canRedo: Bool { replica.canRedo }

    /// Undoes this participant's last edit, selectively: the patches are for the app's store.
    public func undo() -> Replica.Step? {
        guard let step = replica.undo() else { return nil }
        enqueue(step.ops)
        return step
    }

    public func redo() -> Replica.Step? {
        guard let step = replica.redo() else { return nil }
        enqueue(step.ops)
        return step
    }

    public func clearHistory() { replica.clearHistory() }

    /// Sends ops made elsewhere: the host's seed (the whole document, the room's first batch).
    public func send(_ ops: [Op]) { enqueue(ops) }

    func enqueue(_ ops: [Op]) {
        guard !ops.isEmpty, let data = try? RoomSeal.sealOps(ops, replica: replica.id, seq: saved.nextBatch, key: key)
        else { return }
        let b = Outgoing(id: saved.nextBatch, data: data)
        saved.nextBatch += 1
        saved.outbox.append(b)
        if status == .live { send(.ops(id: b.id, data: b.data)) }
        onSave?()
    }

    func sendSnapshot() {
        guard status == .live, role == .edit,
            let data = try? RoomSeal.sealSnapshot(replica.snapshot(), key: key)
        else { return }
        send(.snapshot(seq: saved.lastSeq, data: data))
    }

    /// The join page's read-only view: a sealed viewer bundle (the host sends it now and then).
    public func sendView(_ sealedBundle: Data) {
        guard status == .live, role == .edit else { return }
        send(.view(sealedBundle))
    }

    // MARK: Presence

    /// Where this participant is; sent at most ten times a second.
    public func setPresence(_ p: Presence) {
        guard p != presence else { return }
        presence = p
        sendPresenceSoon()
    }

    func sendPresenceSoon(now: Bool = false) {
        guard presenceTask == nil else { return }
        let elapsed = presenceSent.map { ContinuousClock.now - $0 } ?? Self.presenceInterval
        if now || elapsed >= Self.presenceInterval { return flushPresence() }
        let wait = Self.presenceInterval - elapsed
        presenceTask = Task { @MainActor [weak self, sleep] in
            try? await sleep(wait)
            guard let self, !Task.isCancelled else { return }
            self.presenceTask = nil
            self.flushPresence()
        }
    }

    func flushPresence() {
        guard status == .live, let presence, let data = try? RoomSeal.sealPresence(presence, key: key) else { return }
        presenceSent = .now
        send(.presence(data))
    }
}
