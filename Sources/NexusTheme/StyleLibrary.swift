import Foundation
import NexusCore

/// Custom themes, colour themes ("My colours") and quick styles saved with a document
/// in `theme.json`. Unknown keys round-trip.
public struct StyleLibrary: Equatable, Sendable {
    public var themes: [Theme] = []
    public var palettes: [ColorPalette] = []
    public var quickStyles: [QuickStyle] = []
    public var extra: [String: JSONValue] = [:]

    public init() {}

    public init(json: JSONValue) {
        guard case .object(var o) = json else { return }
        themes = Self.decode([Theme].self, o.removeValue(forKey: "themes")) ?? []
        palettes = Self.decode([ColorPalette].self, o.removeValue(forKey: "palettes")) ?? []
        if case .array(let qs)? = o.removeValue(forKey: "quickStyles") {
            quickStyles = qs.compactMap { q in
                guard let id = q["id"]?.stringValue, let s = q["style"],
                    let style = try? TopicStyle(json: s, path: "quickStyles")
                else { return nil }
                return QuickStyle(
                    id: id, name: q["name"]?.stringValue ?? id, glyph: q["glyph"]?.stringValue ?? "",
                    style: style)
            }
        }
        extra = o
    }

    public var json: JSONValue {
        var o = extra
        if !themes.isEmpty { o["themes"] = Self.encode(themes) }
        if !palettes.isEmpty { o["palettes"] = Self.encode(palettes) }
        if !quickStyles.isEmpty {
            o["quickStyles"] = .array(
                quickStyles.map {
                    [
                        "id": .string($0.id), "name": .string($0.name), "glyph": .string($0.glyph),
                        "style": $0.style.json,
                    ]
                })
        }
        return .object(o)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue?) -> T? {
        guard let value, let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func encode<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value),
            let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .null }
        return json
    }
}
