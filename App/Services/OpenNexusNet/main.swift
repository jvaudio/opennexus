import Foundation
import NexusFormat
import NexusNet

/// OpenNexusNet.xpc (M44): the one OpenNexus process with the network entitlement (D313).
/// The app hands it one job at a time; it makes the requests that job needs, only to the
/// hosts the job allows (for a share link the user opens, the link's own hosts, D441), and
/// replies with the outcome, a log entry for every request, and the bytes a sync or a link
/// read (M45, M47d). A live session's socket (M46) is a connection of its own.
/// An app's XPC service can be reached only by that app.
final class Service: NSObject, NetServiceProtocol, @unchecked Sendable {
    weak var connection: NSXPCConnection?
    let lock = NSLock()
    var socket: NetSocket?

    init(_ connection: NSXPCConnection) {
        self.connection = connection
    }

    func perform(_ job: Data, body: Data, reply: @escaping @Sendable (Data, Data) -> Void) {
        guard let j = try? JSONDecoder().decode(NetJob.self, from: job) else {
            reply((try? JSONEncoder().encode(NetReply.failed("Unreadable request."))) ?? Data(), Data())
            return
        }
        Task {
            let r = await NetService().exchange(j, body: body)
            reply((try? JSONEncoder().encode(r.reply)) ?? Data(), r.body)
        }
    }

    // MARK: A session's socket

    var events: NetSocketEvents? { connection?.remoteObjectProxy as? NetSocketEvents }

    func openSocket(_ job: Data) {
        let encoder = JSONEncoder()
        guard let j = try? JSONDecoder().decode(NetJob.self, from: job), j.action == .socket,
            let address = j.object, let url = URL(string: address)
        else {
            events?.socketClosed("Unreadable request.", log: Data())
            return
        }
        let s = NetSocket(url: url, allowed: j.allowedHosts, purpose: j.purpose) { [weak self] e in
            guard let events = self?.events else { return }
            switch e {
            case .opened(let log): events.socketOpened((try? encoder.encode(log)) ?? Data())
            case .text(let t): events.socketReceived(t)
            case .closed(let why, let log): events.socketClosed(why, log: (try? encoder.encode(log)) ?? Data())
            }
        }
        let old = lock.withLock {
            defer { socket = s }
            return socket
        }
        old?.close()
        s.open()
    }

    func sendText(_ text: String) {
        lock.withLock { socket }?.send(text)
    }

    func closeSocket() {
        lock.withLock { socket }?.close()
    }
}

final class Listener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let service = Service(connection)
        connection.exportedInterface = NSXPCInterface(with: NetServiceProtocol.self)
        connection.exportedObject = service
        connection.remoteObjectInterface = NSXPCInterface(with: NetSocketEvents.self)
        // The app went away: so does its socket.
        connection.invalidationHandler = { service.closeSocket() }
        connection.interruptionHandler = { service.closeSocket() }
        connection.resume()
        return true
    }
}

let delegate = Listener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
