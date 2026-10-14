import Foundation
import NexusCore

/// A small JSON Schema (draft 2020-12) validator covering the keywords the
/// published `nexus.schema.json` uses: `type`, `properties`, `required`,
/// `additionalProperties`, `patternProperties`, `items`, `enum`, `const`,
/// `minimum`, `maximum`, `minLength`, `minItems`, `pattern`, `uniqueItems`,
/// `$ref` (local), `anyOf`, `oneOf` and `allOf`.
public struct SchemaValidator: Sendable {
    public struct Issue: Equatable, Sendable, CustomStringConvertible {
        public var path: String
        public var message: String
        public var description: String { "\(path.isEmpty ? "$" : path): \(message)" }
    }

    public let schema: JSONValue

    public init(schema: JSONValue) { self.schema = schema }

    /// Location of the bundled `nexus.schema.json`.
    public static var bundledSchemaURL: URL? {
        Bundle.module.url(forResource: "nexus.schema", withExtension: "json")
    }

    /// The schema bundled with OpenNexus.
    public static let bundled: SchemaValidator = {
        guard let url = bundledSchemaURL,
            let data = try? Data(contentsOf: url),
            let json = try? CanonicalJSON.parse(data)
        else { fatalError("nexus.schema.json is missing from the NexusFormat bundle") }
        return SchemaValidator(schema: json)
    }()

    /// Validates against a named definition (`manifest`, `canvas`, …) or the root schema.
    public func validate(_ value: JSONValue, definition: String? = nil) -> [Issue] {
        var issues: [Issue] = []
        let s: JSONValue = definition.flatMap { schema["$defs"]?[$0] } ?? schema
        check(value, s, path: "", &issues)
        return issues
    }

    /// Validates every JSON file in a package.
    public func validate(package files: [String: Data]) -> [Issue] {
        var issues: [Issue] = []
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            let def: String
            if path == "manifest.json" {
                def = "manifest"
            } else if path.hasPrefix("canvases/") && path.hasSuffix(".json") {
                def = "canvas"
            } else if path == "theme.json" {
                def = "theme"
            } else if path == "ai/chats.json" {
                def = "chats"
            } else {
                continue
            }
            guard let json = try? CanonicalJSON.parse(data) else {
                issues.append(Issue(path: path, message: "not valid JSON"))
                continue
            }
            issues += validate(json, definition: def).map { Issue(path: "\(path)\($0.path)", message: $0.message) }
        }
        return issues
    }

    private func resolve(_ ref: String) -> JSONValue? {
        guard ref.hasPrefix("#/") else { return nil }
        var cur: JSONValue? = schema
        for part in ref.dropFirst(2).split(separator: "/") {
            cur = cur?[String(part)]
        }
        return cur
    }

    private func typeName(_ v: JSONValue) -> String {
        switch v {
        case .null: "null"
        case .bool: "boolean"
        case .number(let n): n == n.rounded() ? "integer" : "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    private func matches(_ v: JSONValue, type t: String) -> Bool {
        let actual = typeName(v)
        return actual == t || (t == "number" && actual == "integer")
    }

    private func check(_ v: JSONValue, _ s: JSONValue, path: String, _ issues: inout [Issue]) {
        if case .bool(let b) = s {
            if !b { issues.append(Issue(path: path, message: "not allowed")) }
            return
        }
        guard let s = s.objectValue else { return }

        if let ref = s["$ref"]?.stringValue {
            if let target = resolve(ref) {
                check(v, target, path: path, &issues)
            } else {
                issues.append(Issue(path: path, message: "unresolvable $ref \(ref)"))
            }
        }

        if let t = s["type"] {
            let types = t.arrayValue?.compactMap(\.stringValue) ?? [t.stringValue].compactMap { $0 }
            if !types.contains(where: { matches(v, type: $0) }) {
                issues.append(
                    Issue(path: path, message: "expected \(types.joined(separator: " or ")), got \(typeName(v))"))
                return
            }
        }
        if let e = s["enum"]?.arrayValue, !e.contains(v) {
            issues.append(Issue(path: path, message: "value is not one of the allowed values"))
        }
        if let c = s["const"], c != v {
            issues.append(
                Issue(path: path, message: "value must be \(CanonicalJSON.string(c).trimmingCharacters(in: .newlines))")
            )
        }
        if let all = s["allOf"]?.arrayValue {
            for sub in all { check(v, sub, path: path, &issues) }
        }
        if let any = s["anyOf"]?.arrayValue {
            let ok = any.contains { sub in
                var tmp: [Issue] = []
                check(v, sub, path: path, &tmp)
                return tmp.isEmpty
            }
            if !ok { issues.append(Issue(path: path, message: "does not match any allowed shape")) }
        }
        if let one = s["oneOf"]?.arrayValue {
            let n = one.filter { sub in
                var tmp: [Issue] = []
                check(v, sub, path: path, &tmp)
                return tmp.isEmpty
            }.count
            if n != 1 { issues.append(Issue(path: path, message: "must match exactly one shape (matched \(n))")) }
        }

        switch v {
        case .number(let n):
            if let min = s["minimum"]?.doubleValue, n < min {
                issues.append(Issue(path: path, message: "must be ≥ \(CanonicalJSON.number(min))"))
            }
            if let max = s["maximum"]?.doubleValue, n > max {
                issues.append(Issue(path: path, message: "must be ≤ \(CanonicalJSON.number(max))"))
            }
        case .string(let str):
            if let min = s["minLength"]?.doubleValue, Double(str.count) < min {
                issues.append(Issue(path: path, message: "must have at least \(Int(min)) characters"))
            }
            if let p = s["pattern"]?.stringValue, str.range(of: p, options: .regularExpression) == nil {
                issues.append(Issue(path: path, message: "must match \(p)"))
            }
        case .array(let a):
            if let min = s["minItems"]?.doubleValue, Double(a.count) < min {
                issues.append(Issue(path: path, message: "must have at least \(Int(min)) items"))
            }
            if s["uniqueItems"]?.boolValue == true, Set(a).count != a.count {
                issues.append(Issue(path: path, message: "items must be unique"))
            }
            if let items = s["items"] {
                for (i, item) in a.enumerated() { check(item, items, path: "\(path)[\(i)]", &issues) }
            }
        case .object(let o):
            for req in s["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where o[req] == nil {
                issues.append(Issue(path: path, message: "missing required key “\(req)”"))
            }
            let props = s["properties"]?.objectValue ?? [:]
            let patterns = s["patternProperties"]?.objectValue ?? [:]
            for (k, val) in o.sorted(by: { $0.key < $1.key }) {
                var covered = false
                if let ps = props[k] {
                    covered = true
                    check(val, ps, path: "\(path).\(k)", &issues)
                }
                for (p, ps) in patterns where k.range(of: p, options: .regularExpression) != nil {
                    covered = true
                    check(val, ps, path: "\(path).\(k)", &issues)
                }
                if !covered, let ap = s["additionalProperties"] {
                    check(val, ap, path: "\(path).\(k)", &issues)
                }
            }
        default:
            break
        }
    }
}
