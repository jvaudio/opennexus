import CoreGraphics
import Foundation
import NexusCore
import NexusFormat
import NexusInterchange
import NexusScene
import NexusTheme
import UniformTypeIdentifiers

/// The interactive viewer's data (M43), as `schema/viewer.schema.json` describes it: per
/// canvas, two drawings (as saved and with every branch open), where each topic sits in
/// them, the outline, and each topic's details. The browser never lays a map out; it
/// draws these SVGs and places its text layer and focus from the index (D315, D316).
@MainActor
public enum ViewerBundle {
    public static let format = "opennexus-viewer"
    public static let version = 1

    /// What an interactive export covers (the export sheet's Scope).
    public enum Scope: Equatable, Sendable {
        case document
        case canvas(CanvasID)
        /// The branch from this topic down.
        case branch(CanvasID, NodeID)
        /// One zone and its topics.
        case zone(CanvasID, String)
    }

    public struct Options: Equatable, Sendable {
        public var scope = Scope.document
        public var notes = true
        public var comments = true
        /// Attachments' bytes (images on topics are always drawn).
        public var attachments = false
        /// Both layouts; off, only as saved.
        public var expanded = true
        /// Draw with another theme (nil keeps each canvas's).
        public var theme: String?
        /// Assets' bytes in the bundle (exports); a document's viewer copy only names
        /// them, as the document holds them already.
        public var embedAssets = true
        /// The day task dates are spoken against ("Overdue", "Tomorrow"); tests pin it.
        public var today: TaskDate?
        public init() {}
    }

    /// The bundle for `model` (already masked and stripped as the export sheet makes it).
    public static func build(_ model: DocumentModel, _ o: Options, prefs: Preferences = .isolated()) -> JSONValue {
        MathEngine.waiting { make(model, o, prefs: prefs) }
    }

    private static func make(_ model: DocumentModel, _ o: Options, prefs: Preferences) -> JSONValue {
        var m = model
        for (id, c) in m.canvases {
            for n in c.nodes.keys {
                if !o.notes { m.canvases[id]?.nodes[n]?.note = nil }
                if !o.comments { m.canvases[id]?.nodes[n]?.comments = [] }
            }
        }
        var assets: [String: JSONValue] = [:]
        var canvases: [JSONValue] = []
        for id in canvasIDs(m, o.scope) {
            canvases.append(canvas(m, id, o, prefs: prefs, assets: &assets))
        }
        let first = m.canvasOrder.first.flatMap { m.canvases[$0] }
        var out: [String: JSONValue] = [
            "format": .string(format),
            "version": .number(Double(version)),
            "title": .string(first.map { $0.title.isEmpty ? ($0.nodes[$0.root]?.text ?? "") : $0.title } ?? ""),
            "canvases": .array(canvases),
            "assets": .object(assets),
        ]
        out["strings"] = .object(strings.mapValues { .string($0) })
        out["lang"] = .string(Loc.pseudo ? "en-XA" : "en")
        return .object(out)
    }

    /// The canvases a scope draws, in tab order.
    static func canvasIDs(_ m: DocumentModel, _ scope: Scope) -> [CanvasID] {
        switch scope {
        case .document: m.canvasOrder
        case .canvas(let c), .branch(let c, _), .zone(let c, _): m.canvases[c] == nil ? [] : [c]
        }
    }

    /// The image exporter's options for a scope: same padding and background as a PNG.
    static func imageOptions(_ scope: Scope, theme: String?) -> ImageExporter.Options {
        var io = ImageExporter.Options()
        io.scale = 1
        io.theme = theme
        switch scope {
        case .branch(_, let top):
            io.scope = .branch
            io.selection = [top]
        case .zone(_, let zone):
            io.scope = .zone
            io.zone = zone
        default: break
        }
        return io
    }

    static func canvas(
        _ m: DocumentModel, _ id: CanvasID, _ o: Options, prefs: Preferences, assets: inout [String: JSONValue]
    ) -> JSONValue {
        let io = imageOptions(o.scope, theme: o.theme)
        let saved = ImageExporter.controller(m, canvas: id, io)
        saved.prefs = prefs
        let c = saved.canvas
        let keep = ImageExporter.keep(c, io)
        let parents = c.parentMap()
        var layouts: [String: JSONValue] = ["saved": layout(saved, m, io, prefix: "\(id.rawValue)s-", parents)]
        // Everything: the same canvas with every branch open (only when something is folded).
        var open = saved
        if c.nodes.values.contains(where: \.folded), o.expanded {
            var all = m
            for n in c.nodes.keys { all.canvases[id]?.nodes[n]?.folded = false }
            open = ImageExporter.controller(all, canvas: id, io)
            open.prefs = prefs
            layouts["expanded"] = layout(open, all, io, prefix: "\(id.rawValue)e-", parents)
        }
        // The topics: the scope's (every topic for canvas and document scopes).
        let tops: [NodeID] =
            switch o.scope {
            case .branch(_, let top): [top]
            case .zone(_, let z): c.zones.first { $0.id == z }?.members ?? []
            default: c.tops
            }
        var topics: [String: JSONValue] = [:]
        // Depths as VoiceOver gives them in the app: in the whole canvas, whatever the scope.
        let (depths, maxDepth) = Spoken.depths(c)
        for (nid, depth) in depths where keep?.contains(nid) ?? true {
            topics[nid.rawValue] = topic(
                c, nid, depth: depth, maxDepth: maxDepth, scene: open.scene.nodes[nid] ?? saved.scene.nodes[nid],
                m, o, prefs: prefs, assets: &assets)
        }
        func outline(_ nid: NodeID) -> JSONValue {
            guard let n = c.nodes[nid] else { return .null }
            var item: [String: JSONValue] = ["id": .string(nid.rawValue)]
            if !n.children.isEmpty { item["children"] = .array(n.children.map(outline)) }
            if n.folded { item["folded"] = .bool(true) }
            return .object(item)
        }
        let theme = saved.scene.theme
        var out: [String: JSONValue] = [
            "id": .string(id.rawValue),
            "title": .string(c.title.isEmpty ? (c.nodes[c.root]?.text ?? "") : c.title),
            "type": .string(c.type.rawValue),
            "typeName": .string(Loc.t(c.type.displayName)),
            "theme": .object([
                "canvas": .string(SVGExporter.hex(saved.scene.canvasColor)), "ink": .string(SVGExporter.hex(theme.ink)),
                "ink2": .string(SVGExporter.hex(theme.ink2)), "accent": .string(SVGExporter.hex(theme.ring)),
                "dark": .bool(theme.isDark),
            ]),
            "layouts": .object(layouts),
            "outline": .array(tops.filter { c.nodes[$0] != nil }.map(outline)),
            "topics": .object(topics),
        ]
        if let l = saved.scene.legend {
            out["legend"] = .object([
                "title": .string(Loc.t("Legend")),
                "rows": .array(
                    l.rows.map { r in
                        var row: [String: JSONValue] = ["text": .string(r.label ?? r.text)]
                        if let mk = r.marker { row["marker"] = .string(mk) }
                        return .object(row)
                    }),
            ])
        }
        let threats = Stride.threats(c).filter { keep?.contains($0.node) ?? true }
        if c.type == .threatModel || !threats.isEmpty {
            out["threats"] = .object([
                "columns": .array(Stride.tableHeader.map { .string(Loc.t($0)) }),
                "rows": .array(threats.map { .array(Stride.row($0).map(JSONValue.string)) }),
            ])
        }
        // The deck, for the web viewer's Present (M47d). A branch or a zone has none.
        switch o.scope {
        case .document, .canvas: out["deck"] = deck(c)
        case .branch, .zone: break
        }
        return .object(out)
    }

    /// The slides that play, as Present plays them: after the author's order, merges and
    /// skips, with the deck's camera and aspect. Notes come with the canvas (gone when the
    /// export leaves notes out). A slide that frames every topic says so with no focus.
    static func deck(_ c: Canvas) -> JSONValue {
        let s = c.presentation
        let hidden = Set(c.nodes.filter { $0.value.presentHidden }.keys)
        let all = Set(c.tops.flatMap { c.subtree($0, includeFolded: false) }.filter { !hidden.contains($0) })
        let ids: ([NodeID]) -> JSONValue = { .array($0.map { .string($0.rawValue) }) }
        let slides = Deck.slides(c).filter { !$0.skipped }.map { slide -> JSONValue in
            var out: [String: JSONValue] = [
                "kicker": .string(slide.kicker), "title": .string(slide.title),
                "focus": Set(slide.focus) == all ? .array([]) : ids(slide.focus),
                "highlight": ids(slide.highlight),
            ]
            if let note = slide.note, !note.isEmpty { out["note"] = .string(note) }
            return .object(out)
        }
        return .object([
            "move": .string(s.cameraMove), "aspect": .number((s.aspectRatio * 10000).rounded() / 10000),
            "slides": .array(slides),
        ])
    }

    /// One drawing and where each topic sits in it.
    static func layout(
        _ controller: CanvasController, _ m: DocumentModel, _ io: ImageExporter.Options, prefix: String,
        _ parents: [NodeID: NodeID]
    ) -> JSONValue {
        var svg = SVGExporter.Options()
        svg.outlineText = true
        svg.fields = false
        svg.idPrefix = prefix
        svg.reuseGlyphs = true
        svg.embedImages = false
        let scene = controller.scene
        let c = controller.canvas
        let depths = Spoken.depths(c).depths
        var topics: [String: JSONValue] = [:]
        for (id, sn) in scene.nodes where CanvasController.ghostIndex(id) == nil {
            let r = sn.frame.rect
            var p: [String: JSONValue] = [
                "frame": rect(r), "depth": .number(Double(depths[id] ?? 0)),
                "text": rect(sn.textRect.offsetBy(dx: r.minX, dy: r.minY)),
            ]
            if let parent = parents[id] { p["parent"] = .string(parent.rawValue) }
            if sn.hiddenCount > 0 {
                p["hidden"] = .number(Double(sn.hiddenCount))
                let label = StyledText("+\(sn.hiddenCount)", font: Fonts.system(11, .bold))
                let w = max(22, ceil(label.lineSize.width) + 10)
                p["badge"] = rect(SVGExporter.badgeRect(sn, width: w).offsetBy(dx: r.minX, dy: r.minY))
            }
            topics[id.rawValue] = .object(p)
        }
        var out: [String: JSONValue] = [
            "svg": .string(SVGExporter.export(controller, assets: m.assets, io, svg)),
            "viewBox": rect(SVGExporter.viewBox(scene, io)),
            "topics": .object(topics),
        ]
        if !scene.zones.isEmpty {
            out["zones"] = .array(
                scene.zones.map {
                    .object(["id": .string($0.zone.id), "title": .string($0.zone.title), "frame": rect($0.rect)])
                })
        }
        return .object(out)
    }

    static func topic(
        _ c: Canvas, _ id: NodeID, depth: Int, maxDepth: Int, scene sn: SceneNode?, _ m: DocumentModel, _ o: Options,
        prefs: Preferences, assets: inout [String: JSONValue]
    ) -> JSONValue {
        guard let n = c.nodes[id] else { return .null }
        var t: [String: JSONValue] = [
            "text": .string(n.text),
            "label": .string(
                Spoken.describe(
                    id, in: c, prefs: prefs, branchColor: sn.map { Spoken.colorName($0.branchColor) }, depth: depth,
                    maxDepth: maxDepth, today: o.today ?? .today(), hints: false)),
        ]
        if let type = n.nodeType, DiagramCatalog.isTechnical(c.type) {
            t["type"] = .string(Loc.t(DiagramCatalog.info(type, in: c.type)?.name ?? type.rawValue))
        }
        if let note = n.note?.text, !note.isEmpty { t["note"] = .string(note) }
        if !n.comments.isEmpty {
            t["comments"] = .array(
                n.comments.map {
                    .object(["author": .string($0.author), "date": .string($0.date), "text": .string($0.text)])
                })
        }
        if let l = n.link, !l.isEmpty { t["link"] = link(l) }
        if !n.attachments.isEmpty {
            t["attachments"] = .array(
                n.attachments.map { a in
                    var item: [String: JSONValue] = ["name": .string(a.name ?? a.asset)]
                    if let data = m.assets[a.asset] {
                        item["size"] = .number(Double(data.count))
                        if o.attachments {
                            item["asset"] = .string(a.asset)
                            assets[a.asset] = asset(data, name: a.name ?? a.asset, embed: o.embedAssets)
                        }
                    }
                    return .object(item)
                })
        }
        if let todo = n.todo {
            let line =
                [todo.done ? Loc.t("Done") : Loc.t("To do")]
                + [TaskFormat.spoken(c, id, today: o.today ?? .today())].compactMap { $0 }
            t["task"] = .string(line.joined(separator: ", "))
        }
        if !n.labels.isEmpty { t["labels"] = .array(n.labels.map(JSONValue.string)) }
        if !n.markers.isEmpty { t["markers"] = .array(n.markers.map { .string(markerName($0)) }) }
        if !n.metadata.isEmpty {
            t["fields"] = .array(n.metadata.map { .object(["key": .string($0.key), "value": .string($0.value)]) })
        }
        // Images the drawing names (data-nexus-asset).
        for ref in [n.image?.asset, n.sticker?.asset].compactMap({ $0 }) {
            guard assets[ref] == nil, let data = m.assets[ref] else { continue }
            assets[ref] = asset(data, name: ref, embed: o.embedAssets, image: true)
        }
        return .object(t)
    }

    static func link(_ l: String) -> JSONValue {
        if let target = TopicLink.parse(l) {
            return .object([
                "href": .string(l), "kind": .string("topic"), "canvas": .string(target.canvas.rawValue),
                "topic": .string(target.node.rawValue),
            ])
        }
        let lower = l.lowercased()
        let kind =
            lower.hasPrefix("http://") || lower.hasPrefix("https://")
            ? "web" : lower.hasPrefix("mailto:") ? "mail" : lower.hasPrefix("file:") ? "file" : "other"
        return .object(["href": .string(l), "kind": .string(kind)])
    }

    static func asset(_ data: Data, name: String, embed: Bool, image: Bool = false) -> JSONValue {
        var bytes = data
        var type = UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType
        if image, let b = SVGExporter.browserImage(data) {
            bytes = b.data
            type = b.type
        }
        var out: [String: JSONValue] = [
            "type": .string(type ?? "application/octet-stream"), "size": .number(Double(bytes.count)),
        ]
        if embed { out["data"] = .string(bytes.base64EncodedString()) }
        return .object(out)
    }

    /// "priority-1" → "Priority 1".
    static func markerName(_ id: String) -> String {
        let words = id.split(separator: "-").joined(separator: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func rect(_ r: CGRect) -> JSONValue {
        .array([r.minX, r.minY, r.width, r.height].map { .number((Double($0) * 100).rounded() / 100) })
    }

    /// The viewer's own words, in the app's language.
    static var strings: [String: String] {
        [
            "outline": Loc.t("Outline"),
            "details": Loc.t("Details"),
            "search": Loc.t("Search"),
            "searchPlaceholder": Loc.t("Search topics"),
            "matchCase": Loc.t("Match case"),
            "wholeWords": Loc.t("Whole words"),
            "noMatches": Loc.t("No matches"),
            "matches": Loc.t("%d of %d"),
            "asSaved": Loc.t("As saved"),
            "everything": Loc.t("Everything"),
            "layout": Loc.t("Layout"),
            "fit": Loc.t("Fit"),
            "zoomIn": Loc.t("Zoom In"),
            "zoomOut": Loc.t("Zoom Out"),
            "canvases": Loc.t("Canvases"),
            "map": Loc.t("Map"),
            "close": Loc.t("Close"),
            "note": Loc.t("Note"),
            "comments": Loc.t("Comments"),
            "link": Loc.t("Link"),
            "attachments": Loc.t("Attachments"),
            "notIncluded": Loc.t("Not included in this export"),
            "task": Loc.t("Task"),
            "labels": Loc.t("Labels"),
            "markers": Loc.t("Markers"),
            "type": Loc.t("Type"),
            "fields": Loc.t("Fields"),
            "threats": Loc.t("Threats"),
            "legend": Loc.t("Legend"),
            "print": Loc.t("Print"),
            "keys": Loc.t("Arrow keys move between topics · Return opens details · / searches · Esc closes"),
            "noScript": Loc.t("This map needs JavaScript to show."),
            "notes": Loc.t("Notes"),
            "allCanvases": Loc.t("All canvases"),
            "showHidden": Loc.t("Show %d hidden topics"),
            "previous": Loc.t("Previous match"),
            "next": Loc.t("Next match"),
            "topic": Loc.t("Topic"),
            "present": Loc.t("Present"),
            "previousSlide": Loc.t("Previous Slide"),
            "nextSlide": Loc.t("Next Slide"),
            "endPresentation": Loc.t("End Presentation"),
            "slideCount": Loc.t("%d of %d"),
        ]
    }
}
