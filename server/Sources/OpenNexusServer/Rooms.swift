import Crypto
import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// Live sessions' rooms (M46): the relay between participants. It numbers, keeps and fans
/// out sealed op batches, passes presence along, and keeps the latest sealed snapshot and
/// viewer bundle. It never sees a key: capabilities arrive as the SHA-256 of secrets that
/// only invite links carry, and every payload is a sealed envelope.
///
/// Rooms live in memory and are written through to `OPENNEXUS_ROOMS_DIR` (sealed bytes and
/// hashes only). A room is deleted when its host ends it, or after `OPENNEXUS_ROOM_IDLE_DAYS`
/// without anyone connected.
public actor RoomHub {
    public enum Role: String, Sendable { case edit, view }

    /// What the relay keeps about a room besides its sealed bytes.
    public struct Record: Codable, Equatable, Sendable {
        /// SHA-256 (hex) of the read and write capabilities and the end secret.
        public var read: String
        public var write: String
        public var end: String
        public var created: Date
        /// When someone was last connected.
        public var active: Date
    }

    struct Entry: Sendable {
        var seq: Int
        var member: String
        var data: Data
    }

    final class Member: @unchecked Sendable {
        let id: String
        let role: Role
        let out: AsyncStream<String>.Continuation
        init(id: String, role: Role, out: AsyncStream<String>.Continuation) {
            self.id = id
            self.role = role
            self.out = out
        }
    }

    final class Room {
        var record: Record
        var seq = 0
        var snapshot: (seq: Int, data: Data)?
        var tail: [Entry] = []
        var view: Data?
        var members: [String: Member] = [:]
        var nextMember = 1
        /// When the relay last asked for a snapshot (it asks again after a while).
        var asked: Date?
        var bytes: Int { (snapshot?.data.count ?? 0) + tail.reduce(0) { $0 + $1.data.count } + (view?.count ?? 0) }
        init(record: Record) { self.record = record }
    }

    public enum Refusal: Error, Equatable, Sendable {
        case unauthorized, notFound, full, tooManyRooms, readOnly, tooLarge, badMessage
        var code: String {
            switch self {
            case .unauthorized: "unauthorized"
            case .notFound: "not-found"
            case .full: "full"
            case .tooManyRooms: "too-many-rooms"
            case .readOnly: "read-only"
            case .tooLarge: "too-large"
            case .badMessage: "bad-message"
            }
        }
        var message: String {
            switch self {
            case .unauthorized: "That invite isn’t valid for this session."
            case .notFound: "This session has ended."
            case .full: "This session is full."
            case .tooManyRooms: "This server has as many sessions as it allows."
            case .readOnly: "You can view this session but not edit it."
            case .tooLarge: "That change is larger than this server allows."
            case .badMessage: "The server didn’t understand a message."
            }
        }
    }

    let config: ServerConfig
    let directory: URL?
    let now: @Sendable () -> Date
    var rooms: [String: Room] = [:]
    var lastSweep = Date.distantPast

    /// The relay asks a writer for a snapshot once the tail is longer than this.
    public static let snapshotAfter = 200

    /// Rooms in memory, written through to `config.roomsDirectory` (created first) if set.
    public init(config: ServerConfig, now: @escaping @Sendable () -> Date = Date.init) throws {
        self.config = config
        self.now = now
        if let dir = config.roomsDirectory {
            let url = URL(fileURLWithPath: dir, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            directory = url
            rooms = Self.load(url)
        } else {
            directory = nil
        }
    }

    /// Rooms in memory only (tests).
    public init(memory config: ServerConfig, now: @escaping @Sendable () -> Date = Date.init) {
        self.config = config
        self.now = now
        directory = nil
    }

    // MARK: HTTP

    public func create(read: String, write: String, end: String) throws -> String {
        sweepIfDue()
        guard rooms.count < config.maxRooms else { throw Refusal.tooManyRooms }
        let id = ShareAPI.random(16)
        let t = now()
        let room = Room(record: Record(read: read, write: write, end: end, created: t, active: t))
        rooms[id] = room
        saveRecord(id, room)
        return id
    }

    /// Ends the room for everyone and deletes what was kept.
    public func end(_ id: String, secret: String) throws {
        guard let room = rooms[id] else { throw Refusal.notFound }
        guard ShareAPI.matches(ShareAPI.digest(secret), room.record.end) else { throw Refusal.unauthorized }
        for m in room.members.values {
            m.out.yield(Frames.ended)
            m.out.finish()
        }
        rooms[id] = nil
        if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent(id)) }
    }

    /// The latest viewer bundle, for anyone holding a capability.
    public func view(_ id: String, cap: String) throws -> Data? {
        guard let room = rooms[id] else { throw Refusal.notFound }
        guard role(room, cap) != nil else { throw Refusal.unauthorized }
        return room.view
    }

    // MARK: Sockets

    /// Joins with a capability; the welcome is the first thing on `out`.
    public func join(_ id: String, cap: String, since: Int, out: AsyncStream<String>.Continuation) throws -> String {
        guard let room = rooms[id] else { throw Refusal.notFound }
        guard let role = role(room, cap) else { throw Refusal.unauthorized }
        guard room.members.count < config.roomMaxMembers else { throw Refusal.full }
        let m = "m\(room.nextMember)"
        room.nextMember += 1
        var snapshot: (Int, Data)?
        var ops = room.tail.filter { $0.seq > since }
        if let s = room.snapshot, since < s.seq {
            snapshot = s
            ops = room.tail
        }
        out.yield(
            Frames.welcome(
                role: role, member: m, members: room.members.keys.sorted(), snapshot: snapshot, ops: ops,
                seq: room.seq))
        for o in room.members.values { o.out.yield(Frames.joined(m)) }
        room.members[m] = Member(id: m, role: role, out: out)
        touch(id, room)
        return m
    }

    public func leave(_ id: String, member: String) {
        guard let room = rooms[id], let m = room.members.removeValue(forKey: member) else { return }
        m.out.finish()
        for o in room.members.values { o.out.yield(Frames.left(member)) }
        touch(id, room)
    }

    /// One frame from a member.
    public func receive(_ id: String, member: String, _ text: String) {
        guard let room = rooms[id], let m = room.members[member] else { return }
        do {
            try handle(id, room, m, text)
        } catch let r as Refusal {
            m.out.yield(Frames.error(r))
        } catch {
            m.out.yield(Frames.error(.badMessage))
        }
    }

    func handle(_ id: String, _ room: Room, _ m: Member, _ text: String) throws {
        guard let f = Frames.parse(text) else { throw Refusal.badMessage }
        switch f.type {
        case "ops":
            guard m.role == .edit else { throw Refusal.readOnly }
            guard let batch = f.id, let data = f.sealed else { throw Refusal.badMessage }
            guard room.bytes + data.count <= config.roomMaxBytes else {
                askForSnapshot(room, m, force: true)
                throw Refusal.tooLarge
            }
            room.seq += 1
            let e = Entry(seq: room.seq, member: m.id, data: data)
            room.tail.append(e)
            append(id, e)
            m.out.yield(Frames.ack(id: batch, seq: e.seq))
            let frame = Frames.ops(e)
            for (k, o) in room.members where k != m.id { o.out.yield(frame) }
            if room.tail.count > Self.snapshotAfter { askForSnapshot(room, m) }
        case "presence":
            guard let data = f.sealed else { throw Refusal.badMessage }
            let frame = Frames.presence(member: m.id, data)
            for (k, o) in room.members where k != m.id { o.out.yield(frame) }
        case "snapshot":
            guard m.role == .edit else { throw Refusal.readOnly }
            guard let seq = f.seq, let data = f.sealed, seq <= room.seq else { throw Refusal.badMessage }
            // An older snapshot than the one kept is no use.
            guard seq >= (room.snapshot?.seq ?? 0) else { return }
            room.snapshot = (seq, data)
            room.tail.removeAll { $0.seq <= seq }
            room.asked = nil
            saveSnapshot(id, room)
        case "view":
            guard m.role == .edit else { throw Refusal.readOnly }
            guard let data = f.sealed else { throw Refusal.badMessage }
            room.view = data
            write(data, id, "view.onx")
        default:
            throw Refusal.badMessage
        }
    }

    /// Asks a writer for a snapshot, at most once a minute.
    func askForSnapshot(_ room: Room, _ m: Member, force: Bool = false) {
        if let a = room.asked, now().timeIntervalSince(a) < 60, !force { return }
        let writer = m.role == .edit ? m : room.members.values.first { $0.role == .edit }
        guard let writer else { return }
        room.asked = now()
        writer.out.yield(Frames.snapshot)
    }

    func role(_ room: Room, _ cap: String) -> Role? {
        let d = ShareAPI.digest(cap)
        if ShareAPI.matches(d, room.record.write) { return .edit }
        if ShareAPI.matches(d, room.record.read) { return .view }
        return nil
    }

    func touch(_ id: String, _ room: Room) {
        room.record.active = now()
        saveRecord(id, room)
    }

    // MARK: Retention

    /// Deletes rooms nobody has been in for `roomIdleDays`; at most every ten minutes.
    func sweepIfDue() {
        guard now().timeIntervalSince(lastSweep) >= 600 else { return }
        sweep()
    }

    @discardableResult
    public func sweep() -> Int {
        lastSweep = now()
        let cutoff = now().addingTimeInterval(-Double(config.roomIdleDays) * 86_400)
        let idle = rooms.filter { $0.value.members.isEmpty && $0.value.record.active < cutoff }.map(\.key)
        for id in idle {
            rooms[id] = nil
            if let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent(id)) }
        }
        return idle.count
    }

    public var roomCount: Int { rooms.count }

    /// A room's numbers, for tests: sequence, snapshot sequence, tail length, members.
    public func stats(_ id: String) -> (seq: Int, snapshot: Int?, tail: Int, members: Int)? {
        rooms[id].map { ($0.seq, $0.snapshot?.seq, $0.tail.count, $0.members.count) }
    }

    // MARK: Files
    //
    // <dir>/<room>/room.json      the record: hashes and dates
    // <dir>/<room>/snapshot.onx   the sequence (8 bytes) and the sealed snapshot
    // <dir>/<room>/tail.log       batches after it: sequence, member, length, sealed bytes
    // <dir>/<room>/view.onx       the sealed viewer bundle

    func folder(_ id: String) -> URL? {
        guard let directory else { return nil }
        let f = directory.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    func write(_ data: Data, _ id: String, _ name: String) {
        guard let f = folder(id) else { return }
        try? data.write(to: f.appendingPathComponent(name), options: .atomic)
    }

    func saveRecord(_ id: String, _ room: Room) {
        guard let d = try? MetaCoding.encoder.encode(room.record) else { return }
        write(d, id, "room.json")
    }

    static func entryBytes(_ e: Entry) -> Data {
        var out = Data()
        withUnsafeBytes(of: UInt64(e.seq).bigEndian) { out.append(contentsOf: $0) }
        let m = Data(e.member.utf8.prefix(255))
        out.append(UInt8(m.count))
        out.append(m)
        withUnsafeBytes(of: UInt32(e.data.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(e.data)
        return out
    }

    func append(_ id: String, _ e: Entry) {
        guard let f = folder(id)?.appendingPathComponent("tail.log") else { return }
        let bytes = Self.entryBytes(e)
        if let h = try? FileHandle(forWritingTo: f) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: bytes)
        } else {
            try? bytes.write(to: f)
        }
    }

    func saveSnapshot(_ id: String, _ room: Room) {
        guard let s = room.snapshot else { return }
        var d = Data()
        withUnsafeBytes(of: UInt64(s.seq).bigEndian) { d.append(contentsOf: $0) }
        write(d + s.data, id, "snapshot.onx")
        write(room.tail.reduce(into: Data()) { $0.append(Self.entryBytes($1)) }, id, "tail.log")
    }

    static func load(_ dir: URL) -> [String: Room] {
        var out: [String: Room] = [:]
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for id in ids where id.count == 22 {
            let f = dir.appendingPathComponent(id, isDirectory: true)
            guard let rd = try? Data(contentsOf: f.appendingPathComponent("room.json")),
                let record = try? MetaCoding.decoder.decode(Record.self, from: rd)
            else { continue }
            let room = Room(record: record)
            if let s = try? Data(contentsOf: f.appendingPathComponent("snapshot.onx")), s.count > 8 {
                room.snapshot = (Int(s.prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }), Data(s.dropFirst(8)))
            }
            if let t = try? Data(contentsOf: f.appendingPathComponent("tail.log")) {
                room.tail = parseTail(Data(t))
            }
            room.view = try? Data(contentsOf: f.appendingPathComponent("view.onx"))
            room.seq = max(room.snapshot?.seq ?? 0, room.tail.last?.seq ?? 0)
            out[id] = room
        }
        return out
    }

    /// The tail's records; a record cut short (the server stopped mid-write) ends it.
    static func parseTail(_ d: Data) -> [Entry] {
        var out: [Entry] = []
        var i = 0
        func int(_ n: Int) -> Int? {
            guard i + n <= d.count else { return nil }
            defer { i += n }
            return Int(d[i..<(i + n)].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        }
        while i < d.count {
            guard let seq = int(8), let ml = int(1), i + ml <= d.count else { break }
            let member = String(decoding: d[i..<(i + ml)], as: UTF8.self)
            i += ml
            guard let n = int(4), i + n <= d.count else { break }
            out.append(Entry(seq: seq, member: member, data: Data(d[i..<(i + n)])))
            i += n
        }
        return out
    }
}

/// The room protocol's frames, as the relay reads and writes them (the app's side is
/// `NexusReplica/RoomProtocol.swift`).
enum Frames {
    struct Parsed {
        var type: String
        var id: Int?
        var seq: Int?
        var cap: String?
        var since: Int?
        /// `data`, decoded, when it's a sealed envelope.
        var sealed: Data?
    }

    /// A field that's nil unless it has the type asked for: `true` is no count, on Linux too.
    struct Loose<T: Decodable>: Decodable {
        var value: T?
        init(from decoder: any Decoder) throws { value = try? decoder.singleValueContainer().decode(T.self) }
    }

    struct Raw: Decodable {
        var t: String
        var id, seq, since: Loose<Int>?
        var cap, data: Loose<String>?
    }

    static func parse(_ text: String) -> Parsed? {
        guard let o = try? JSONDecoder().decode(Raw.self, from: Data(text.utf8)) else { return nil }
        func count(_ f: Loose<Int>?) -> Int? {
            f?.value.flatMap { (0..<9_000_000_000_000_000).contains($0) ? $0 : nil }
        }
        var sealed: Data?
        if let s = o.data?.value, let d = Data(base64Encoded: s), d.count > 8 + 12 + 16,
            Array(d.prefix(4)) == ShareAPI.magic
        {
            sealed = d
        }
        return Parsed(
            type: o.t, id: count(o.id), seq: count(o.seq), cap: o.cap?.value, since: count(o.since), sealed: sealed)
    }

    static func text(_ o: [String: Any]) -> String {
        let d =
            (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }

    static func entry(_ e: RoomHub.Entry) -> [String: Any] {
        ["seq": e.seq, "member": e.member, "data": e.data.base64EncodedString()]
    }

    static func welcome(
        role: RoomHub.Role, member: String, members: [String], snapshot: (Int, Data)?, ops: [RoomHub.Entry], seq: Int
    ) -> String {
        var o: [String: Any] = [
            "t": "welcome", "role": role.rawValue, "member": member, "members": members, "ops": ops.map(entry),
            "seq": seq,
        ]
        if let (n, d) = snapshot { o["snapshot"] = ["seq": n, "data": d.base64EncodedString()] }
        return text(o)
    }

    static func ops(_ e: RoomHub.Entry) -> String { text(entry(e).merging(["t": "ops"]) { $1 }) }
    static func ack(id: Int, seq: Int) -> String { text(["t": "ack", "id": id, "seq": seq]) }
    static func presence(member: String, _ d: Data) -> String {
        text(["t": "presence", "member": member, "data": d.base64EncodedString()])
    }
    static func joined(_ m: String) -> String { text(["t": "joined", "member": m]) }
    static func left(_ m: String) -> String { text(["t": "left", "member": m]) }
    static let snapshot = #"{"t":"snapshot"}"#
    static let ended = #"{"t":"ended"}"#
    static func error(_ r: RoomHub.Refusal) -> String { text(["t": "error", "code": r.code, "message": r.message]) }
}

// MARK: Routes

/// A WebSocket request's context: the client's address, for limits.
public struct RoomContext: RequestContext, WebSocketRequestContext {
    public var coreContext: CoreRequestContextStorage
    public let webSocket: WebSocketHandlerReference<Self>
    public let remoteAddress: String?

    public init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        webSocket = .init()
        remoteAddress = source.channel.remoteAddress?.ipAddress
    }
}

extension ShareAPI {
    /// `POST /v1/rooms`, `DELETE /v1/rooms/{id}` and `GET /v1/rooms/{id}/view`.
    func addRoomRoutes(_ router: Router<ShareContext>) {
        router.post("v1/rooms") { request, context in try await createRoom(request, context) }
        router.delete("v1/rooms/:id") { request, context in try await endRoom(request, context) }
        router.get("v1/rooms/:id/view") { request, context in try await roomView(request, context) }
        router.on("v1/rooms/:id/view", method: .options) { _, _ in
            Response(
                status: .noContent,
                headers: [
                    .accessControlAllowMethods: "GET", .accessControlAllowHeaders: "Authorization",
                    .accessControlMaxAge: "86400",
                ])
        }
    }

    func createRoom(_ request: Request, _ context: ShareContext) async throws -> Response {
        if let wait = await writes.check(address(request, context), now: now()) { return Self.tooMany(wait) }
        guard Self.matches(Self.bearer(request), config.uploadToken) else {
            return Self.fail(.unauthorized, "The upload token is missing or wrong.")
        }
        guard let body = try? await request.body.collect(upTo: 4096),
            let o = try? JSONSerialization.jsonObject(with: Data(buffer: body)) as? [String: Any],
            let read = o["read"] as? String, let write = o["write"] as? String, let end = o["end"] as? String,
            [read, write, end].allSatisfy(Self.isDigest), Set([read, write, end]).count == 3
        else { return Self.fail(.badRequest, "A room needs the SHA-256 of its read, write and end secrets.") }
        do {
            let id = try await rooms.create(read: read, write: write, end: end)
            context.logger.info("created room")
            return Self.json(.created, #"{"id":"\#(id)"}"#)
        } catch RoomHub.Refusal.tooManyRooms {
            return Self.fail(.serviceUnavailable, RoomHub.Refusal.tooManyRooms.message)
        }
    }

    func endRoom(_ request: Request, _ context: ShareContext) async throws -> Response {
        if let wait = await writes.check(address(request, context), now: now()) { return Self.tooMany(wait) }
        guard let id = Self.shareID(context) else { return Self.fail(.notFound, "No such room.") }
        do {
            try await rooms.end(id, secret: Self.bearer(request) ?? "")
            return Response(status: .noContent)
        } catch RoomHub.Refusal.notFound {
            return Self.fail(.notFound, "No such room.")
        } catch {
            return Self.fail(.forbidden, "The end secret is missing or wrong.")
        }
    }

    func roomView(_ request: Request, _ context: ShareContext) async throws -> Response {
        if let wait = await reads.check(address(request, context), now: now()) { return Self.tooMany(wait) }
        guard let id = Self.shareID(context) else { return Self.fail(.notFound, "No such room.") }
        do {
            guard let data = try await rooms.view(id, cap: Self.bearer(request) ?? "") else {
                return Self.fail(.notFound, "The session hasn’t shared a view yet.")
            }
            return Response(
                status: .ok, headers: [.contentType: "application/octet-stream", .cacheControl: "no-store"],
                body: .init(byteBuffer: ByteBuffer(bytes: data)))
        } catch RoomHub.Refusal.notFound {
            return Self.fail(.notFound, "This session has ended.")
        } catch {
            return Self.fail(.forbidden, "That invite isn’t valid for this session.")
        }
    }

    static func isDigest(_ s: String) -> Bool { s.count == 64 && s.allSatisfy { $0.isHexDigit && !$0.isUppercase } }

    /// The WebSocket router: `/v1/rooms/{id}`.
    public func socketRouter() -> Router<RoomContext> {
        let router = Router(context: RoomContext.self)
        router.ws("v1/rooms/:id") { _, context in
            Self.shareID(context.parameters.get("id")) == nil ? .dontUpgrade : .upgrade([:])
        } onUpgrade: { inbound, outbound, context in
            guard let id = Self.shareID(context.requestContext.parameters.get("id")) else { return }
            try await session(id, inbound, outbound, context.requestContext)
        }
        return router
    }

    /// One connection: `hello` first, then frames until either side goes.
    func session(
        _ id: String, _ inbound: WebSocketInboundStream, _ outbound: WebSocketOutboundWriter, _ context: RoomContext
    ) async throws {
        var messages = inbound.messages(maxSize: config.roomMaxMessage).makeAsyncIterator()
        guard case .text(let first)? = try await messages.next(), let hello = Frames.parse(first),
            hello.type == "hello", let cap = hello.cap
        else {
            try await outbound.write(.text(Frames.error(.badMessage)))
            return
        }
        let (stream, out) = AsyncStream<String>.makeStream()
        let member: String
        do {
            member = try await rooms.join(id, cap: cap, since: hello.since ?? 0, out: out)
        } catch let r as RoomHub.Refusal {
            try await outbound.write(.text(Frames.error(r)))
            return
        }
        let rooms = self.rooms
        await withTaskGroup(of: Void.self) { group in
            // Everything for this member, in order; when the room ends, the socket closes.
            group.addTask {
                for await text in stream {
                    do { try await outbound.write(.text(text)) } catch { break }
                }
                try? await outbound.close(.normalClosure, reason: nil)
            }
            // Its frames, within the rate limit.
            var bucket = TokenBucket(perSecond: config.roomMessagesPerSecond)
            do {
                while let m = try await messages.next() {
                    guard case .text(let t) = m else { continue }
                    guard bucket.take() else {
                        out.yield(Frames.text(["t": "error", "code": "rate", "message": "Too many messages."]))
                        break
                    }
                    await rooms.receive(id, member: member, t)
                }
            } catch {}
            await rooms.leave(id, member: member)
            out.finish()
        }
    }

    static func shareID(_ id: String?) -> String? {
        guard let id, id.count == 22,
            id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        return id
    }
}

/// Messages per second on one connection, with a burst of twice that.
struct TokenBucket {
    let rate: Double
    var tokens: Double
    var last = ContinuousClock.now

    init(perSecond: Int) {
        rate = Double(perSecond)
        tokens = rate * 2
    }

    mutating func take() -> Bool {
        let t = ContinuousClock.now
        let elapsed = t - last
        last = t
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        tokens = min(rate * 2, tokens + seconds * rate)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
