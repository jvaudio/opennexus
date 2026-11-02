import Foundation

/// The network, replaced: each request is recorded and answered by `respond`. Tests that
/// use it are serialized (one handler at a time).
final class Stub: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data
    }

    typealias Answer = (status: Int, headers: [String: String], body: Data)

    nonisolated(unsafe) static var respond: @Sendable (Seen) -> Answer = { _ in (500, [:], Data()) }
    nonisolated(unsafe) static var seen: [Seen] = []
    static let lock = NSLock()

    static func reset(_ respond: @escaping @Sendable (Seen) -> Answer) {
        lock.withLock {
            self.respond = respond
            seen = []
        }
    }

    static var requests: [Seen] { lock.withLock { seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {
            s.open()
            var buf = [UInt8](repeating: 0, count: 65_536)
            while s.hasBytesAvailable {
                let n = s.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            s.close()
        }
        let seen = Seen(
            method: request.httpMethod ?? "GET", url: request.url!, headers: request.allHTTPHeaderFields ?? [:],
            body: body)
        let answer = Self.lock.withLock {
            Self.seen.append(seen)
            return Self.respond(seen)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension Stub.Seen {
    func header(_ name: String) -> String? {
        headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }
}
