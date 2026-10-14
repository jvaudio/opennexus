import CryptoKit
import Foundation
import NexusCore
import NexusFormat

// MARK: Intermediate model

/// A topic as an importer sees it, before ids exist. `ref` is the source format's id, used to
/// resolve relationships, boundaries, summaries and links.
public struct ITopic: Sendable, Equatable {
    public var text: String
    public var ref: String?
    public var note: String?
    public var markers: [String] = []
    public var labels: [String] = []
    public var link: String?
    public var image: AssetRef?
    public var attachments: [AssetRef] = []
    public var todo: Bool?
    public var nodeType: NodeType?
    public var edgeLabel: String?
    public var structure: LayoutStructure?
    public var folded = false
    public var position: CanvasPoint?
    public var children: [ITopic] = []

    public init(_ text: String, ref: String? = nil, children: [ITopic] = []) {
        self.text = text
        self.ref = ref
        self.children = children
    }

    public var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
}

/// A canvas as an importer sees it.
public struct ICanvas: Sendable, Equatable {
    public struct Link: Sendable, Equatable {
        public var from: String
        public var to: String
        public var label: String
        public var kind: String?
        public init(from: String, to: String, label: String = "", kind: String? = nil) {
            self.from = from
            self.to = to
            self.label = label
            self.kind = kind
        }
    }
    public struct Group: Sendable, Equatable {
        public var refs: [String]
        public var title: String
        public init(refs: [String], title: String = "") {
            self.refs = refs
            self.title = title
        }
    }
    public struct Brace: Sendable, Equatable {
        public var parent: String
        public var from: String
        public var to: String
        public var topic: ITopic
        public init(parent: String, from: String, to: String, topic: ITopic) {
            self.parent = parent
            self.from = from
            self.to = to
            self.topic = topic
        }
    }
    public struct Bubble: Sendable, Equatable {
        public var host: String
        public var topic: ITopic
        public init(host: String, topic: ITopic) {
            self.host = host
            self.topic = topic
        }
    }

    public var title: String
    public var type: DiagramType = .mindmap
    public var structure: LayoutStructure?
    public var root: ITopic
    public var floating: [ITopic] = []
    public var links: [Link] = []
    public var groups: [Group] = []
    public var summaries: [Brace] = []
    public var callouts: [Bubble] = []
    /// The root was made up to hold several top-level topics (pasting drops it).
    public var synthesizedRoot = false

    public init(title: String, root: ITopic) {
        self.title = title
        self.root = root
    }

    public var topicCount: Int {
        root.count + floating.reduce(0) { $0 + $1.count } + summaries.reduce(0) { $0 + $1.topic.count }
            + callouts.reduce(0) { $0 + $1.topic.count }
    }
}

// MARK: Report

/// What an import produced and what it couldn't convert (artboard 33, "Import report").
public struct ImportReport: Sendable, Equatable {
    public var source: String
    public var format: String
    /// Sheets, pages or diagrams in the source.
    public var sheets = 0
    public var canvases = 0
    public var topics = 0
    public var markers = 0
    public var notes = 0
    /// Things not converted, in first-seen order, with how often each occurred.
    public private(set) var skipped: [(String, Int)] = []

    public init(source: String, format: String) {
        self.source = source
        self.format = format
    }

    public mutating func skip(_ what: String, _ n: Int = 1) {
        if let i = skipped.firstIndex(where: { $0.0 == what }) {
            skipped[i].1 += n
        } else {
            skipped.append((what, n))
        }
    }

    public var notConverted: Int { skipped.reduce(0) { $0 + $1.1 } }

    /// "· Audio note on “Kickoff” (kept as attachment)", one line per kind.
    public var lines: [String] { skipped.map { $0.1 > 1 ? "\($0.0) ×\($0.1)" : $0.0 } }

    public static func == (a: ImportReport, b: ImportReport) -> Bool {
        a.source == b.source && a.format == b.format && a.sheets == b.sheets && a.canvases == b.canvases
            && a.topics == b.topics && a.markers == b.markers && a.notes == b.notes
            && a.skipped.map(\.0) == b.skipped.map(\.0) && a.skipped.map(\.1) == b.skipped.map(\.1)
    }

    /// Plain-text form (golden files, the CLI).
    public var text: String {
        var s = "\(source) · \(format)\n"
        s += "\(sheets) sheets → \(canvases) canvases · \(topics) topics, \(markers) markers, \(notes) notes\n"
        s += "\(notConverted) not converted\n"
        for l in lines { s += "· \(l)\n" }
        return s
    }
}

/// An import's result: canvases (ids `c1`, `c2`, … unless the caller re-ids them),
/// their assets, and the report.
public struct Imported: Sendable {
    public var canvases: [Canvas]
    public var assets: [String: Data]
    public var report: ImportReport

    public init(canvases: [Canvas], assets: [String: Data] = [:], report: ImportReport) {
        self.canvases = canvases
        self.assets = assets
        self.report = report
    }

    public var document: DocumentModel { DocumentModel(canvases: canvases, assets: assets) }
}

public enum ImportError: Error, Equatable, CustomStringConvertible {
    case unrecognised(String)
    case empty(String)
    case invalid(String, String)
    case encrypted(String)

    public var description: String {
        switch self {
        case .unrecognised(let n): "\(n): not a format OpenNexus can import"
        case .empty(let n): "\(n) is empty (if it lives in cloud storage, download it first)"
        case .invalid(let n, let why): "\(n): \(why)"
        case .encrypted(let n): "\(n) is password-protected; remove the password in its app first"
        }
    }
}

// MARK: Building canvases

public enum CanvasBuilder {
    /// Content-hashed asset names, as the app stores them.
    public static func assetName(_ data: Data, ext: String) -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(20)
        return "\(digest).\(ext.lowercased())"
    }

    /// Builds a canvas, resolving refs. Unresolved references are reported.
    public static func build(_ ic: ICanvas, id: CanvasID, report: inout ImportReport) -> Canvas {
        var c = Canvas(id: id, title: ic.title, type: ic.type, rootText: ic.root.text)
        if let s = ic.structure { c.layout.structure = s }
        var refs: [String: NodeID] = [:]
        func apply(_ t: ITopic, to id: NodeID) {
            var n = c.nodes[id] ?? Node(text: t.text)
            n.text = t.text
            if let note = t.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                n.note = Note(text: note)
                report.notes += 1
            }
            n.markers = t.markers
            report.markers += t.markers.count
            n.labels = t.labels
            n.link = t.link
            n.image = t.image
            n.attachments = t.attachments
            n.todo = t.todo.map { Todo(done: $0) }
            n.nodeType = t.nodeType
            n.edgeLabel = t.edgeLabel
            n.structure = t.structure
            n.folded = t.folded && !t.children.isEmpty
            c.nodes[id] = n
            if let r = t.ref { refs[r] = id }
            report.topics += 1
        }
        func add(_ t: ITopic, under parent: NodeID) -> NodeID {
            let id = c.makeNodeID()
            c.nodes[id] = Node(text: t.text, kind: .topic)
            c.nodes[parent]!.children.append(id)
            apply(t, to: id)
            for ch in t.children { _ = add(ch, under: id) }
            return id
        }
        apply(ic.root, to: c.root)
        c.nodes[c.root]!.kind = .root
        for ch in ic.root.children { _ = add(ch, under: c.root) }
        for f in ic.floating {
            let id = c.makeNodeID()
            var n = Node(text: f.text, kind: .floating)
            n.position = f.position ?? CanvasPoint(x: 0, y: 260 + Double(c.floating.count) * 80)
            c.nodes[id] = n
            c.floating.append(id)
            apply(f, to: id)
            c.nodes[id]!.kind = .floating
            c.nodes[id]!.position = n.position
            for ch in f.children { _ = add(ch, under: id) }
        }
        for s in ic.summaries {
            guard let parent = refs[s.parent], let from = refs[s.from], let to = refs[s.to] else {
                report.skip("Summary with a missing range")
                continue
            }
            let tid = c.makeNodeID()
            c.nodes[tid] = Node(text: s.topic.text, kind: .summary)
            apply(s.topic, to: tid)
            c.nodes[tid]!.kind = .summary
            for ch in s.topic.children { _ = add(ch, under: tid) }
            c.summaries.append(Summary(id: "s\(c.summaries.count + 1)", parent: parent, from: from, to: to, topic: tid))
        }
        for b in ic.callouts {
            guard let host = refs[b.host] else { continue }
            let tid = c.makeNodeID()
            c.nodes[tid] = Node(text: b.topic.text, kind: .callout)
            apply(b.topic, to: tid)
            c.nodes[tid]!.kind = .callout
            c.callouts.append(Callout(id: "k\(c.callouts.count + 1)", host: host, topic: tid))
        }
        for g in ic.groups {
            let ids = g.refs.compactMap { refs[$0] }
            guard !ids.isEmpty else { continue }
            c.boundaries.append(Boundary(id: "b\(c.boundaries.count + 1)", nodes: ids, title: g.title))
        }
        for l in ic.links {
            guard let from = refs[l.from], let to = refs[l.to] else {
                report.skip("Relationship to a missing topic")
                continue
            }
            var r = Relationship(id: "r\(c.relationships.count + 1)", from: from, to: to, label: l.label)
            r.kind = l.kind
            c.relationships.append(r)
        }
        // Internal links ("xmind:#id", "#id") point at topics in this canvas.
        for (id, n) in c.nodes {
            guard let link = n.link else { continue }
            let target =
                link.hasPrefix("xmind:#")
                ? String(link.dropFirst(7)) : link.hasPrefix("#") ? String(link.dropFirst()) : nil
            if let target {
                c.nodes[id]!.link = refs[target].map { TopicLink.make(canvas: c.id, node: $0) }
                if refs[target] == nil { report.skip("Link to a topic in another file") }
            }
        }
        report.canvases += 1
        return c
    }

    /// Builds several canvases with ids `c1…cN` and fills the report's counts.
    public static func build(_ list: [ICanvas], report: inout ImportReport) -> [Canvas] {
        list.enumerated().map { build($1, id: CanvasID("c\($0 + 1)"), report: &report) }
    }
}

// MARK: Shared helpers

enum XML {
    static func escape(_ s: String, attribute: Bool = true) -> String {
        var out = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        if attribute {
            out = out.replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "\n", with: "&#10;")
        }
        return out
    }

    /// Parses XML with Foundation's tree parser (no network: external entities off).
    static func parse(_ data: Data, name: String) throws -> XMLElement {
        do {
            let doc = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
            guard let root = doc.rootElement() else { throw ImportError.invalid(name, "no XML root element") }
            return root
        } catch let e as ImportError {
            throw e
        } catch {
            throw ImportError.invalid(name, "not well-formed XML")
        }
    }
}

extension XMLElement {
    func attr(_ name: String) -> String? { attribute(forName: name)?.stringValue }

    /// Direct child elements, optionally by local name (namespace prefixes ignored).
    func kids(_ local: String? = nil) -> [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }.filter {
            local == nil || $0.localName == local || $0.name == local
        }
    }

    func kid(_ local: String) -> XMLElement? { kids(local).first }

    /// All descendants with this local name, in document order.
    func descendants(_ local: String) -> [XMLElement] {
        var out: [XMLElement] = []
        for k in kids() {
            if k.localName == local || k.name == local { out.append(k) }
            out += k.descendants(local)
        }
        return out
    }
}

extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
