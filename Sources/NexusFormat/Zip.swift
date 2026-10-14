import Foundation

/// A small ZIP reader and writer: stored and deflate entries, no ZIP64, no encryption.
/// Enough for .xmind, .mmap, .docx, .pptx, TextBundle archives and encrypted packages.
public enum Zip {
    public enum ReadError: Error, Equatable, CustomStringConvertible {
        case notAZip
        case truncated
        case unsupportedMethod(String, UInt16)
        case tooLarge(String)
        case corrupt(String)

        public var description: String {
            switch self {
            case .notAZip: "not a ZIP archive"
            case .truncated: "the archive is truncated"
            case .unsupportedMethod(let n, let m): "\(n): unsupported compression method \(m)"
            case .tooLarge(let n): "\(n): entry is too large"
            case .corrupt(let n): "\(n): corrupt entry"
            }
        }
    }

    /// Entries larger than this are refused (zip-bomb guard).
    public static let maxEntrySize = 512 * 1024 * 1024

    /// Reads every file entry (directories are skipped). Names keep their archive paths.
    public static func read(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        func u16(_ o: Int) throws -> Int {
            guard o >= 0, o + 2 <= bytes.count else { throw ReadError.truncated }
            return Int(bytes[o]) | Int(bytes[o + 1]) << 8
        }
        func u32(_ o: Int) throws -> Int {
            guard o >= 0, o + 4 <= bytes.count else { throw ReadError.truncated }
            return Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
        }
        guard bytes.count >= 22 else { throw ReadError.notAZip }
        // The end-of-central-directory record is within the last 64 KiB + 22 bytes.
        var eocd = -1
        var i = bytes.count - 22
        let floor = max(0, bytes.count - 65_557)
        while i >= floor {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw bytes.starts(with: [0x50, 0x4B]) ? ReadError.truncated : ReadError.notAZip }
        let count = try u16(eocd + 10)
        var p = try u32(eocd + 16)
        var out: [String: Data] = [:]
        for _ in 0..<count {
            guard try u32(p) == 0x0201_4B50 else { throw ReadError.truncated }
            let method = UInt16(try u16(p + 10))
            let compressed = try u32(p + 20)
            let size = try u32(p + 24)
            let nameLen = try u16(p + 28)
            let extraLen = try u16(p + 30)
            let commentLen = try u16(p + 32)
            let local = try u32(p + 42)
            guard p + 46 + nameLen <= bytes.count else { throw ReadError.truncated }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen
            if name.hasSuffix("/") { continue }
            guard size <= maxEntrySize, compressed <= maxEntrySize else { throw ReadError.tooLarge(name) }
            guard try u32(local) == 0x0403_4B50 else { throw ReadError.corrupt(name) }
            let start = local + 30 + (try u16(local + 26)) + (try u16(local + 28))
            guard start >= 0, start + compressed <= bytes.count else { throw ReadError.truncated }
            let body = Data(bytes[start..<(start + compressed)])
            switch method {
            case 0:
                out[name] = body
            case 8:
                guard let inflated = try? (body as NSData).decompressed(using: .zlib) as Data else {
                    throw ReadError.corrupt(name)
                }
                guard inflated.count == size || size == 0 else { throw ReadError.corrupt(name) }
                out[name] = inflated
            default:
                throw ReadError.unsupportedMethod(name, method)
            }
        }
        return out
    }

    /// True when the data starts like a ZIP archive.
    public static func looksLikeZip(_ data: Data) -> Bool { data.starts(with: [0x50, 0x4B, 0x03, 0x04]) }
}

/// Writes a ZIP archive. Entries are deflated unless that doesn't help (or `store` is set).
public struct ZipWriter {
    private var data = Data()
    private var central = Data()
    private var count: UInt16 = 0
    public var store = false

    public init(store: Bool = false) { self.store = store }

    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in d { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    public mutating func add(_ name: String, _ text: String) { add(name, Data(text.utf8)) }

    public mutating func add(_ name: String, _ body: Data) {
        let n = Data(name.utf8)
        let crc = Self.crc32(body)
        var method: UInt16 = 0
        var payload = body
        if !store, body.count > 64, let d = try? (body as NSData).compressed(using: .zlib) as Data, d.count < body.count
        {
            method = 8
            payload = d
        }
        let offset = UInt32(data.count)
        // Fixed timestamp (1980-01-01) keeps archives byte-stable.
        var local = Data()
        local += Self.le32(0x0403_4B50) + Self.le16(20) + Self.le16(0) + Self.le16(method) + Self.le16(0)
        local += Self.le16(0x21) + Self.le32(crc) + Self.le32(UInt32(payload.count)) + Self.le32(UInt32(body.count))
        local += Self.le16(UInt16(n.count)) + Self.le16(0) + n
        data += local + payload
        var c = Data()
        c += Self.le32(0x0201_4B50) + Self.le16(20) + Self.le16(20) + Self.le16(0) + Self.le16(method) + Self.le16(0)
        c += Self.le16(0x21) + Self.le32(crc) + Self.le32(UInt32(payload.count)) + Self.le32(UInt32(body.count))
        c += Self.le16(UInt16(n.count)) + Self.le16(0) + Self.le16(0) + Self.le16(0) + Self.le16(0) + Self.le32(0)
        c += Self.le32(offset) + n
        central += c
        count += 1
    }

    public mutating func finish() -> Data {
        let start = UInt32(data.count)
        var out = data + central
        out += Self.le32(0x0605_4B50) + Self.le16(0) + Self.le16(0) + Self.le16(count) + Self.le16(count)
        out += Self.le32(UInt32(central.count)) + Self.le32(start) + Self.le16(0)
        return out
    }
}
