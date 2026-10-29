#if os(macOS)
import Foundation
import NexusCore
import NexusFormat
import NexusReplica
import NexusScene
import Security

// The Mac's way to the network (M47a): every request goes through `OpenNexusNet.xpc`, and
// credentials live in the login Keychain. `PlatformNetwork` hands them to the centres.

/// `OpenNexusNet.xpc`, over a private XPC connection (only the app can open it).
public struct XPCShareTransport: ShareTransport {
    public init() {}

    public func perform(_ job: NetJob, body: Data) async -> NetReply {
        await exchange(job, body: body).reply
    }

    public func exchange(_ job: NetJob, body: Data) async -> (reply: NetReply, body: Data) {
        guard let data = try? JSONEncoder().encode(job) else {
            return (.failed("The request couldn’t be encoded."), Data())
        }
        return await withCheckedContinuation { cont in
            let call = XPCCall(cont)
            let proxy =
                call.connection.remoteObjectProxyWithErrorHandler { error in
                    call.finish(.failed("The network service didn’t answer (\(error.localizedDescription))."), Data())
                } as? NetServiceProtocol
            guard let proxy else { return call.finish(.failed("The network service isn’t available."), Data()) }
            proxy.perform(data, body: body) { reply, body in
                call.finish(
                    (try? JSONDecoder().decode(NetReply.self, from: reply)) ?? .failed("Unreadable reply."), body)
            }
        }
    }
}

/// One call: its connection, answered once (the reply or the error handler, whichever comes first).
private final class XPCCall: @unchecked Sendable {
    let connection = NSXPCConnection(serviceName: NetXPC.serviceName)
    private var cont: CheckedContinuation<(reply: NetReply, body: Data), Never>?
    private let lock = NSLock()

    init(_ cont: CheckedContinuation<(reply: NetReply, body: Data), Never>) {
        self.cont = cont
        connection.remoteObjectInterface = NSXPCInterface(with: NetServiceProtocol.self)
        connection.resume()
    }

    func finish(_ reply: NetReply, _ body: Data) {
        let c = lock.withLock {
            defer { cont = nil }
            return cont
        }
        c?.resume(returning: (reply, body))
        connection.invalidate()
    }
}

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

/// The login Keychain: generic passwords, this app only.
public struct KeychainSecrets: SecretStore {
    public var service: String
    public init(service: String = "org.opennexus.sharing") { self.service = service }

    func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func secret(_ account: String) -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    public func setSecret(_ data: Data, _ account: String) {
        deleteSecret(account)
        var q = query(account)
        q[kSecValueData as String] = data
        q[kSecAttrLabel as String] = "OpenNexus sharing"
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        SecItemAdd(q as CFDictionary, nil)
    }

    public func deleteSecret(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}
#endif
