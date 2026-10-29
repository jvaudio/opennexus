import Foundation

/// The server's settings, read from environment variables (README › Settings).
public struct ServerConfig: Sendable {
    public enum Storage: Sendable {
        case disk(String)
        case s3(S3Config)
    }

    public var host = "0.0.0.0"
    public var port = 8787
    /// Who may create shares: the token the app's destination is set up with.
    public var uploadToken: String
    public var storage = Storage.disk("/data")
    /// The largest sealed share accepted, in bytes.
    public var maxBytes = 50 * 1024 * 1024
    /// When set, no share lives longer than this many days (and shares without an expiry get it).
    public var maxDays: Int?
    /// Requests per minute from one address: creating, updating and deleting; and reading.
    public var writesPerMinute = 30
    public var readsPerMinute = 600
    /// Behind a reverse proxy (Caddy), the client's address is the first in X-Forwarded-For.
    public var trustProxy = false
    // Live sessions' rooms (M46).
    /// Where rooms are written through (sealed bytes and hashes only); nil keeps them in memory.
    public var roomsDirectory: String?
    /// Rooms nobody has joined for this many days are deleted.
    public var roomIdleDays = 7
    /// The largest message (a snapshot with images in it), and the most a room may keep.
    public var roomMaxMessage = 32 * 1024 * 1024
    public var roomMaxBytes = 256 * 1024 * 1024
    public var roomMaxMembers = 50
    public var maxRooms = 1000
    /// Messages per second from one connection (twice that in a burst).
    public var roomMessagesPerSecond = 50

    public init(uploadToken: String) { self.uploadToken = uploadToken }

    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) throws
        -> ServerConfig
    {
        guard let token = env["OPENNEXUS_UPLOAD_TOKEN"], token.count >= 16 else {
            throw ConfigError("Set OPENNEXUS_UPLOAD_TOKEN to a random string of at least 16 characters.")
        }
        var c = ServerConfig(uploadToken: token)
        if let v = env["OPENNEXUS_HOST"], !v.isEmpty { c.host = v }
        if let v = env["OPENNEXUS_PORT"] { c.port = try int(v, "OPENNEXUS_PORT", 1...65_535) }
        if let v = env["OPENNEXUS_MAX_BYTES"] { c.maxBytes = try int(v, "OPENNEXUS_MAX_BYTES", 1024...Int.max) }
        if let v = env["OPENNEXUS_MAX_DAYS"], v != "0" { c.maxDays = try int(v, "OPENNEXUS_MAX_DAYS", 1...36_500) }
        if let v = env["OPENNEXUS_WRITES_PER_MINUTE"] {
            c.writesPerMinute = try int(v, "OPENNEXUS_WRITES_PER_MINUTE", 1...100_000)
        }
        if let v = env["OPENNEXUS_READS_PER_MINUTE"] {
            c.readsPerMinute = try int(v, "OPENNEXUS_READS_PER_MINUTE", 1...1_000_000)
        }
        c.trustProxy = ["1", "true", "yes"].contains(env["OPENNEXUS_TRUST_PROXY"]?.lowercased() ?? "")
        if let v = env["OPENNEXUS_ROOM_IDLE_DAYS"] { c.roomIdleDays = try int(v, "OPENNEXUS_ROOM_IDLE_DAYS", 1...3650) }
        if let v = env["OPENNEXUS_ROOM_MAX_MESSAGE"] {
            c.roomMaxMessage = try int(v, "OPENNEXUS_ROOM_MAX_MESSAGE", 4096...Int(Int32.max))
        }
        if let v = env["OPENNEXUS_ROOM_MAX_BYTES"] {
            c.roomMaxBytes = try int(v, "OPENNEXUS_ROOM_MAX_BYTES", 65_536...Int.max)
        }
        if let v = env["OPENNEXUS_ROOM_MAX_MEMBERS"] {
            c.roomMaxMembers = try int(v, "OPENNEXUS_ROOM_MAX_MEMBERS", 2...10_000)
        }
        if let v = env["OPENNEXUS_MAX_ROOMS"] { c.maxRooms = try int(v, "OPENNEXUS_MAX_ROOMS", 0...1_000_000) }
        if let v = env["OPENNEXUS_ROOM_MESSAGES_PER_SECOND"] {
            c.roomMessagesPerSecond = try int(v, "OPENNEXUS_ROOM_MESSAGES_PER_SECOND", 1...100_000)
        }
        switch env["OPENNEXUS_STORAGE"]?.lowercased() ?? "disk" {
        case "disk": c.storage = .disk(env["OPENNEXUS_DATA_DIR"] ?? "/data")
        case "s3":
            var s = S3Config()
            for (key, path) in [
                ("OPENNEXUS_S3_ENDPOINT", \S3Config.endpoint), ("OPENNEXUS_S3_BUCKET", \.bucket),
                ("OPENNEXUS_S3_ACCESS_KEY", \.accessKey), ("OPENNEXUS_S3_SECRET_KEY", \.secretKey),
            ] {
                guard let v = env[key], !v.isEmpty else { throw ConfigError("Set \(key) for S3 storage.") }
                s[keyPath: path] = v
            }
            if let v = env["OPENNEXUS_S3_REGION"], !v.isEmpty { s.region = v }
            if let v = env["OPENNEXUS_S3_PREFIX"] { s.prefix = v }
            if let v = env["OPENNEXUS_S3_PATH_STYLE"] { s.pathStyle = !["0", "false", "no"].contains(v.lowercased()) }
            guard URL(string: s.endpoint)?.host != nil else { throw ConfigError("OPENNEXUS_S3_ENDPOINT isn’t a URL.") }
            c.storage = .s3(s)
        case let other: throw ConfigError("OPENNEXUS_STORAGE is “\(other)”; use disk or s3.")
        }
        // Rooms beside the shares on disk; set it empty to keep rooms in memory only.
        let dataDir = env["OPENNEXUS_DATA_DIR"] ?? "/data"
        let rooms = env["OPENNEXUS_ROOMS_DIR"] ?? (dataDir.hasSuffix("/") ? dataDir : dataDir + "/") + "rooms"
        c.roomsDirectory = rooms.isEmpty ? nil : rooms
        return c
    }

    static func int(_ v: String, _ name: String, _ range: ClosedRange<Int>) throws -> Int {
        guard let n = Int(v), range.contains(n) else { throw ConfigError("\(name) must be a number in \(range).") }
        return n
    }
}

public struct S3Config: Sendable {
    public var endpoint = ""
    public var region = "us-east-1"
    public var bucket = ""
    public var prefix = "shares/"
    public var accessKey = ""
    public var secretKey = ""
    public var pathStyle = true
    public init() {}
}

public struct ConfigError: Error, CustomStringConvertible {
    public var description: String
    init(_ d: String) { description = d }
}
