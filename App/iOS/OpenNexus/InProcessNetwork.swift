import Foundation
import NexusCanvas
import NexusFormat
import NexusNet
import NexusReplica

/// The iPad's way to the network (M47b, D389): `NexusNet` in the app's own process,
/// behind the same switches, host allow-lists and request log as the Mac's
/// `OpenNexusNet.xpc`. iOS has no XPC services for apps, so this is the app's one
/// adapter; every request still names the hosts its job allows.
@MainActor
struct InProcessNetwork: NetworkProvider {
    func transport() -> any ShareTransport { Transport() }

    func connector(purpose: String, log: NetworkLog) -> any RoomConnector {
        Connector(purpose: purpose) { entries in Task { @MainActor in log.append(entries) } }
    }

    struct Transport: ShareTransport {
        func perform(_ job: NetJob, body: Data) async -> NetReply { await NetService().perform(job, body: body) }

        func exchange(_ job: NetJob, body: Data) async -> (reply: NetReply, body: Data) {
            await NetService().exchange(job, body: body)
        }
    }

    /// A session's socket, allowed to reach only the invite's own server.
    struct Connector: RoomConnector {
        var purpose: String
        var onLog: @Sendable ([NetLogEntry]) -> Void

        func open(_ url: URL, events: @escaping @Sendable (SocketEvent) -> Void) -> any RoomSocket {
            let onLog = onLog
            let socket = NetSocket(url: url, allowed: [url.host()?.lowercased() ?? ""], purpose: purpose) { e in
                switch e {
                case .opened(let log):
                    onLog([log])
                    events(.opened)
                case .text(let t): events(.text(t))
                case .closed(let why, let log):
                    onLog([log])
                    events(.closed(why))
                }
            }
            socket.open()
            return Socket(socket: socket)
        }
    }

    final class Socket: RoomSocket {
        let socket: NetSocket
        init(socket: NetSocket) { self.socket = socket }
        func send(_ text: String) { socket.send(text) }
        func close() { socket.close() }
    }
}
