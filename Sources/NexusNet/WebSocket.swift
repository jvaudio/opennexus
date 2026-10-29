import Foundation
import NexusFormat

/// A live session's WebSocket (M46), allow-listed like every request: the address's host
/// must be the job's. The Privacy card's log gets one entry when it opens and one, with the
/// byte totals, when it closes; never a frame's content.
public final class NetSocket: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    public enum Event: Sendable {
        /// Open, with its log entry.
        case opened(NetLogEntry)
        case text(String)
        /// Closed or failed (why, if it failed), with the log entry and its byte totals.
        case closed(String?, NetLogEntry)
    }

    let url: URL
    let host: String
    let allowed: Set<String>
    let purpose: String
    let events: @Sendable (Event) -> Void
    let lock = NSLock()
    var session: URLSession?
    var task: URLSessionWebSocketTask?
    var sent = 0
    var received = 0
    var finished = false
    var refused = false
    /// Sends are one at a time, in order.
    var queue: [String] = []
    var sending = false

    /// The largest frame accepted: a snapshot with images in it.
    public static let maxFrame = 64 * 1024 * 1024

    public init(url: URL, allowed: [String], purpose: String, events: @escaping @Sendable (Event) -> Void) {
        self.url = url
        host = url.host()?.lowercased() ?? url.absoluteString
        self.allowed = Set(allowed.map { $0.lowercased() })
        self.purpose = purpose
        self.events = events
    }

    /// `ws` and `wss` follow the same rule as HTTP: TLS, or this Mac only.
    public static func isAllowed(_ url: URL, allowed: Set<String>) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(), allowed.contains(host)
        else { return false }
        return scheme == "wss" || (scheme == "ws" && ["localhost", "127.0.0.1", "::1"].contains(host))
    }

    public func open() {
        guard Self.isAllowed(url, allowed: allowed) else {
            lock.withLock { refused = true }
            return finish("\(host) isn’t the session’s server, so OpenNexus didn’t contact it.")
        }
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.waitsForConnectivity = false
        let s = URLSession(configuration: c, delegate: self, delegateQueue: nil)
        let t = s.webSocketTask(with: url)
        t.maximumMessageSize = Self.maxFrame
        lock.withLock {
            session = s
            task = t
        }
        t.resume()
        receive(t)
    }

    public func send(_ text: String) {
        lock.withLock { queue.append(text) }
        pump()
    }

    func pump() {
        let next: (URLSessionWebSocketTask, String)? = lock.withLock {
            guard !sending, !finished, let task, !queue.isEmpty else { return nil }
            sending = true
            return (task, queue.removeFirst())
        }
        guard let (t, text) = next else { return }
        t.send(.string(text)) { [weak self] error in
            guard let self else { return }
            self.lock.withLock {
                self.sending = false
                if error == nil { self.sent += text.utf8.count }
            }
            if let error { return self.finish(error.localizedDescription) }
            self.pump()
        }
    }

    public func close() {
        let t = lock.withLock { task }
        t?.cancel(with: .normalClosure, reason: nil)
        finish(nil)
    }

    func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.string(let s)):
                self.lock.withLock { self.received += s.utf8.count }
                self.events(.text(s))
                self.receive(t)
            case .success(.data(let d)):
                self.lock.withLock { self.received += d.count }
                self.receive(t)
            case .success:
                self.receive(t)
            case .failure(let e):
                self.finish(e.localizedDescription)
            }
        }
    }

    public func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?
    ) {
        events(.opened(entry(status: 101, purpose: purpose, sent: 0, received: 0)))
    }

    public func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        finish(closeCode == .normalClosure ? nil : "closed (\(closeCode.rawValue))")
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        finish(error?.localizedDescription)
    }

    func finish(_ why: String?) {
        let closing: NetLogEntry? = lock.withLock {
            guard !finished else { return nil }
            finished = true
            return entry(
                status: 0, purpose: refused ? "\(purpose) (refused)" : "\(purpose) (closed)", sent: sent,
                received: received)
        }
        guard let closing else { return }
        session?.invalidateAndCancel()
        events(.closed(why, closing))
    }

    func entry(status: Int, purpose: String, sent: Int, received: Int) -> NetLogEntry {
        NetLogEntry(
            date: Date(), host: host, method: "WS", purpose: purpose, status: status, sent: sent, received: received)
    }
}
