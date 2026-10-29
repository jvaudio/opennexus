import Foundation
import NexusFormat

/// The network rule's code (D313): the only module that makes requests, linked only into
/// `OpenNexusNet.xpc`. Every request is checked against the job's allow-list (redirects
/// too, one hop at a time) and recorded for the Privacy card's log.

public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data

    public init(_ method: String, _ url: URL, headers: [String: String] = [:], body: Data = Data()) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    /// Header names in lower case.
    public var headers: [String: String]
    public var body: Data

    public var ok: Bool { (200..<300).contains(status) }
    public var text: String { String(decoding: body.prefix(2048), as: UTF8.self) }
}

public enum NetError: Error, Equatable, CustomStringConvertible {
    /// The host isn't one the user configured.
    case notAllowed(String)
    /// No response: offline, the host didn't answer, TLS failed.
    case unreachable(String)
    /// The destination answered with an error.
    case status(Int, String)
    /// The answer wasn't what the destination's API promises.
    case unexpected(String)

    public var description: String {
        switch self {
        case .notAllowed(let h): "\(h) isn’t one of your destinations, so OpenNexus didn’t contact it."
        case .unreachable(let why): "Couldn’t reach the destination: \(why)"
        case .status(let s, let why): "The destination answered \(s)\(why.isEmpty ? "" : ": \(why)")"
        case .unexpected(let why): "Unexpected answer from the destination: \(why)"
        }
    }
}

/// Sends requests for one job and keeps its log.
public actor HTTPClient {
    public let allowed: Set<String>
    public let purpose: String
    let session: URLSession
    public private(set) var log: [NetLogEntry] = []
    /// Redirects followed per request, each checked against the allow-list.
    static let maxRedirects = 3

    /// `protocolClasses` replaces the network with a stub (tests).
    public init(allowed: [String], purpose: String, protocolClasses: [AnyClass]? = nil) {
        self.allowed = Set(allowed.map { $0.lowercased() })
        self.purpose = purpose
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.timeoutIntervalForRequest = 60
        c.timeoutIntervalForResource = 600
        c.waitsForConnectivity = false
        if let protocolClasses { c.protocolClasses = protocolClasses }
        session = URLSession(configuration: c)
    }

    public func isAllowed(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return allowed.contains(host) && ShareDestination.secure(url)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var r = request
        for _ in 0...Self.maxRedirects {
            let response = try await sendOnce(r)
            guard [301, 302, 303, 307, 308].contains(response.status), let location = response.headers["location"],
                let next = URL(string: location, relativeTo: r.url)?.absoluteURL
            else { return response }
            if response.status == 303 || (response.status != 307 && response.status != 308 && r.method == "POST") {
                r = HTTPRequest("GET", next, headers: r.headers.filter { $0.key.lowercased() != "content-type" })
            } else {
                r.url = next
            }
            // Credentials never follow a redirect to another host.
            if next.host() != request.url.host() { r.headers.removeValue(forKey: "Authorization") }
        }
        throw NetError.unexpected("too many redirects")
    }

    func sendOnce(_ r: HTTPRequest) async throws -> HTTPResponse {
        let host = r.url.host()?.lowercased() ?? r.url.absoluteString
        guard isAllowed(r.url) else {
            record(host, r.method, status: 0, sent: 0, received: 0, refused: true)
            throw NetError.notAllowed(host)
        }
        var u = URLRequest(url: r.url)
        u.httpMethod = r.method
        for (k, v) in r.headers { u.setValue(v, forHTTPHeaderField: k) }
        if !r.body.isEmpty || ["PUT", "POST", "PATCH"].contains(r.method) { u.httpBody = r.body }
        do {
            let (data, response) = try await session.data(for: u, delegate: NoRedirects())
            let http = response as? HTTPURLResponse
            var headers: [String: String] = [:]
            for (k, v) in http?.allHeaderFields ?? [:] {
                if let k = k as? String, let v = v as? String { headers[k.lowercased()] = v }
            }
            let status = http?.statusCode ?? 0
            record(host, r.method, status: status, sent: r.body.count, received: data.count)
            return HTTPResponse(status: status, headers: headers, body: data)
        } catch {
            record(host, r.method, status: 0, sent: r.body.count, received: 0)
            throw NetError.unreachable((error as NSError).localizedDescription)
        }
    }

    func record(_ host: String, _ method: String, status: Int, sent: Int, received: Int, refused: Bool = false) {
        log.append(
            NetLogEntry(
                date: Date(), host: host, method: method, purpose: refused ? "\(purpose) (refused)" : purpose,
                status: status, sent: sent, received: received))
    }
}

/// Redirects come back to `HTTPClient.send`, which checks the new host first.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? { nil }
}
