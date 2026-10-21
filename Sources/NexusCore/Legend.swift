import Foundation

/// A canvas's legend (M14), like Xmind's: a box on the canvas listing the markers and
/// labels the canvas uses, with an optional description per marker. Written only when
/// the canvas has one, so other files stay byte-identical (D164).
public struct Legend: Hashable, Sendable, JSONRepresentable {
    /// Shown on the canvas and in image exports. A hidden legend keeps its descriptions.
    public var visible: Bool
    /// Top-left corner in canvas coordinates; nil places it beside the map.
    public var position: CanvasPoint?
    /// Marker id → description, shown instead of the marker's own name.
    public var markers: [String: String] = [:]
    public var extra: [String: JSONValue] = [:]

    public init(visible: Bool = true, position: CanvasPoint? = nil, markers: [String: String] = [:]) {
        self.visible = visible
        self.position = position
        self.markers = markers
    }

    public init(json: JSONValue, path: String) throws {
        var r = try ObjectReader(json, path: path)
        visible = try r.bool("visible", default: true)
        if let p = r.raw("position"), p != .null { position = try CanvasPoint(json: p, path: "\(path).position") }
        for (k, v) in try r.object("markers") ?? [:] {
            guard case .string(let s) = v else {
                throw ModelDecodingError(path: "\(path).markers.\(k)", "expected a string")
            }
            markers[k] = s
        }
        extra = r.leftovers
    }

    public var json: JSONValue {
        var w = ObjectWriter(extra: extra)
        w.set("visible", .bool(visible))
        if let position { w.set("position", position.json) }
        if !markers.isEmpty { w.set("markers", .object(markers.mapValues { .string($0) })) }
        return w.value
    }
}

extension Canvas {
    /// What a legend lists: the markers and labels in use, each once, in outline order
    /// of first use (the main tree, then floating topics, summaries and callouts).
    public var legendContents: (markers: [String], labels: [String]) {
        var markers: [String] = []
        var labels: [String] = []
        var seenM = Set<String>()
        var seenL = Set<String>()
        var ids = tops.flatMap { subtree($0) }
        let listed = Set(ids)
        ids += nodes.keys.filter { !listed.contains($0) }.sorted { $0.rawValue < $1.rawValue }
        for id in ids {
            guard let n = nodes[id] else { continue }
            for m in n.markers where seenM.insert(m).inserted { markers.append(m) }
            for l in n.labels where seenL.insert(l).inserted { labels.append(l) }
        }
        return (markers, labels)
    }
}
