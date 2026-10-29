import Foundation
import NexusFormat

@testable import NexusReplica

/// A relay in memory with the server's rules (roles from capabilities, numbered batches, a
/// stored snapshot and tail, fan-out, presence, End), delivering on its own queue like a
/// socket would. The real one is `server/`'s `RoomHub`; the live script runs the client
/// against it.
final class MemoryRelay: RoomConnector, @unchecked Sendable {
    final class Conn: RoomSocket, @unchecked Sendable {
        weak var relay: MemoryRelay?
        let room: String
        let events: @Sendable (SocketEvent) -> Void
        var member: String?
        var role: RoomClient.Role?
        var open = true

        init(relay: MemoryRelay, room: String, events: @escaping @Sendable (SocketEvent) -> Void) {
            self.relay = relay
            self.room = room
            self.events = events
        }

        func send(_ text: String) { relay?.queue.async { [self] in relay?.receive(self, text) } }
        func close() { relay?.queue.async { [self] in relay?.disconnect(self) } }
    }

    struct Room {
        var read: String
        var write: String
        var seq = 0
        var snapshot: (seq: Int, data: Data)?
        var tail: [RelayFrame.Sequenced] = []
        var members: [String: Conn] = [:]
        var nextMember = 1
        var asked = false
        var view: Data?
    }

    let queue = DispatchQueue(label: "memory-relay")
    var rooms: [String: Room] = [:]
    /// The relay asks for a snapshot when the tail is longer than this.
    var snapshotAfter = 200
    /// Refuses connections, as if the network were down.
    var offline = false
    /// Every frame's text, both ways, for the plaintext check.
    var traffic: [String] = []

    func createRoom(read: String, write: String) -> String {
        let id = Sealed.randomBytes(16).base64URL()
        queue.sync { rooms[id] = Room(read: Invite.digest(read), write: Invite.digest(write)) }
        return id
    }

    func open(_ url: URL, events: @escaping @Sendable (SocketEvent) -> Void) -> any RoomSocket {
        let c = Conn(relay: self, room: url.lastPathComponent, events: events)
        queue.async { [self] in
            if offline || rooms[c.room] == nil {
                c.open = false
                c.events(.closed("unreachable"))
            } else {
                c.events(.opened)
            }
        }
        return c
    }

    func out(_ c: Conn, _ f: RelayFrame) {
        guard c.open else { return }
        let t = f.text
        traffic.append(t)
        c.events(.text(t))
    }

    func receive(_ c: Conn, _ text: String) {
        guard c.open, var room = rooms[c.room], let f = ClientFrame(text: text) else { return }
        traffic.append(text)
        defer { rooms[c.room] = room }
        switch f {
        case .hello(let cap, let since):
            let d = Invite.digest(cap)
            guard d == room.write || d == room.read else {
                return out(c, .error(code: "unauthorized", message: "That invite isn’t valid for this session."))
            }
            c.role = d == room.write ? .edit : .view
            let m = "m\(room.nextMember)"
            room.nextMember += 1
            c.member = m
            var snapshot: (Int, Data)?
            var ops = room.tail.filter { $0.seq > since }
            if let s = room.snapshot, since < s.seq {
                snapshot = s
                ops = room.tail
            }
            out(
                c,
                .welcome(
                    .init(
                        role: c.role!, member: m, members: room.members.keys.sorted(), snapshot: snapshot, ops: ops,
                        seq: room.seq)))
            for o in room.members.values { out(o, .joined(m)) }
            room.members[m] = c
        case .ops(let id, let data):
            guard c.role == .edit, let m = c.member else {
                return out(c, .error(code: "read-only", message: "You can view this session but not edit it."))
            }
            room.seq += 1
            let s = RelayFrame.Sequenced(seq: room.seq, member: m, data: data)
            room.tail.append(s)
            out(c, .ack(id: id, seq: room.seq))
            for (k, o) in room.members where k != m { out(o, .ops(s)) }
            if room.tail.count > snapshotAfter, !room.asked {
                room.asked = true
                out(c, .snapshot)
            }
        case .presence(let data):
            guard let m = c.member else { return }
            for (k, o) in room.members where k != m { out(o, .presence(member: m, data: data)) }
        case .snapshot(let seq, let data):
            guard c.role == .edit, seq <= room.seq, seq >= (room.snapshot?.seq ?? 0) else { return }
            room.snapshot = (seq, data)
            room.tail.removeAll { $0.seq <= seq }
            room.asked = false
        case .view(let data):
            guard c.role == .edit else { return }
            room.view = data
        }
    }

    func disconnect(_ c: Conn) {
        guard c.open else { return }
        c.open = false
        if let m = c.member, rooms[c.room]?.members[m] === c {
            rooms[c.room]?.members[m] = nil
            for o in rooms[c.room]?.members.values.map({ $0 }) ?? [] { out(o, .left(m)) }
        }
        c.events(.closed(nil))
    }

    /// Drops every connection (a network blip); clients reconnect on their own.
    func dropAll() {
        queue.sync {
            for r in rooms.values { for c in r.members.values { disconnect(c) } }
        }
    }

    /// Drops one member's connection.
    func drop(_ member: String?) {
        queue.sync {
            for r in rooms.values { if let m = member, let c = r.members[m] { disconnect(c) } }
        }
    }

    func end(_ room: String) {
        queue.sync {
            for c in rooms[room]?.members.values.map({ $0 }) ?? [] {
                out(c, .ended)
                c.open = false
                c.events(.closed(nil))
            }
            rooms[room] = nil
        }
    }

    func room(_ id: String) -> Room? { queue.sync { rooms[id] } }
    func allTraffic() -> [String] { queue.sync { traffic } }
}
