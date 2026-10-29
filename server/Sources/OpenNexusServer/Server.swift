import Crypto
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket
import NIOCore

/// The request context: the client's address, for rate limits.
public struct ShareContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    public let remoteAddress: String?

    public init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        remoteAddress = source.channel.remoteAddress?.ipAddress
    }
}

/// The share API (README › API). It stores sealed envelopes and never sees a key.
///
/// - `GET /v1/health`
/// - `POST /v1/shares` with `Authorization: Bearer <upload token>` → `{"id", "secret"}`
/// - `GET /v1/shares/{id}`, from any origin, without credentials
/// - `PUT` and `DELETE /v1/shares/{id}` with `Authorization: Bearer <write secret>`
///
/// `X-OpenNexus-Expires` (ISO 8601) on POST or PUT sets when the share stops being served.
///
/// Live sessions' rooms (M46) are `Rooms.swift`.
public struct ShareAPI: Sendable {
    public let config: ServerConfig
    public let storage: any ShareStorage
    public let rooms: RoomHub
    let writes: RateLimiter
    let reads: RateLimiter
    let sweeper: Sweeper
    let now: @Sendable () -> Date

    public init(
        config: ServerConfig, storage: any ShareStorage, rooms: RoomHub? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.config = config
        self.storage = storage
        self.rooms = rooms ?? RoomHub(memory: config, now: now)
        self.now = now
        writes = RateLimiter(perMinute: config.writesPerMinute)
        reads = RateLimiter(perMinute: config.readsPerMinute)
        sweeper = Sweeper(storage: storage)
    }

    static let magic: [UInt8] = Array("ONX1".utf8)
    static let expiresHeader = HTTPField.Name("X-OpenNexus-Expires")!
    static let forwardedFor = HTTPField.Name("X-Forwarded-For")!
    static let referrerPolicy = HTTPField.Name("Referrer-Policy")!

    public func router() -> Router<ShareContext> {
        let router = Router(context: ShareContext.self)
        router.add(middleware: Headers())
        router.get("v1/health") { _, _ in
            Self.json(.ok, #"{"service":"opennexus-server","version":1}"#)
        }
        router.post("v1/shares") { request, context in try await create(request, context) }
        router.get("v1/shares/:id") { request, context in try await read(request, context) }
        router.on("v1/shares/:id", method: .options) { _, _ in
            Response(
                status: .noContent,
                headers: [
                    .accessControlAllowMethods: "GET", .accessControlMaxAge: "86400",
                ])
        }
        router.put("v1/shares/:id") { request, context in try await replace(request, context) }
        router.delete("v1/shares/:id") { request, context in try await remove(request, context) }
        addRoomRoutes(router)
        return router
    }

    // MARK: Routes

    func create(_ request: Request, _ context: ShareContext) async throws -> Response {
        if let wait = await writes.check(address(request, context), now: now()) { return Self.tooMany(wait) }
        guard Self.matches(Self.bearer(request), config.uploadToken) else {
            return Self.fail(.unauthorized, "The upload token is missing or wrong.")
        }
        let body: Data
        switch await collect(request) {
        case .success(let d): body = d
        case .failure(let f): return f.response
        }
        let expires: Date?
        switch expiry(request) {
        case .success(let d): expires = d
        case .failure(let f): return f.response
        }
        let id = Self.random(16)
        let secret = Self.random(32)
        try await storage.put(
            id, body, ShareMeta(secret: Self.digest(secret), created: now(), expires: expires, size: body.count))
        await sweeper.sweepIfDue(now: now())
        context.logger.info("created share", metadata: ["bytes": "\(body.count)"])
        return Self.json(.created, #"{"id":"\#(id)","secret":"\#(secret)"}"#)
    }

    func read(_ request: Request, _ context: ShareContext) async throws -> Response {
        if let wait = await reads.check(address(request, context), now: now()) { return Self.tooMany(wait) }
        guard let id = Self.shareID(context), let meta = try await storage.meta(id) else {
            return Self.fail(.notFound, "No such share.")
        }
        if meta.isExpired(now()) {
            try await storage.delete(id)
            return Self.fail(.gone, "This share has expired.")
        }
        guard let data = try await storage.get(id) else { return Self.fail(.notFound, "No such share.") }
        return Response(
            status: .ok,
            headers: [.contentType: "application/octet-stream", .cacheControl: "no-store"],
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    func replace(_ request: Request, _ context: ShareContext) async throws -> Response {
        if let wait = await writes.check(address(request, context), now: now()) { return Self.tooMany(wait) }
        let (id, meta, denied) = try await authorize(request, context)
        guard let id, var meta else { return denied! }
        let body: Data
        switch await collect(request) {
        case .success(let d): body = d
        case .failure(let f): return f.response
        }
        switch expiry(request) {
        case .success(let d): meta.expires = d
        case .failure(let f): return f.response
        }
        meta.size = body.count
        try await storage.put(id, body, meta)
        return Response(status: .noContent)
    }

    func remove(_ request: Request, _ context: ShareContext) async throws -> Response {
        if let wait = await writes.check(address(request, context), now: now()) { return Self.tooMany(wait) }
        let (id, _, denied) = try await authorize(request, context)
        guard let id else { return denied! }
        try await storage.delete(id)
        return Response(status: .noContent)
    }

    // MARK: Checks

    /// The share and its record when the request carries its write secret.
    func authorize(_ request: Request, _ context: ShareContext) async throws -> (String?, ShareMeta?, Response?) {
        guard let id = Self.shareID(context), let meta = try await storage.meta(id) else {
            return (nil, nil, Self.fail(.notFound, "No such share."))
        }
        guard let given = Self.bearer(request), Self.matches(Self.digest(given), meta.secret) else {
            return (nil, nil, Self.fail(.forbidden, "The write secret is missing or wrong."))
        }
        return (id, meta, nil)
    }

    /// The body, if it's a sealed envelope no larger than the limit.
    func collect(_ request: Request) async -> Result<Data, ResponseFailure> {
        if let n = request.headers[.contentLength].flatMap(Int.init), n > config.maxBytes {
            return .failure(ResponseFailure(Self.tooLarge(config.maxBytes)))
        }
        let buffer: ByteBuffer
        do {
            buffer = try await request.body.collect(upTo: config.maxBytes)
        } catch {
            return .failure(ResponseFailure(Self.tooLarge(config.maxBytes)))
        }
        let data = Data(buffer: buffer)
        guard data.count > 8 + 12 + 16, Array(data.prefix(4)) == Self.magic else {
            return .failure(
                ResponseFailure(Self.fail(.unsupportedMediaType, "Only sealed OpenNexus shares can be stored here.")))
        }
        return .success(data)
    }

    /// `X-OpenNexus-Expires`, in the future and within `maxDays`; `maxDays` when absent.
    func expiry(_ request: Request) -> Result<Date?, ResponseFailure> {
        let t = now()
        let cap = config.maxDays.map { t.addingTimeInterval(Double($0) * 86_400) }
        guard let text = request.headers[Self.expiresHeader] else { return .success(cap) }
        guard let d = ISO8601DateFormatter().date(from: text), d > t else {
            return .failure(
                ResponseFailure(Self.fail(.badRequest, "X-OpenNexus-Expires must be a future ISO 8601 time.")))
        }
        if let cap, d > cap {
            return .failure(
                ResponseFailure(
                    Self.fail(.badRequest, "This server keeps shares for at most \(config.maxDays!) days.")))
        }
        return .success(d)
    }

    /// The client: the connection's address, or behind a proxy the first X-Forwarded-For.
    func address(_ request: Request, _ context: ShareContext) -> String {
        if config.trustProxy, let f = request.headers[Self.forwardedFor]?.split(separator: ",").first {
            return f.trimmingCharacters(in: .whitespaces)
        }
        return context.remoteAddress ?? "unknown"
    }

    struct ResponseFailure: Error {
        var response: Response
        init(_ r: Response) { response = r }
    }

    // MARK: Helpers

    static func shareID(_ context: ShareContext) -> String? {
        guard let id = context.parameters.get("id"), id.count == 22,
            id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        return id
    }

    static func bearer(_ request: Request) -> String? {
        guard let a = request.headers[.authorization], a.hasPrefix("Bearer ") else { return nil }
        return String(a.dropFirst(7))
    }

    /// Compares SHA-256 digests in constant time.
    static func matches(_ given: String?, _ expected: String) -> Bool {
        guard let given else { return false }
        let a = Array(SHA256.hash(data: Data(given.utf8)))
        let b = Array(SHA256.hash(data: Data(expected.utf8)))
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    static func digest(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func random(_ n: Int) -> String {
        var g = SystemRandomNumberGenerator()
        let bytes = (0..<n).map { _ in UInt8.random(in: 0...255, using: &g) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func json(_ status: HTTPResponse.Status, _ text: String) -> Response {
        Response(
            status: status, headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(string: text)))
    }

    static func fail(_ status: HTTPResponse.Status, _ message: String) -> Response {
        let escaped = message.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return json(status, #"{"error":"\#(escaped)"}"#)
    }

    static func tooLarge(_ max: Int) -> Response {
        fail(.contentTooLarge, "Shares on this server are at most \(max) bytes.")
    }

    static func tooMany(_ wait: Int) -> Response {
        var r = fail(.tooManyRequests, "Too many requests; try again shortly.")
        r.headers[.retryAfter] = "\(wait)"
        return r
    }
}

/// Every response: readable from any origin (shares are public ciphertext and nothing uses
/// cookies), never cached, never sniffed, no referrer.
struct Headers: RouterMiddleware {
    typealias Context = ShareContext
    func handle(_ request: Request, context: ShareContext, next: (Request, ShareContext) async throws -> Response)
        async throws -> Response
    {
        var r: Response
        do {
            r = try await next(request, context)
        } catch let e as HTTPError {
            r = ShareAPI.fail(e.status, e.body ?? e.status.reasonPhrase)
        }
        r.headers[.accessControlAllowOrigin] = "*"
        r.headers[.xContentTypeOptions] = "nosniff"
        r.headers[ShareAPI.referrerPolicy] = "no-referrer"
        r.headers[.crossOriginResourcePolicy] = "cross-origin"
        if r.headers[.cacheControl] == nil { r.headers[.cacheControl] = "no-store" }
        return r
    }
}

/// The application: the API on the configured address and storage.
public func buildApplication(_ config: ServerConfig) throws -> some ApplicationProtocol {
    let storage: any ShareStorage =
        switch config.storage {
        case .disk(let dir): try DiskStorage(directory: dir)
        case .s3(let s): S3Storage(s)
        }
    let api = ShareAPI(config: config, storage: storage, rooms: try RoomHub(config: config))
    return Application(
        router: api.router(),
        server: .http1WebSocketUpgrade(
            webSocketRouter: api.socketRouter(),
            configuration: .init(ws: .init(maxFrameSize: config.roomMaxMessage, closeTimeout: .seconds(5)))),
        configuration: .init(address: .hostname(config.host, port: config.port), serverName: "opennexus-server"))
}
