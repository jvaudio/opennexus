import Foundation

/// The contents of a `.nexus` package: a manifest, one or more canvases (shown as
/// tabs), a document theme, and binary assets.
public struct DocumentModel: Equatable, Sendable {
    public static let formatName = "opennexus"
    public static let schemaVersion = 1

    public var canvases: [CanvasID: Canvas]
    /// Tab order.
    public var canvasOrder: [CanvasID]
    /// Document theme, custom colour themes and quick styles (`theme.json`).
    public var theme: JSONValue
    /// Asset files by name (content-hashed filenames under `assets/`).
    public var assets: [String: Data]
    public var encrypted: Bool
    /// Unknown manifest keys, written back unchanged.
    public var manifestExtra: [String: JSONValue]

    public init(canvases: [Canvas], theme: JSONValue = .object([:]), assets: [String: Data] = [:]) {
        self.canvases = Dictionary(uniqueKeysWithValues: canvases.map { ($0.id, $0) })
        self.canvasOrder = canvases.map(\.id)
        self.theme = theme
        self.assets = assets
        self.encrypted = false
        self.manifestExtra = [:]
    }

    /// A new document with one canvas whose root waits to be named.
    public static func blank(type: DiagramType = .mindmap, title: String = "Map 1") -> DocumentModel {
        DocumentModel(canvases: [Canvas(id: "c1", title: title, type: type)])
    }

    public var orderedCanvases: [Canvas] { canvasOrder.compactMap { canvases[$0] } }

    public mutating func apply(_ patch: Patch) {
        guard var c = canvases[patch.canvasID] else { return }
        patch.apply(to: &c)
        canvases[patch.canvasID] = c
    }

    public func makeCanvasID() -> CanvasID {
        var i = canvases.count + 1
        while canvases[CanvasID("c\(i)")] != nil { i += 1 }
        return CanvasID("c\(i)")
    }

    /// Total topics across canvases (for the title bar's "N topics").
    public var topicCount: Int { canvases.values.reduce(0) { $0 + $1.nodes.count } }
}
