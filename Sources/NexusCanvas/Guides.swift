import AppKit
import NexusCore
import NexusFormat
import NexusKeys

/// The built-in guides (M41): JSON files in `Guides/`, checked against
/// `schema/guide.schema.json`, one per diagram type that has one.
public enum GuideLibrary {
    /// Mind map, flowchart, data flow, architecture and threat model, so far.
    public static let all: [Guide] = (try? load()) ?? []

    public static func guide(for type: DiagramType) -> Guide? { all.first { $0.type == type } }

    static var folder: URL? { Bundle.module.url(forResource: "Guides", withExtension: nil) }

    /// Every guide file, by id. Throws on the first that doesn't read, so a broken built-in
    /// fails the tests instead of vanishing.
    static func load() throws -> [Guide] {
        guard let folder else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        return try files.map { url in
            try Guide(json: CanonicalJSON.parse(Data(contentsOf: url)), path: url.lastPathComponent)
        }
        .sorted { $0.id < $1.id }
    }
}

/// A tip's text with its `{command.id}` tokens resolved: the active profile's keys, or the
/// command's name when nothing is bound to it.
public enum GuideTip {
    public enum Part: Equatable, Sendable {
        case text(String)
        case key(String)
    }

    public static func parts(_ tip: String, key: (CommandID) -> String?, title: (CommandID) -> String?) -> [Part] {
        var out: [Part] = []
        var rest = Substring(tip)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            if open > rest.startIndex { out.append(.text(String(rest[..<open]))) }
            let id = CommandID(rawValue: String(rest[rest.index(after: open)..<close]))
            if let k = key(id) {
                out.append(.key(k))
            } else {
                out.append(.text("“\(title(id).map(Loc.t) ?? id.rawValue)”"))
            }
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { out.append(.text(String(rest))) }
        return out
    }
}

extension CanvasController {
    /// The canvas's guide, if its type has one.
    public var guide: Guide? { GuideLibrary.guide(for: canvas.type) }

    /// ⌃⌘G, View › Guide.
    public func toggleGuide() { guideVisible.toggle() }

    /// Coalesced to the next run-loop turn, so typing never waits on matching.
    func scheduleGuideUpdate() {
        guard guideVisible, !guideUpdatePending else { return }
        guideUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.updateGuide() }
        }
    }

    func updateGuide() {
        guideUpdatePending = false
        guard guideVisible, let g = guide else {
            if guideProgress != nil { guideProgress = nil }
            return
        }
        let skipped = canvas.guide.skipped(in: g.id)
        let key = "\(store.revision)|\(canvasID.rawValue)|\(g.id)|\(skipped.sorted())"
        let evaluated: GuideProgress
        if let c = guideCache, c.key == key {
            evaluated = c.progress
        } else {
            let c = canvas
            evaluated = GuideMatcher.evaluate(
                c, g, skipped: skipped, types: DiagramCatalog.isTechnical(c.type) ? scene.nodeTypes : nil)
            guideCache = (key, evaluated)
        }
        let p = evaluated.focused(on: selectedElement == nil ? selection.primary : nil)
        if p != guideProgress { guideProgress = p }
    }

    /// Skip a step, or bring it back: one undo step, saved with the canvas.
    public func toggleGuideSkip(_ step: String) {
        guard let g = guide else { return }
        let skipped = canvas.guide.skipped(in: g.id).contains(step)
        perform(skipped ? Loc.t("Restore Guide Step") : Loc.t("Skip Guide Step")) { $0.toggleGuideSkip(step, in: g.id) }
        updateGuide()
    }

    /// Clicking a step: its first match is selected and shown. Returns false for a step with
    /// none yet, whose tip then says what to do.
    @discardableResult
    public func selectGuideStep(_ index: Int) -> Bool {
        guard let p = guideProgress, p.steps.indices.contains(index),
            let id = p.steps[index].nodes.first(where: { canvas.nodes[$0] != nil })
        else { return false }
        select(id)
        return true
    }

    /// Format › Data › Type for the selection, as one undo step.
    public func setNodeType(_ type: NodeType?) {
        let ids = selection.nodes.filter { canvas.nodes[$0] != nil }
        guard !ids.isEmpty else { return }
        perform(Loc.t("Node Type")) { e in for id in ids { e.update(id) { $0.nodeType = type } } }
    }

    /// Set Node Type…: the Format panel's Data tab, where the Type control is.
    public func showNodeTypeControl() {
        UserDefaults.standard.set("data", forKey: "format.tab")
        onShowFormatPanel?()
    }

    /// The tip's parts in the active profile's keys.
    public func guideTipParts(_ tip: String) -> [GuideTip.Part] {
        GuideTip.parts(Loc.t(tip), key: { bindings(for: $0).first?.glyphs }, title: { registry[$0]?.title })
    }
}
