import CryptoKit
import Foundation
import NexusCore
import NexusFormat
import Testing

@testable import NexusReplica

/// Waits for a condition the event loop will make true (or gives up).
@MainActor
func eventually(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
    let end = ContinuousClock.now + timeout
    while ContinuousClock.now < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

@Suite struct InviteTests {
    let invite = Invite(
        server: "https://relay.example.com", room: Sealed.randomBytes(16).base64URL(), key: Sealed.randomBytes(32),
        read: Invite.secret(), write: Invite.secret())

    @Test func fragmentRoundTrips() throws {
        #expect(Invite(fragment: invite.fragment) == invite)
        #expect(Invite(fragment: invite.viewOnly.fragment) == invite.viewOnly)
        #expect(Invite(fragment: invite.viewOnly.fragment)?.canEdit == false)
        let link = invite.link(viewer: "https://jvaudio.github.io/opennexus")
        #expect(link.hasPrefix("https://jvaudio.github.io/opennexus/join/#2."))
        #expect(Invite(link: link) == invite)
        #expect(Invite(link: "  " + invite.appLink + "\n") == invite)
        #expect(invite.appLink.hasPrefix("opennexus://join#2."))
        #expect(invite.socketURL?.absoluteString == "wss://relay.example.com/v1/rooms/\(invite.room)")
        var local = invite
        local.server = "http://localhost:8787/"
        #expect(local.socketURL?.absoluteString == "ws://localhost:8787/v1/rooms/\(invite.room)")
    }

    @Test func badInvitesAreRefused() {
        let parts = invite.fragment.split(separator: ".").map(String.init)
        for bad in [
            "", "2", "1." + parts.dropFirst().joined(separator: "."),  // another version
            parts.prefix(4).joined(separator: "."),  // no read capability
            parts.enumerated().map { $0.offset == 3 ? "AAAA" : $0.element }.joined(separator: "."),  // short key
            parts.enumerated().map { $0.offset == 1 ? Data("http://example.com".utf8).base64URL() : $0.element }
                .joined(separator: "."),  // plain HTTP to another host
            invite.fragment + ".extra",
        ] {
            #expect(Invite(fragment: bad) == nil, "\(bad)")
        }
    }
}

@Suite struct RoomMessageTests {
    @Test func framesRoundTrip() {
        let d = Data([1, 2, 3, 250])
        for f: ClientFrame in [
            .hello(cap: "abc", since: 12), .ops(id: 3, data: d), .presence(d), .snapshot(seq: 9, data: d), .view(d),
        ] {
            #expect(ClientFrame(text: f.text) == f)
        }
        let s = RelayFrame.Sequenced(seq: 4, member: "m2", data: d)
        for f: RelayFrame in [
            .welcome(.init(role: .edit, member: "m1", members: ["m2"], snapshot: (3, d), ops: [s], seq: 4)),
            .welcome(.init(role: .view, member: "m1", members: [], snapshot: nil, ops: [], seq: 0)),
            .ops(s), .ack(id: 2, seq: 5), .presence(member: "m3", data: d), .joined("m4"), .left("m4"), .snapshot,
            .ended, .error(code: "read-only", message: "No"),
        ] {
            #expect(RelayFrame(text: f.text) == f)
        }
        #expect(ClientFrame(text: #"{"t":"ops","id":-1,"data":"AA=="}"#) == nil)
        #expect(RelayFrame(text: "not json") == nil)
    }

    @Test func sealedMessagesHideTheirContent() throws {
        let key = Sealed.newKey()
        let (r, seed) = Replica.seed(sampleDocument(), id: "host01")
        let sealed = try RoomSeal.sealOps(seed, replica: r.id, seq: 1, key: key)
        let text = String(decoding: sealed, as: UTF8.self)
        for word in ["Launch plan", "Pricing", "Invite list", "Ana"] { #expect(!text.contains(word)) }
        #expect(try RoomSeal.openOps(sealed, key: key) == seed)
        #expect(throws: Sealed.SealError.damaged) { try RoomSeal.openOps(sealed, key: Sealed.newKey()) }
        // One kind can't be passed off as another.
        let p = try RoomSeal.sealPresence(Presence(replica: "host01", name: "Ana"), key: key)
        #expect(throws: Sealed.SealError.damaged) { try RoomSeal.openOps(p, key: key) }
        #expect(try RoomSeal.openPresence(p, key: key).name == "Ana")
    }

    @Test func presenceColoursComeFromThePalette() {
        let p = Presence(replica: "k3x9qa", name: "Ana", selection: ["n1"], viewport: [0, 0, 800, 600])
        #expect(Presence.palette.contains(p.colour))
        #expect(Presence(json: p.json) == p)
        var forged = p.json.objectValue!
        forged["colour"] = "javascript:alert(1)"
        #expect(Presence(json: .object(forged))?.colour == p.colour)
    }
}

/// `RoomClient` against the in-memory relay: a session from start to End.
@MainActor
@Suite struct RoomClientTests {
    let relay = MemoryRelay()
    let fast: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0 / 50) }

    func newRoom() -> (edit: Invite, view: Invite) {
        let s = Invite.newSecrets()
        let id = relay.createRoom(read: s.read, write: s.write)
        let edit = Invite(server: "https://relay.test", room: id, key: s.key, read: s.read, write: s.write)
        return (edit, edit.viewOnly)
    }

    /// The host's client, live, with the document sent.
    func host(_ invite: Invite, doc: DocumentModel = sampleDocument()) async -> RoomClient {
        let (r, seed) = Replica.seed(doc, id: "host01")
        let c = RoomClient(invite: invite, replica: r, connector: relay, sleep: fast)
        c.start()
        c.send(seed)
        _ = await eventually { c.status == .live && c.saved.outbox.isEmpty }
        return c
    }

    func join(_ invite: Invite, id: String) -> RoomClient {
        let c = RoomClient(invite: invite, replica: Replica(id: id), connector: relay, sleep: fast)
        c.start()
        return c
    }

    func settled(_ clients: [RoomClient]) async -> Bool {
        await eventually {
            clients.allSatisfy { $0.status == .live && $0.saved.outbox.isEmpty }
                && Set(clients.map { canonical($0.replica.doc) }).count == 1
        }
    }

    @Test func joinersGetTheDocument() async {
        let (edit, _) = newRoom()
        let h = await host(edit)
        let j = join(edit, id: "peer1a")
        var changes = 0
        j.onEvent = { if case .changes = $0 { changes += 1 } }
        #expect(await settled([h, j]))
        #expect(canonical(j.replica.doc) == canonical(sampleDocument()))
        #expect(j.role == .edit)
        #expect(changes >= 1)
    }

    /// A1 through the client: three people edit at once while connections drop now and
    /// then; everyone ends with the same document and nothing left unsent.
    @Test(arguments: Array(UInt64(1)...8)) func editsConvergeThroughDrops(seed: UInt64) async {
        var rng = SplitMix64(seed: seed)
        let (edit, _) = newRoom()
        let h = await host(edit)
        let clients = [h, join(edit, id: "peer1a"), join(edit, id: "peer2a")]
        #expect(await settled(clients))
        for step in 0..<90 {
            let c = clients[Int.random(in: 0..<3, using: &rng)]
            c.send(randomEdit(&c.replica, &rng))
            if step % 15 == 7 { relay.drop(clients[Int.random(in: 0..<3, using: &rng)].member) }
            if step % 30 == 20 { relay.dropAll() }
            if step % 4 == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        }
        #expect(await settled(clients), "seed \(seed)")
        let docs = clients.map { canonical($0.replica.doc) }
        #expect(Set(docs).count == 1)
        for c in clients { #expect(c.replica.doc.canvases.values.allSatisfy { $0.validate().isEmpty }) }
    }

    /// A6: someone joining after the relay compacted its tail into a snapshot gets the same
    /// document, byte for byte.
    @Test func lateJoinerAfterASnapshot() async {
        relay.snapshotAfter = 10
        var rng = SplitMix64(seed: 77)
        let (edit, view) = newRoom()
        let h = await host(edit)
        let p = join(edit, id: "peer1a")
        #expect(await settled([h, p]))
        for i in 0..<60 {
            let c = i % 2 == 0 ? h : p
            c.send(randomEdit(&c.replica, &rng))
            if i % 10 == 0 { try? await Task.sleep(for: .milliseconds(2)) }
        }
        #expect(await settled([h, p]))
        let room = relay.room(edit.room)!
        #expect(room.snapshot != nil)
        #expect(room.tail.count <= 60)
        let late = join(view, id: "late01")
        #expect(await settled([h, p, late]))
        #expect(canonical(late.replica.doc) == canonical(h.replica.doc))
        #expect(late.role == .view)
    }

    /// A5: a view-only participant's edits are refused, and the relay never carries the
    /// document in the clear.
    @Test func viewOnlyEditsAreRefusedAndTrafficIsSealed() async {
        let (edit, view) = newRoom()
        let h = await host(edit)
        let v = join(view, id: "view01")
        #expect(await settled([h, v]))
        var refused: [String] = []
        v.onEvent = { if case .refused(let why) = $0 { refused.append(why) } }
        var e = CanvasEditor(v.replica.doc.canvases["c1"]!)
        e.setText(e.canvas.root, "Hijacked")
        v.record(e.patch(actionName: "Rename"))
        #expect(await eventually { !refused.isEmpty })
        #expect(h.replica.doc.canvases["c1"]!.nodes[h.replica.doc.canvases["c1"]!.root]?.text == "Launch plan")
        let traffic = relay.allTraffic().joined(separator: "\n")
        for word in ["Launch plan", "Pricing", "Hijacked", "Invite list"] { #expect(!traffic.contains(word)) }
    }

    @Test func endingTheSessionStopsEveryone() async {
        let (edit, _) = newRoom()
        let h = await host(edit)
        let p = join(edit, id: "peer1a")
        #expect(await settled([h, p]))
        relay.end(edit.room)
        #expect(await eventually { h.status == .ended && p.status == .ended })
        // No reconnecting after an End.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(p.status == .ended)
        #expect(relay.room(edit.room) == nil)
    }

    @Test func presenceReachesEveryoneAndIsThrottled() async {
        let (edit, _) = newRoom()
        let h = await host(edit)
        let p = join(edit, id: "peer1a")
        #expect(await settled([h, p]))
        var seen: [Presence] = []
        h.onEvent = { if case .presence(_, let pr) = $0 { seen.append(pr) } }
        for i in 0..<50 {
            p.setPresence(Presence(replica: "peer1a", name: "Ben", canvas: "c1", selection: ["n\(i)"]))
        }
        #expect(await eventually { seen.last?.selection == ["n49"] })
        // Fifty changes in a burst: the first goes at once, the rest collapse into the latest.
        #expect(seen.count <= 3)
        #expect(h.people.values.first?.name == "Ben")
        p.leave()
        #expect(await eventually { h.people.isEmpty })
    }

    /// A8: a participant restarted while offline keeps its edits and sends them on reconnecting.
    @Test func resumesAfterARestart() async throws {
        let (edit, _) = newRoom()
        let h = await host(edit)
        let p = join(edit, id: "peer1a")
        #expect(await settled([h, p]))
        relay.offline = true
        relay.drop(p.member)
        #expect(await eventually { p.status == .reconnecting })
        var e = CanvasEditor(p.replica.doc.canvases["c1"]!)
        _ = try e.addChild(of: e.canvas.root, text: "Offline idea")
        p.record(e.patch(actionName: "Add"))
        #expect(p.saved.outbox.count == 1)
        // Saved and reopened (the app keeps both in its container).
        let replica = try Replica(decoding: try p.replica.encoded())
        let saved = p.saved
        p.leave()
        relay.offline = false
        let back = RoomClient(invite: edit, replica: replica, saved: saved, connector: relay, sleep: fast)
        back.start()
        #expect(await settled([h, back]))
        #expect(h.replica.doc.canvases["c1"]!.nodes.values.contains { $0.text == "Offline idea" })
    }

    @Test func backoffDoublesToThirtySeconds() {
        #expect(RoomClient.backoff(0) == .milliseconds(500))
        #expect(RoomClient.backoff(1) == .seconds(1))
        #expect(RoomClient.backoff(5) == .seconds(16))
        #expect(RoomClient.backoff(6) == .seconds(30))
        #expect(RoomClient.backoff(100) == .seconds(30))
    }
}
