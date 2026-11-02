import Crypto
import Foundation
import Hummingbird
import HummingbirdTesting
import HummingbirdWSClient
import Logging
import NIOCore
import Testing

@testable import OpenNexusServer

/// Secrets as invite links carry them, and what the server is given.
struct Caps {
    let read = ShareAPI.random(32)
    let write = ShareAPI.random(32)
    let end = ShareAPI.random(32)
    var body: String {
        #"{"read":"\#(ShareAPI.digest(read))","write":"\#(ShareAPI.digest(write))","end":"\#(ShareAPI.digest(end))"}"#
    }
}

/// One member's view of the hub: the frames it was sent, parsed, in order.
final class Probe: @unchecked Sendable {
    let stream: AsyncStream<String>
    let out: AsyncStream<String>.Continuation
    var iterator: AsyncStream<String>.Iterator
    init() {
        (stream, out) = AsyncStream<String>.makeStream()
        iterator = stream.makeAsyncIterator()
    }
    /// The next frame already sent (the hub sends within its calls).
    func next() async -> [String: Any]? {
        guard let t = await iterator.next() else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any]
    }
}

/// A sealed-looking payload in base64: the magic, then bytes nobody can read.
func sealedText(_ fill: UInt8 = 1, _ n: Int = 64) -> String {
    Data(Array("ONX1".utf8) + [UInt8](repeating: fill, count: n)).base64EncodedString()
}

func frame(_ o: [String: Any]) -> String { Frames.text(o) }

@Suite struct RoomTests {
    func hub(_ edit: (inout ServerConfig) -> Void = { _ in }, now: @escaping @Sendable () -> Date = Date.init)
        -> RoomHub
    {
        var c = ServerConfig(uploadToken: Server.token)
        edit(&c)
        return RoomHub(memory: c, now: now)
    }

    func room(_ h: RoomHub, _ caps: Caps = Caps()) async throws -> String {
        try await h.create(
            read: ShareAPI.digest(caps.read), write: ShareAPI.digest(caps.write), end: ShareAPI.digest(caps.end))
    }

    // MARK: HTTP

    @Test func creatingARoomNeedsTheTokenAndOnlyHashes() async throws {
        try await Server({ $0.maxRooms = 1 }).test { client in
            let caps = Caps()
            let none = try await client.execute(uri: "/v1/rooms", method: .post, body: ByteBuffer(string: caps.body))
            #expect(none.status == .unauthorized)
            let auth: HTTPFields = [.authorization: "Bearer \(Server.token)"]
            for bad in [
                "{}", #"{"read":"x","write":"y","end":"z"}"#,
                #"{"read":"\#(caps.read)","write":"\#(caps.write)","end":"\#(caps.end)"}"#,  // secrets, not hashes
            ] {
                let r = try await client.execute(
                    uri: "/v1/rooms", method: .post, headers: auth, body: ByteBuffer(string: bad))
                #expect(r.status == .badRequest, "\(bad)")
            }
            let ok = try await client.execute(
                uri: "/v1/rooms", method: .post, headers: auth, body: ByteBuffer(string: caps.body))
            #expect(ok.status == .created)
            let id = (try JSONSerialization.jsonObject(with: Data(buffer: ok.body)) as? [String: String])?["id"]
            #expect(id?.count == 22)
            let full = try await client.execute(
                uri: "/v1/rooms", method: .post, headers: auth, body: ByteBuffer(string: Caps().body))
            #expect(full.status == .serviceUnavailable)
        }
    }

    @Test func endingNeedsTheEndSecretAndViewingACapability() async throws {
        let s = Server()
        let rooms = RoomHub(memory: s.config)
        let caps = Caps()
        let id = try await room(rooms, caps)
        let api = ShareAPI(config: s.config, storage: MemoryStorage(), rooms: rooms)
        try await Application(router: api.router()).test(.router) { client in
            func view(_ cap: String) async throws -> TestResponse {
                try await client.execute(
                    uri: "/v1/rooms/\(id)/view", method: .get, headers: [.authorization: "Bearer \(cap)"])
            }
            #expect(try await view(caps.read).status == .notFound)  // nothing shared yet
            let p = Probe()
            let m = try await rooms.join(id, cap: caps.write, since: 0, out: p.out)
            await rooms.receive(id, member: m, frame(["t": "view", "data": sealedText(9)]))
            let r = try await view(caps.read)
            #expect(r.status == .ok && Data(buffer: r.body) == Data(base64Encoded: sealedText(9)))
            #expect(r.headers[.accessControlAllowOrigin] == "*")
            #expect(try await view(caps.end).status == .forbidden)
            let pre = try await client.execute(uri: "/v1/rooms/\(id)/view", method: .options)
            #expect(pre.headers[.accessControlAllowHeaders] == "Authorization")

            func end(_ secret: String) async throws -> HTTPResponse.Status {
                try await client.execute(
                    uri: "/v1/rooms/\(id)", method: .delete, headers: [.authorization: "Bearer \(secret)"]
                ).status
            }
            #expect(try await end(caps.write) == .forbidden)
            #expect(try await end(caps.end) == .noContent)
            #expect(try await end(caps.end) == .notFound)
            #expect(try await view(caps.read).status == .notFound)
        }
    }

    // MARK: The hub

    @Test func capabilitiesDecideTheRole() async throws {
        let h = hub()
        let caps = Caps()
        let id = try await room(h, caps)
        await #expect(throws: RoomHub.Refusal.unauthorized) {
            try await h.join(id, cap: "guess", since: 0, out: Probe().out)
        }
        await #expect(throws: RoomHub.Refusal.notFound) {
            try await h.join("Nosuchroomnosuchroomxx", cap: caps.read, since: 0, out: Probe().out)
        }
        let (w, v) = (Probe(), Probe())
        let wm = try await h.join(id, cap: caps.write, since: 0, out: w.out)
        let vm = try await h.join(id, cap: caps.read, since: 0, out: v.out)
        #expect(await w.next()?["role"] as? String == "edit")
        #expect(await w.next()?["t"] as? String == "joined")
        let welcome = await v.next()
        #expect(welcome?["role"] as? String == "view" && welcome?["members"] as? [String] == [wm])
        // A viewer's ops and snapshots are refused, and nothing reaches anyone.
        await h.receive(id, member: vm, frame(["t": "ops", "id": 1, "data": sealedText()]))
        await h.receive(id, member: vm, frame(["t": "snapshot", "seq": 0, "data": sealedText()]))
        #expect(await v.next()?["code"] as? String == "read-only")
        #expect(await v.next()?["code"] as? String == "read-only")
        #expect(await h.stats(id)?.seq == 0)
        // Presence from a viewer is fine.
        await h.receive(id, member: vm, frame(["t": "presence", "data": sealedText(3)]))
        let p = await w.next()
        #expect(p?["t"] as? String == "presence" && p?["member"] as? String == vm)
    }

    @Test func opsAreNumberedAckedAndFannedOut() async throws {
        let h = hub()
        let caps = Caps()
        let id = try await room(h, caps)
        let (a, b, c) = (Probe(), Probe(), Probe())
        let am = try await h.join(id, cap: caps.write, since: 0, out: a.out)
        _ = await a.next()
        let bm = try await h.join(id, cap: caps.write, since: 0, out: b.out)
        _ = (await a.next(), await b.next())
        for i in 1...3 { await h.receive(id, member: am, frame(["t": "ops", "id": i, "data": sealedText(UInt8(i))])) }
        for i in 1...3 {
            let ack = await a.next()
            #expect(ack?["t"] as? String == "ack" && ack?["id"] as? Int == i && ack?["seq"] as? Int == i)
            let op = await b.next()
            #expect(op?["seq"] as? Int == i && op?["member"] as? String == am)
            #expect(op?["data"] as? String == sealedText(UInt8(i)))
        }
        // Only sealed payloads.
        await h.receive(
            id, member: bm, frame(["t": "ops", "id": 1, "data": Data("plain text, no".utf8).base64EncodedString()]))
        #expect(await b.next()?["code"] as? String == "bad-message")
        await h.receive(id, member: bm, "not json")
        #expect(await b.next()?["code"] as? String == "bad-message")
        // A late joiner gets the tail after its `since`.
        let cm = try await h.join(id, cap: caps.read, since: 1, out: c.out)
        let w = await c.next()
        #expect((w?["ops"] as? [[String: Any]])?.compactMap { $0["seq"] as? Int } == [2, 3])
        #expect(w?["seq"] as? Int == 3 && w?["snapshot"] == nil)
        await h.leave(id, member: cm)
        #expect(await a.next()?["t"] as? String == "joined")
        let left = await a.next()
        #expect(left?["t"] as? String == "left" && left?["member"] as? String == cm)
    }

    @Test func aLongTailAsksForASnapshotThatReplacesIt() async throws {
        let h = hub()
        let caps = Caps()
        let id = try await room(h, caps)
        let a = Probe()
        let am = try await h.join(id, cap: caps.write, since: 0, out: a.out)
        _ = await a.next()
        var asked = 0
        for i in 1...(RoomHub.snapshotAfter + 5) {
            await h.receive(id, member: am, frame(["t": "ops", "id": i, "data": sealedText()]))
            _ = await a.next()  // the ack
            if i == RoomHub.snapshotAfter + 1 {
                asked += await a.next()?["t"] as? String == "snapshot" ? 1 : 0
            }
        }
        #expect(asked == 1)
        await h.receive(id, member: am, frame(["t": "snapshot", "seq": 200, "data": sealedText(5)]))
        let st = await h.stats(id)
        #expect(st?.snapshot == 200 && st?.tail == 5)
        // An older one changes nothing.
        await h.receive(id, member: am, frame(["t": "snapshot", "seq": 100, "data": sealedText(6)]))
        #expect(await h.stats(id)?.snapshot == 200)
        // Joining from before the snapshot: the snapshot and the tail after it.
        let b = Probe()
        _ = try await h.join(id, cap: caps.read, since: 10, out: b.out)
        let w = await b.next()
        #expect((w?["snapshot"] as? [String: Any])?["seq"] as? Int == 200)
        #expect((w?["ops"] as? [[String: Any]])?.count == 5)
    }

    @Test func limits() async throws {
        let h = hub {
            $0.roomMaxMembers = 2
            $0.roomMaxBytes = 65_536
        }
        let caps = Caps()
        let id = try await room(h, caps)
        let a = Probe()
        let am = try await h.join(id, cap: caps.write, since: 0, out: a.out)
        _ = try await h.join(id, cap: caps.read, since: 0, out: Probe().out)
        await #expect(throws: RoomHub.Refusal.full) { try await h.join(id, cap: caps.read, since: 0, out: Probe().out) }
        _ = (await a.next(), await a.next())
        // A room can hold only so much: the relay refuses, and asks for a snapshot to compact.
        await h.receive(id, member: am, frame(["t": "ops", "id": 1, "data": sealedText(1, 70_000)]))
        #expect(await a.next()?["t"] as? String == "snapshot")
        #expect(await a.next()?["code"] as? String == "too-large")
    }

    /// Retention: a room nobody has been in for a week goes; one in use stays.
    @Test func idleRoomsAreDeleted() async throws {
        let clock = TestClock()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rooms-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        var c = ServerConfig(uploadToken: Server.token)
        c.roomsDirectory = dir.path
        let h = try RoomHub(config: c, now: { clock.now })
        let (c1, c2) = (Caps(), Caps())
        let idle = try await room(h, c1)
        let busy = try await room(h, c2)
        _ = try await h.join(busy, cap: c2.read, since: 0, out: Probe().out)
        clock.advance(6 * 86_400)
        #expect(await h.sweep() == 0)
        clock.advance(2 * 86_400)
        #expect(await h.sweep() == 1)
        let (gone, kept) = (await h.stats(idle), await h.stats(busy))
        #expect(gone == nil && kept != nil)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(idle).path))
    }

    /// Rooms survive a restart; the files hold only sealed bytes and hashes; End deletes them.
    @Test func roomsAreKeptOnDiskAndEndDeletesThem() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rooms-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        var c = ServerConfig(uploadToken: Server.token)
        c.roomsDirectory = dir.path
        let caps = Caps()
        var h = try RoomHub(config: c)
        let id = try await room(h, caps)
        let a = Probe()
        let am = try await h.join(id, cap: caps.write, since: 0, out: a.out)
        for i in 1...4 { await h.receive(id, member: am, frame(["t": "ops", "id": i, "data": sealedText(UInt8(i))])) }
        await h.receive(id, member: am, frame(["t": "snapshot", "seq": 2, "data": sealedText(8)]))
        await h.receive(id, member: am, frame(["t": "ops", "id": 5, "data": sealedText(5)]))
        await h.receive(id, member: am, frame(["t": "view", "data": sealedText(9)]))
        // Restarted.
        h = try RoomHub(config: c)
        let st = await h.stats(id)
        #expect(st?.seq == 5 && st?.snapshot == 2 && st?.tail == 3)
        #expect(try await h.view(id, cap: caps.read) == Data(base64Encoded: sealedText(9)))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent(id).path).sorted()
        #expect(files == ["room.json", "snapshot.onx", "tail.log", "view.onx"])
        for f in files {
            let text = String(
                decoding: try Data(contentsOf: dir.appendingPathComponent(id).appendingPathComponent(f)), as: UTF8.self)
            for secret in [caps.read, caps.write, caps.end] { #expect(!text.contains(secret)) }
        }
        try await h.end(id, secret: caps.end)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(id).path))
    }

    /// Counts are whole numbers from 0; `true` isn't one (the same on Linux as on a Mac).
    @Test func framesReadCountsStrictly() {
        #expect(
            Frames.parse(#"{"t":"ops","id":1,"seq":0,"since":42}"#).map { [$0.id, $0.seq, $0.since] } == [1, 0, 42])
        for bad in ["true", "false", "-1", "1.5", "\"1\"", "1e40", "null"] {
            #expect(Frames.parse(#"{"t":"ops","id":\#(bad)}"#)?.id == nil, "\(bad)")
        }
        #expect(Frames.parse(#"{"t":"hello","cap":7}"#)?.cap == nil)
        #expect(Frames.parse(#"{"id":1}"#) == nil)
        #expect(Frames.parse("[1]") == nil)
    }

    @Test func roomSettingsComeFromTheEnvironment() throws {
        let base = ["OPENNEXUS_UPLOAD_TOKEN": Server.token]
        let d = try ServerConfig.fromEnvironment(base)
        #expect(d.roomsDirectory == "/data/rooms" && d.roomIdleDays == 7)
        let c = try ServerConfig.fromEnvironment(
            base.merging([
                "OPENNEXUS_ROOMS_DIR": "", "OPENNEXUS_ROOM_IDLE_DAYS": "2", "OPENNEXUS_ROOM_MAX_MEMBERS": "5",
                "OPENNEXUS_MAX_ROOMS": "9", "OPENNEXUS_ROOM_MESSAGES_PER_SECOND": "20",
            ]) { $1 })
        #expect(c.roomsDirectory == nil && c.roomIdleDays == 2 && c.roomMaxMembers == 5 && c.maxRooms == 9)
        #expect(c.roomMessagesPerSecond == 20)
        #expect(throws: ConfigError.self) {
            try ServerConfig.fromEnvironment(base.merging(["OPENNEXUS_ROOM_IDLE_DAYS": "0"]) { $1 })
        }
    }
}

// MARK: Over real sockets

/// A9: the relay on a port, with WebSocket clients.
@Suite(.serialized) struct RoomSocketTests {
    struct Live {
        let caps = Caps()
        let api: ShareAPI
        let id: String

        init(_ edit: (inout ServerConfig) -> Void = { _ in }) async throws {
            var c = ServerConfig(uploadToken: Server.token)
            edit(&c)
            api = ShareAPI(config: c, storage: MemoryStorage())
            id = try await api.rooms.create(
                read: ShareAPI.digest(caps.read), write: ShareAPI.digest(caps.write), end: ShareAPI.digest(caps.end))
        }

        func run(_ body: @escaping @Sendable (Int) async throws -> Void) async throws {
            let app = Application(
                router: api.router(),
                server: .http1WebSocketUpgrade(
                    webSocketRouter: api.socketRouter(), configuration: .init(ws: .init(maxFrameSize: 1 << 20))),
                configuration: .init(address: .hostname("127.0.0.1", port: 0)))
            // The test framework serves on `localhost`, whatever the address says.
            try await app.test(.live) { client in try await body(client.port!) }
        }
    }

    static let logger = Logger(label: "room-test")

    @Test func helloFirstThenFrames() async throws {
        let live = try await Live()
        try await live.run { port in
            let url = "ws://localhost:\(port)/v1/rooms/\(live.id)"
            // A wrong capability is refused and the socket closes.
            try await WebSocketClient.connect(url: url, logger: Self.logger) { inbound, outbound, _ in
                try await outbound.write(.text(frame(["t": "hello", "cap": "wrong", "since": 0])))
                var it = inbound.messages(maxSize: 1 << 20).makeAsyncIterator()
                guard case .text(let t)? = try await it.next() else { Issue.record("no reply"); return }
                #expect(t.contains("\"unauthorized\""))
            }
            try await WebSocketClient.connect(url: url, logger: Self.logger) { inbound, outbound, _ in
                try await outbound.write(.text(frame(["t": "hello", "cap": live.caps.write, "since": 0])))
                var it = inbound.messages(maxSize: 1 << 20).makeAsyncIterator()
                guard case .text(let t)? = try await it.next() else { Issue.record("no welcome"); return }
                #expect(t.contains("\"welcome\"") && t.contains("\"edit\""))
                try await outbound.write(.text(frame(["t": "ops", "id": 1, "data": sealedText()])))
                guard case .text(let ack)? = try await it.next() else { Issue.record("no ack"); return }
                #expect(ack.contains("\"ack\""))
                try await outbound.close(.normalClosure, reason: nil)
            }
        }
    }

    @Test func aFloodIsCutOff() async throws {
        let live = try await Live { $0.roomMessagesPerSecond = 5 }
        try await live.run { port in
            try await WebSocketClient.connect(url: "ws://localhost:\(port)/v1/rooms/\(live.id)", logger: Self.logger) {
                inbound, outbound, _ in
                try await outbound.write(.text(frame(["t": "hello", "cap": live.caps.write, "since": 0])))
                for i in 1...40 { try await outbound.write(.text(frame(["t": "ops", "id": i, "data": sealedText()]))) }
                var sawRate = false
                for try await m in inbound.messages(maxSize: 1 << 20) {
                    if case .text(let t) = m, t.contains("\"rate\"") { sawRate = true }
                }
                #expect(sawRate)
            }
            #expect(await live.api.rooms.stats(live.id)!.seq < 40)
        }
    }

    /// A9's load run: 10 editors, each sending 10 batches a second for 3 seconds. Every
    /// editor gets every other editor's batches, in sequence order, and every ack.
    @Test(.timeLimit(.minutes(1))) func tenEditorsAtTenOpsASecond() async throws {
        let live = try await Live()
        let editors = 10
        let perEditor = 30
        let results = Results()
        try await live.run { port in
            let url = "ws://localhost:\(port)/v1/rooms/\(live.id)"
            let ready = Gate(editors)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for e in 0..<editors {
                    group.addTask {
                        try await WebSocketClient.connect(url: url, logger: Self.logger) { inbound, outbound, _ in
                            try await outbound.write(.text(frame(["t": "hello", "cap": live.caps.write, "since": 0])))
                            var it = inbound.messages(maxSize: 1 << 22).makeAsyncIterator()
                            _ = try await it.next()  // welcome
                            await ready.arrive()
                            await ready.wait()
                            let sender = Task {
                                for i in 1...perEditor {
                                    let sent = Date().timeIntervalSince1970
                                    try await outbound.write(
                                        .text(
                                            frame([
                                                "t": "ops", "id": i, "data": sealedText(UInt8(e), 200), "sent": sent,
                                            ])))
                                    try await Task.sleep(for: .milliseconds(100))
                                }
                            }
                            var acks = 0
                            var ops = 0
                            var lastSeq = 0
                            var ordered = true
                            while acks < perEditor || ops < (editors - 1) * perEditor {
                                guard case .text(let t)? = try await it.next(),
                                    let o = try JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any],
                                    let kind = o["t"] as? String
                                else { break }
                                if let s = o["seq"] as? Int {
                                    if s <= lastSeq { ordered = false }
                                    lastSeq = s
                                }
                                if kind == "ack" { acks += 1 }
                                if kind == "ops" { ops += 1 }
                            }
                            try await sender.value
                            await results.add(acks: acks, ops: ops, ordered: ordered)
                            try await outbound.close(.normalClosure, reason: nil)
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
        let r = await results.all
        #expect(r.count == editors)
        for x in r {
            #expect(x.acks == perEditor && x.ops == (editors - 1) * perEditor && x.ordered)
        }
        #expect(await live.api.rooms.stats(live.id)?.seq == editors * perEditor)
    }
}

actor Results {
    var all: [(acks: Int, ops: Int, ordered: Bool)] = []
    func add(acks: Int, ops: Int, ordered: Bool) { all.append((acks, ops, ordered)) }
}

/// Everyone waits until all have arrived.
actor Gate {
    let count: Int
    var arrived = 0
    var waiting: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { count = n }
    func arrive() {
        arrived += 1
        if arrived == count { for w in waiting { w.resume() }; waiting = [] }
    }
    func wait() async {
        if arrived >= count { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}
