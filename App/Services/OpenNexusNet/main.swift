import Foundation
import NexusFormat
import NexusNet

/// OpenNexusNet.xpc (M44): the one OpenNexus process with the network entitlement (D313).
/// The app hands it one job at a time; it makes the requests that job needs, only to the
/// hosts the job allows, and replies with the outcome, a log entry for every request, and
/// the bytes a sync read (M45).
/// An app's XPC service can be reached only by that app.
final class Service: NSObject, NetServiceProtocol {
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
}

final class Listener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: NetServiceProtocol.self)
        connection.exportedObject = Service()
        connection.resume()
        return true
    }
}

let delegate = Listener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
