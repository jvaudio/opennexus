import Foundation

/// A JSON tree. The file format layer parses into this and writes from it, and
/// every model type keeps the keys it does not understand as `JSONValue`s so they
/// round-trip unchanged.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByFloatLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

/// Errors raised when a JSON tree does not have the shape a model type expects.
public struct ModelDecodingError: Error, CustomStringConvertible, Sendable {
    public var path: String
    public var message: String

    public init(path: String, _ message: String) {
        self.path = path
        self.message = message
    }

    public var description: String { "\(path): \(message)" }
}

/// Reads typed fields out of a JSON object and remembers which keys it consumed,
/// so the rest can be kept as unknown keys for forward compatibility.
public struct ObjectReader {
    public let path: String
    private let object: [String: JSONValue]
    private var consumed = Set<String>()

    public init(_ value: JSONValue, path: String) throws {
        guard let o = value.objectValue else { throw ModelDecodingError(path: path, "expected an object") }
        self.object = o
        self.path = path
    }

    public mutating func raw(_ key: String) -> JSONValue? {
        consumed.insert(key)
        return object[key]
    }

    public mutating func string(_ key: String) throws -> String {
        guard let s = raw(key)?.stringValue else {
            throw ModelDecodingError(path: "\(path).\(key)", "expected a string")
        }
        return s
    }

    public mutating func optionalString(_ key: String) throws -> String? {
        switch raw(key) {
        case nil, .null?: return nil
        case .string(let s)?: return s
        default: throw ModelDecodingError(path: "\(path).\(key)", "expected a string")
        }
    }

    public mutating func bool(_ key: String, default value: Bool) throws -> Bool {
        switch raw(key) {
        case nil, .null?: return value
        case .bool(let b)?: return b
        default: throw ModelDecodingError(path: "\(path).\(key)", "expected a boolean")
        }
    }

    public mutating func optionalBool(_ key: String) throws -> Bool? {
        switch raw(key) {
        case nil, .null?: return nil
        case .bool(let b)?: return b
        default: throw ModelDecodingError(path: "\(path).\(key)", "expected a boolean")
        }
    }

    public mutating func optionalDouble(_ key: String) throws -> Double? {
        switch raw(key) {
        case nil, .null?: return nil
        case .number(let n)?: return n
        default: throw ModelDecodingError(path: "\(path).\(key)", "expected a number")
        }
    }

    /// A whole number within `range`; anything else (fractions, 1e308, out of range) is
    /// a decoding error rather than a trap when converted (M10 fuzzing).
    public mutating func optionalInt(_ key: String, in range: ClosedRange<Int> = -1_000_000_000...1_000_000_000) throws
        -> Int?
    {
        guard let d = try optionalDouble(key) else { return nil }
        guard d.isFinite, d == d.rounded(), d >= Double(range.lowerBound), d <= Double(range.upperBound) else {
            throw ModelDecodingError(path: "\(path).\(key)", "expected a whole number in \(range)")
        }
        return Int(d)
    }

    public mutating func strings(_ key: String) throws -> [String] {
        switch raw(key) {
        case nil, .null?: return []
        case .array(let a)?:
            return try a.enumerated().map { i, v in
                guard let s = v.stringValue else {
                    throw ModelDecodingError(path: "\(path).\(key)[\(i)]", "expected a string")
                }
                return s
            }
        default: throw ModelDecodingError(path: "\(path).\(key)", "expected an array")
        }
    }

    public mutating func array(_ key: String) throws -> [JSONValue] {
        switch raw(key) {
        case nil, .null?: return []
        case .array(let a)?: return a
        default: throw ModelDecodingError(path: "\(path).\(key)", "expected an array")
        }
    }

    public mutating func object(_ key: String) throws -> [String: JSONValue]? {
        switch raw(key) {
        case nil, .null?: return nil
        case .object(let o)?: return o
        default: throw ModelDecodingError(path: "\(path).\(key)", "expected an object")
        }
    }

    /// Every key that has not been read, to be written back unchanged.
    public var leftovers: [String: JSONValue] {
        object.filter { !consumed.contains($0.key) }
    }
}

/// Builds a JSON object, omitting defaults so files stay small and diffs stay quiet.
public struct ObjectWriter {
    public private(set) var object: [String: JSONValue]

    public init(extra: [String: JSONValue] = [:]) { object = extra }

    public mutating func set(_ key: String, _ value: JSONValue) { object[key] = value }
    public mutating func set(_ key: String, _ value: String) { object[key] = .string(value) }

    public mutating func set(_ key: String, _ value: String?) {
        if let value { object[key] = .string(value) }
    }

    public mutating func set(_ key: String, _ value: Double?) {
        if let value { object[key] = .number(value) }
    }

    public mutating func set(_ key: String, _ value: Bool?) {
        if let value { object[key] = .bool(value) }
    }

    public mutating func set(_ key: String, _ value: Bool, omitting defaultValue: Bool) {
        if value != defaultValue { object[key] = .bool(value) }
    }

    public mutating func set(_ key: String, _ values: [String], omitEmpty: Bool) {
        if !(omitEmpty && values.isEmpty) { object[key] = .array(values.map(JSONValue.string)) }
    }

    public var value: JSONValue { .object(object) }
}

/// Model types that map to and from a JSON tree.
public protocol JSONRepresentable {
    init(json: JSONValue, path: String) throws
    var json: JSONValue { get }
}
