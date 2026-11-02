import Foundation
import NexusFormat
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusNet
@testable import NexusReplica
@testable import NexusScene

/// Every frame the live sessions' sockets sent or received: what crossed the network, and when.
final class Wire: @unchecked Sendable {
    struct Frame {
        var at: ContinuousClock.Instant
        var sent: Bool
        var text: String
    }

    private let lock = NSLock()
    private var frames: [Frame] = []

    func record(_ s: String, sent: Bool) { lock.withLock { frames.append(Frame(at: .now, sent: sent, text: s)) } }
    var all: [Frame] { lock.withLock { frames } }
    var count: Int { lock.withLock { frames.count } }

    /// The relay's part of an edit: from the first op batch sent after frame `from` until the
    /// last of the others received it.
    func hop(from: Int) -> Duration? {
        let after = all.dropFirst(from)
        func data(_ f: Frame) -> String? {
            guard case .object(let o)? = try? CanonicalJSON.parse(Data(f.text.utf8)), o["t"] == .string("ops"),
                case .string(let d)? = o["data"]
            else { return nil }
            return d
        }
        guard let sent = after.first(where: { $0.sent && data($0) != nil }), let d = data(sent) else { return nil }
        return after.filter { !$0.sent && data($0) == d }.map { $0.at - sent.at }.max()
    }
}

/// Rooms' sockets through NexusNet's `NetSocket`, as `OpenNexusNet.xpc` opens them.
struct LiveConnector: RoomConnector {
    let wire: Wire

    final class Socket: RoomSocket {
        let socket: NetSocket
        let wire: Wire

        init(_ socket: NetSocket, wire: Wire) {
            self.socket = socket
            self.wire = wire
        }

        func send(_ text: String) {
            wire.record(text, sent: true)
            socket.send(text)
        }

        func close() { socket.close() }
    }

    func open(_ url: URL, events: @escaping @Sendable (SocketEvent) -> Void) -> any RoomSocket {
        let wire = wire
        let s = NetSocket(url: url, allowed: [url.host() ?? ""], purpose: "Live session") { e in
            switch e {
            case .opened: events(.opened)
            case .text(let t):
                wire.record(t, sent: false)
                events(.text(t))
            case .closed(let why, _): events(.closed(why))
            }
        }
        s.open()
        return Socket(s, wire: wire)
    }
}

/// M46 for real (`scripts/test-collab.sh`): the relay in Docker; three Macs, a view-only
/// guest and a late joiner, all through NexusNet's requests and sockets. The script then
/// looks through the room's files on the server for anything in the clear.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OPENNEXUS_LIVE_COLLAB"] == "1"))
struct CollabLive {
    static let env = ProcessInfo.processInfo.environment
    static let address = env["OPENNEXUS_LIVE_SERVER"] ?? "http://127.0.0.1:18787"
    /// Words only these tests write: they never cross the network or reach the server's disk
    /// in the clear.
    static let marker = "Quokka-Lantern"
    let wire = Wire()

    func mac(_ name: String) -> CollabMac {
        var d = ShareDestination(id: "server", kind: .server, name: "Docker")
        d.server = Self.address
        return CollabMac(
            name, transport: ShareLive.RealNetwork(), connector: LiveConnector(wire: wire), server: d,
            token: "test-upload-token-0123456789")
    }

    func topic(_ m: CollabMac, _ text: String) throws -> NodeID {
        try #require(m.store.model.canvases["c1"]?.nodes.first { $0.value.text == text }?.key)
    }

    /// `GET /v1/rooms/{id}/view` as the join page asks for it.
    func view(_ invite: Invite, bearer: String?) async throws -> HTTPResponse {
        let url = try #require(URL(string: invite.server + "/v1/rooms/\(invite.room)/view"))
        let client = HTTPClient(allowed: [url.host() ?? ""], purpose: "Live session")
        return try await client.send(
            HTTPRequest("GET", url, headers: bearer.map { ["Authorization": "Bearer \($0)"] } ?? [:]))
    }

    /// Writes what the script checks on the server's disk.
    func note(_ name: String, _ text: String) throws {
        guard let dir = Self.env["OPENNEXUS_LIVE_COLLAB_OUT"] else { return }
        try text.write(to: URL(filePath: dir).appending(path: name), atomically: true, encoding: .utf8)
    }

    @Test func threeMacsAndALateJoiner() async throws {
        let a = mac("Ana")
        a.open(launchPlanDocument())
        let pricing = try topic(a, "Pricing")
        a.rename(pricing, "\(Self.marker) pricing")
        let s = try await a.start()
        try await waitUntil("Ana is live", seconds: 10) { s.status == .live }
        let link = try #require(a.controller.inviteLink(canEdit: true))
        let b = mac("Ben")
        let c = mac("Cy")
        try await b.join(link)
        try await c.join(link)
        try await waitUntil("everyone sees everyone", seconds: 10) {
            s.people.count == 2 && b.session?.people.count == 2 && c.session?.people.count == 2
        }
        #expect(sharedCanonical(a.store.model) == sharedCanonical(b.store.model))
        #expect(sharedCanonical(a.store.model) == sharedCanonical(c.store.model))

        // Latency (A4): one person's rename until both others have it.
        let mains = a.store.model.canvases["c1"]!.nodes[a.store.model.canvases["c1"]!.root]!.children
        let clock = ContinuousClock()
        var samples: [Duration] = []
        var hops: [Duration] = []
        for i in 0..<30 {
            let (from, others) = i % 2 == 0 ? (b, [a, c]) : (c, [a, b])
            let id = mains[i % mains.count]
            let text = "\(Self.marker) \(i)"
            let mark = wire.count
            let start = clock.now
            from.rename(id, text)
            for _ in 0..<5000 where !others.allSatisfy({ $0.text(id) == text }) {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(others.allSatisfy { $0.text(id) == text }, "round \(i)")
            samples.append(clock.now - start)
            if let h = wire.hop(from: mark) { hops.append(h) }
        }
        let m = median(samples)
        // All four windows share this process's main thread, in a debug build: the relay's
        // hop is the network's part.
        print(
            "live edit to two others: median \(ms(m)) ms, max \(ms(samples.max()!)) ms;"
                + " relay hop median \(ms(median(hops))) ms")
        #expect(ms(m) < 150, "median \(ms(m)) ms")
        #expect(hops.count == samples.count)

        // View only (A5): the app keeps the edit back, and the relay refuses one sent anyway.
        let v = mac("Vic")
        try await v.join(try #require(a.controller.inviteLink(canEdit: false)))
        let vs = try #require(v.session)
        try await waitUntil("Vic is live", seconds: 10) { vs.status == .live }
        #expect(!vs.canEdit)
        let before = sharedCanonical(v.store.model)
        v.rename(pricing, "Nope")
        #expect(sharedCanonical(v.store.model) == before)
        vs.client.send([Op(Stamp(time: 1, count: 0, replica: "x"), .set(.canvas("c1", "title"), .string("Nope")))])
        try await waitUntil("refused", seconds: 10) { vs.refusal != nil }
        #expect(a.store.model.canvases["c1"]?.title != "Nope")

        // A late joiner (A6): byte for byte the same document.
        let d = mac("Dee")
        try await d.join(link)
        try await waitUntil("Dee has it", seconds: 10) { d.session?.status == .live }
        #expect(sharedCanonical(d.store.model) == sharedCanonical(a.store.model))

        // The join page's view: only for the room's capabilities, and the host's bundle inside.
        let current = a.controller.collabViewBundle()
        var shown: JSONValue?
        for _ in 0..<100 {
            let r = try await view(s.invite, bearer: s.invite.read)
            if r.status == 200 { shown = try? Sealed.openBundle(r.body, key: s.invite.symmetricKey).bundle }
            if shown == current { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(shown == current)
        #expect(try await view(s.invite, bearer: Invite.secret()).status == 403)
        #expect(try await view(s.invite, bearer: nil).status == 403)

        // Nothing in the clear on the network (A6): the marker and the plan's topics.
        let frames = wire.all.map(\.text)
        #expect(frames.count > 60)
        let words =
            [Self.marker, "Launch plan"]
            + a.store.model.canvases["c1"]!.nodes.values.map(\.text).filter { $0.count >= 8 }
        for w in Set(words) {
            #expect(!frames.contains { $0.contains(w) }, "“\(w)” crossed the network")
        }
        try note("kept-room", s.invite.room)
        try note("words", Set(words).sorted().joined(separator: "\n"))
        for m in [b, c, v, d] { m.controller.leaveCollab() }
        a.center.suspend(a.documentID)
    }

    /// End Session (A6): the relay forgets the room, and the others hear and keep their copy.
    @Test func endingDeletesTheRoom() async throws {
        let a = mac("Ana")
        a.open(launchPlanDocument())
        let s = try await a.start()
        try await waitUntil("Ana is live", seconds: 10) { s.status == .live }
        let b = mac("Ben")
        try await b.join(try #require(a.controller.inviteLink(canEdit: true)))
        let bs = try #require(b.session)
        try await waitUntil("Ben is live", seconds: 10) { bs.status == .live }
        var ended: String?
        bs.onEnded = { ended = $0 }
        for _ in 0..<100 {
            if try await view(s.invite, bearer: s.invite.read).status == 200 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await view(s.invite, bearer: s.invite.read).status == 200)
        let invite = s.invite
        await a.controller.endCollab()
        try await waitUntil("Ben hears", seconds: 10) { ended != nil }
        #expect(ended == "The host ended the live session. This copy is yours to keep.")
        #expect(try await view(invite, bearer: invite.read).status == 404)
        let pricing = try topic(b, "Pricing")
        #expect(b.store.collab == nil && b.text(pricing) == "Pricing")
        // The invite leads nowhere now.
        let late = mac("Dee")
        let ls = try late.center.join(invite.link(viewer: ShareCenter.defaultViewer))
        try await waitUntil("Dee is turned away", seconds: 10) {
            if case .failed = ls.client.status { return true }
            return ls.client.status == .ended
        }
        try note("ended-room", invite.room)
    }
}
