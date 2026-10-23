import CryptoKit
import Foundation
import ImageIO
import NexusCore
import NexusKeys

/// Things the canvas asks its host to present (popovers, sheets, panels).
public enum CanvasRequest: Equatable, Sendable {
    case note(NodeID)
    /// The comment thread (M14).
    case comments(NodeID)
    /// Edit Legend… (M14).
    case legend
    case link(NodeID)
    case image(NodeID)
    case labels(NodeID)
    case markers(NodeID)
    case stickers(NodeID)
    case audio(NodeID)
    case attachment(NodeID, Int)
}

/// Marker groups (EN): picking from the same group replaces; another group adds.
public enum MarkerLibrary {
    public struct Marker: Sendable, Identifiable, Equatable {
        public var id: String
        public var glyph: String
        public var color: String
    }

    public struct Group: Sendable, Identifiable {
        public var id: String
        public var name: String
        public var markers: [Marker]
    }

    public static let groups: [Group] = [
        Group(
            id: "priority", name: Loc.t("Priority"),
            markers: (1...9).map {
                Marker(
                    id: "priority-\($0)", glyph: "\($0)",
                    color: [
                        "#C62F35", "#C25E00", "#1E6FB8", "#2E7D4F", "#7A4CC2", "#4A4A55", "#4A4A55", "#4A4A55",
                        "#4A4A55",
                    ][$0 - 1])
            }),
        Group(
            id: "progress", name: Loc.t("Progress"),
            markers: [
                Marker(id: "progress-0", glyph: "○", color: "#4A4A55"),
                Marker(id: "progress-25", glyph: "◔", color: "#1E6FB8"),
                Marker(id: "progress-50", glyph: "◑", color: "#1E6FB8"),
                Marker(id: "progress-75", glyph: "◕", color: "#1E6FB8"),
                Marker(id: "progress-100", glyph: "✓", color: "#2E7D4F"),
            ]),
        Group(
            id: "flag", name: Loc.t("Flags"),
            markers: [
                Marker(id: "flag-red", glyph: "⚑", color: "#C62F35"),
                Marker(id: "flag-orange", glyph: "⚑", color: "#C25E00"),
                Marker(id: "flag-green", glyph: "⚑", color: "#2E7D4F"),
                Marker(id: "flag-blue", glyph: "⚑", color: "#1E6FB8"),
            ]),
        Group(
            id: "star", name: Loc.t("Stars"),
            markers: [
                Marker(id: "star-gold", glyph: "★", color: "#C08A00"),
                Marker(id: "star-red", glyph: "★", color: "#C62F35"),
                Marker(id: "star-blue", glyph: "★", color: "#1E6FB8"),
            ]),
        Group(
            id: "symbol", name: Loc.t("Symbols"),
            markers: [
                Marker(id: "symbol-question", glyph: "?", color: "#1E6FB8"),
                Marker(id: "symbol-exclaim", glyph: "!", color: "#C25E00"),
                Marker(id: "symbol-check", glyph: "✓", color: "#2E7D4F"),
                Marker(id: "symbol-cross", glyph: "✕", color: "#C62F35"),
                Marker(id: "symbol-arrow", glyph: "→", color: "#4A4A55"),
            ]),
        Group(
            id: "people", name: Loc.t("People"),
            markers: [
                Marker(id: "people-me", glyph: "◉", color: "#5850EC"),
                Marker(id: "people-team", glyph: "◎", color: "#0F9F9A"),
                Marker(id: "people-external", glyph: "◍", color: "#C25E00"),
            ]),
    ]

    public static func marker(_ id: String) -> Marker? {
        groups.lazy.flatMap(\.markers).first { $0.id == id }
    }

    public static func group(of id: String) -> String { String(id.split(separator: "-").first ?? "") }
}

/// Built-in stickers: an emoji starter set by category (EN). Image Playground adds more (M6).
public enum StickerLibrary {
    public static let categories: [(String, [String])] = [
        (Loc.t("Tech"), ["💻", "🖥️", "📱", "⌚️", "🔒", "🔑", "🗄️", "☁️", "🛰️", "🤖", "🧩", "⚙️", "🔌", "📡", "🧪", "🐞"]),
        (Loc.t("Business"), ["📈", "📉", "💰", "💳", "🏦", "📊", "🗂️", "📝", "📌", "📎", "🤝", "🏆", "🎯", "📣", "🧾", "⏰"]),
        (Loc.t("Learning"), ["📚", "🎓", "✏️", "🔬", "🧠", "💡", "🗺️", "🧭", "📐", "🔭", "🎨", "🎵", "📖", "🧮", "🔍", "🏫"]),
        (Loc.t("Travel"), ["✈️", "🚆", "🚗", "🚲", "🏨", "🏖️", "🏔️", "🗽", "🧳", "🎒", "🛳️", "🚀", "🗼", "🌉", "⛺️", "🍽️"]),
        (Loc.t("Nature"), ["🌱", "🌳", "🌸", "🍀", "🌻", "🌊", "🔥", "⚡️", "❄️", "🌈", "☀️", "🌙", "⭐️", "🐝", "🦋", "🐢"]),
    ]
}

@MainActor
extension CanvasController {
    // MARK: Selection of elements

    public func selectElement(_ ref: ElementRef?) { selectElement(ref, zones: []) }

    /// Every selected zone, in the order they were selected: the selected zone and the
    /// zones ⇧- or ⌘-clicked with it (D228). Empty when no zone is selected.
    public var selectedZones: [String] {
        guard case .zone(let z)? = selectedElement else { return [] }
        return zoneGroup.contains(z) ? zoneGroup : [z]
    }

    /// ⇧- or ⌘-click on a zone: adds it to the selected zones, or takes it out (D228). The
    /// zone clicked last is the selected element (the Format panel's).
    public func toggleZone(_ id: String) {
        guard canvas.zones.contains(where: { $0.id == id }) else { return }
        var zones = selectedZones
        if let i = zones.firstIndex(of: id) {
            zones.remove(at: i)
            selectElement(zones.last.map { .zone($0) }, zones: zones)
        } else {
            zones.append(id)
            selectElement(.zone(id), zones: zones)
        }
    }

    /// The zones a command on zone `id` acts on: every selected zone when `id` is one of
    /// them, else just `id` (D228, D260).
    public func zones(with id: String) -> [String] {
        let zones = selectedZones
        return zones.contains(id) ? zones : [id]
    }

    /// Selects these zones together, the first as the selected element.
    public func selectZones(_ ids: [String]) {
        let zones = ids.filter { id in canvas.zones.contains { $0.id == id } }
        selectElement(zones.first.map { .zone($0) }, zones: zones)
    }

    /// Select All Zones (`select.allZones`): every zone on the canvas, so ⌘C, ⌘X and ⌘D
    /// take them all.
    public func selectAllZones() { selectZones(canvas.zones.map(\.id)) }

    func selectElement(_ ref: ElementRef?, zones: [String]) {
        if mode == .edit { commitEdit() }
        selectedElement = ref
        zoneGroup = zones.count > 1 ? zones : []
        legendSelected = false
        if case .callout(let id)? = ref, let k = canvas.callouts.first(where: { $0.id == id }) {
            selection = Selection(k.topic)
        }
        onSceneChange?(false)
    }

    /// Keys while an element is selected: Delete removes it, Space / Return edits its
    /// label or title, ⌘/ collapses a zone, Esc returns to the topic.
    func handleElementKey(_ chord: KeyChord) -> KeyResult? {
        if case .relationship(let id)? = selectedElement, let r = sequenceMessageKey(chord, id) { return r }
        guard let ref = selectedElement, chord.modifiers.subtracting(.shift).isEmpty || chord.key == .character("/")
        else { return nil }
        switch chord.key {
        case .delete, .forwardDelete:
            deleteElement(ref)
            return .handled
        case .escape:
            selectElement(nil)
            return .handled
        case .space, .return:
            beginEditingElement(ref)
            return .handled
        case .character("/") where chord.modifiers == [.command]:
            if case .zone(let id) = ref {
                perform(Loc.t("Collapse Zone")) { $0.updateZone(id) { $0.collapsed.toggle() } }
                return .handled
            }
            return nil
        default:
            return nil
        }
    }

    /// Removes a relationship, boundary, summary, callout or zone (one undo step).
    /// A zone among several selected takes the others with it (D228).
    public func deleteElement(_ ref: ElementRef) {
        let zones = selectedZones
        let refs: [ElementRef] =
            zones.count > 1 && ref == .zone(ref.id) && zones.contains(ref.id) ? zones.map { .zone($0) } : [ref]
        perform(Loc.t("Delete")) { e in for r in refs { e.removeElement(r) } }
        selectedElement = nil
        onSceneChange?(true)
    }

    public func beginEditingElement(_ ref: ElementRef) {
        let c = canvas
        let text: String
        switch ref {
        case .relationship(let id):
            text =
                id.hasPrefix("t:")
                ? c.nodes[NodeID(String(id.dropFirst(2)))]?.edgeLabel ?? ""
                : c.relationships.first { $0.id == id }?.label ?? ""
        case .boundary(let id): text = c.boundaries.first { $0.id == id }?.title ?? ""
        case .zone(let id): text = c.zones.first { $0.id == id }?.title ?? ""
        case .summary(let id):
            if let s = c.summaries.first(where: { $0.id == id }) { beginEditing(s.topic) }
            return
        case .callout(let id):
            if let k = c.callouts.first(where: { $0.id == id }) { beginEditing(k.topic) }
            return
        }
        selectedElement = ref
        var session = EditSession(node: selection.primary, text: text, selectAll: true)
        session.element = ref
        edit = session
        mode = .edit
        onEditChange?(edit)
    }

    func commitElementText(_ ref: ElementRef, _ text: String) {
        onEditChange?(nil)
        switch ref {
        case .relationship(let id) where id.hasPrefix("t:"):
            // A tree edge drawn as a flow: its label lives on the child.
            let child = NodeID(String(id.dropFirst(2)))
            perform(Loc.t("Label")) { $0.update(child) { $0.edgeLabel = text.isEmpty ? nil : text } }
        case .relationship(let id): perform(Loc.t("Label")) { $0.updateRelationship(id) { $0.label = text } }
        case .boundary(let id): perform(Loc.t("Boundary Title")) { $0.updateBoundary(id) { $0.title = text } }
        case .zone(let id):
            perform(Loc.t("Zone Title")) { $0.updateZone(id) { $0.title = text.isEmpty ? Loc.t("Zone") : text } }
        default: break
        }
        selectedElement = ref
        onSceneChange?(true)
    }

    // MARK: Element commands

    /// ⇧⌘B
    public func addBoundary() {
        let ids = selection.nodes
        if let id = perform(Loc.t("Boundary"), { try $0.addBoundary(around: ids) }) {
            selectedElement = .boundary(id)
            onSceneChange?(false)
        }
    }

    /// ⇧⌘]
    public func addSummary() {
        let ids = selection.nodes
        createElementTopic(Loc.t("Summary")) { try $0.addSummary(over: ids) }
    }

    /// ⇧⌘C
    public func addCallout() {
        let host = selection.primary
        createElementTopic(Loc.t("Callout")) { try $0.addCallout(on: host) }
    }

    private func createElementTopic(_ name: String, _ body: (inout CanvasEditor) throws -> NodeID) {
        guard let id = perform(name, refresh: false, selectionAfter: { Selection($0) }, body) else { return }
        selectedElement = nil
        edit = EditSession(node: id, text: canvas.nodes[id]?.text ?? "", selectAll: true)
        mode = .edit
        rebuildScene()
        onEditChange?(edit)
        onSceneChange?(true)
        onReveal?(id)
    }

    /// ⌥⌘Z: a zone around the selected floating topics, or an empty one in free space.
    public func addZone() {
        let floating = selection.nodes.filter { canvas.floating.contains($0) }
        var rect = CGRect.null
        for f in floating {
            for d in canvas.subtree(f) { if let n = scene.nodes[d] { rect = rect.union(n.frame.rect) } }
        }
        if rect.isNull {
            let b = scene.bounds
            rect = CGRect(x: (b.isNull ? 0 : b.minX), y: (b.isNull ? 120 : b.maxY + 60), width: 372, height: 172)
        }
        let origin = CanvasPoint(x: rect.minX - 24, y: rect.minY - 44)
        let w = rect.width + 48
        let h = rect.height + 68
        guard
            let id = perform(
                Loc.t("Zone"),
                { $0.addZone(title: Loc.t("Zone"), origin: origin, width: w, height: h, members: floating) })
        else { return }
        beginEditingElement(.zone(id))
    }

    /// ⌥⌘] / ⌥⌘[ on a zone or a floating topic. Several selected zones move together,
    /// keeping their order among themselves (D259).
    public func reorderSelection(_ order: CanvasEditor.ZOrder) {
        if case .zone? = selectedElement {
            reorderZones(selectedZones, order)
            return
        }
        let id = selection.primary
        guard canvas.floating.contains(id) else {
            showToast(Loc.t("Arrange works on zones and floating topics"))
            return
        }
        perform(Loc.t("Arrange")) { $0.reorderFloating(id, order) }
    }

    /// Arrange on these zones, one undo step: Bring to Front, Send to Back and the Format
    /// panel's Order (D259).
    public func reorderZones(_ ids: [String], _ order: CanvasEditor.ZOrder) {
        perform(Loc.t("Arrange")) { $0.reorderZones(ids, order) }
    }

    // MARK: Enrichments

    public func toggleMarker(_ marker: String) {
        let targets = selection.nodes
        let group = MarkerLibrary.group(of: marker)
        perform(Loc.t("Marker")) { e in
            for t in targets {
                e.update(t) { n in
                    if n.markers.contains(marker) {
                        n.markers.removeAll { $0 == marker }
                    } else {
                        n.markers.removeAll { MarkerLibrary.group(of: $0) == group }
                        n.markers.append(marker)
                    }
                }
            }
        }
    }

    public func setLabels(_ labels: [String], on ids: [NodeID]? = nil) {
        let targets = ids ?? selection.nodes
        let clean = labels.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        perform(Loc.t("Labels")) { e in for t in targets { e.update(t) { $0.labels = clean } } }
    }

    /// Every label used on this canvas, most used first (autocomplete).
    public var labelUsage: [(label: String, count: Int)] {
        var counts: [String: Int] = [:]
        for n in canvas.nodes.values { for l in n.labels { counts[l, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    public func setNote(_ text: String, on id: NodeID) {
        perform(Loc.t("Note")) { e in e.update(id) { $0.note = text.isEmpty ? nil : Note(text: text) } }
    }

    public func setLink(_ link: String?, on id: NodeID) {
        perform(Loc.t("Link")) { e in e.update(id) { $0.link = link?.isEmpty == true ? nil : link } }
    }

    public func setSticker(_ sticker: String?, on id: NodeID) {
        perform(Loc.t("Sticker")) { e in e.update(id) { $0.sticker = sticker.map { AssetRef(asset: $0) } } }
    }

    /// Stores bytes in the package's assets under a content-hashed name.
    /// HEIC becomes JPEG; GPS and other location metadata are removed from any photo.
    static func optimisedImage(_ data: Data, ext: String) -> (Data, String)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
            let type = CGImageSourceGetType(src) as String?,
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]
        else { return nil }
        let heic = type == "public.heic" || type == "public.heif"
        let hasLocation = props[kCGImagePropertyGPSDictionary as String] != nil
        guard heic || hasLocation else { return nil }
        let outType = heic ? "public.jpeg" : type
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, outType as CFString, 1, nil) else { return nil }
        // Copy the image without its metadata (keeping orientation).
        var keep: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: 0.88]
        if let o = props[kCGImagePropertyOrientation as String] { keep[kCGImagePropertyOrientation as String] = o }
        CGImageDestinationAddImageFromSource(dest, src, 0, keep as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, heic ? "jpg" : ext)
    }

    public func storeAsset(_ data: Data, ext: String) -> String {
        Self.storeAsset(data, ext: ext, in: store)
    }

    /// Content-hashed asset names, so the same image is stored once.
    public static func storeAsset(_ data: Data, ext: String, in store: DocumentStore) -> String {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(20)
        let name = "\(digest).\(ext.lowercased())"
        if store.model.assets[name] == nil { store.updateDocument { $0.assets[name] = data } }
        return name
    }

    /// Settings › Files: images over the embed limit are linked (the topic gets a file
    /// link), and imports can be optimised (HEIC → JPEG, location metadata stripped).
    public func setImage(_ data: Data, ext: String, size: CGSize?, on id: NodeID, source: URL? = nil) {
        let limit = (Double(prefs.string("files.embedLimit")) ?? 10) * 1_048_576
        if limit > 0, Double(data.count) > limit, let source {
            perform(Loc.t("Link Image")) { e in e.update(id) { $0.link = source.absoluteString } }
            showToast(
                Loc.f(
                    "%@ is larger than %@ MB, so it’s linked, not copied", source.lastPathComponent,
                    prefs.string("files.embedLimit"))
            )
            return
        }
        let image = imageAsset(data, ext: ext, size: size)
        perform(Loc.t("Image")) { e in e.update(id) { $0.image = image } }
    }

    /// Stores an image's bytes (optimised when Settings › Files asks) and returns what a
    /// topic holds: at most 200 pt wide, its aspect kept.
    func imageAsset(_ data: Data, ext: String, size: CGSize?) -> AssetRef {
        var data = data
        var ext = ext
        if prefs.bool("files.optimiseImages"), let (d, e) = Self.optimisedImage(data, ext: ext) {
            data = d
            ext = e
        }
        let name = storeAsset(data, ext: ext)
        let w = size.map { min(Double($0.width), 200) }
        let h = size.map { Double($0.height) * (w ?? 200) / max(Double($0.width), 1) }
        return AssetRef(asset: name, width: w, height: h)
    }

    public func removeImage(on id: NodeID) {
        perform(Loc.t("Remove Image")) { e in e.update(id) { $0.image = nil } }
    }

    public func addAttachment(_ data: Data, name: String, on id: NodeID) {
        let ext = (name as NSString).pathExtension
        let asset = storeAsset(data, ext: ext.isEmpty ? "bin" : ext)
        perform(Loc.t("Attach File")) { e in e.update(id) { $0.attachments.append(AssetRef(asset: asset, name: name)) }
        }
    }

    public func setAudio(_ data: Data, duration: Double, on id: NodeID) {
        let asset = storeAsset(data, ext: "m4a")
        perform(Loc.t("Audio Note")) { e in e.update(id) { $0.audio = AudioNote(asset: asset, duration: duration) } }
    }

    /// Clicking a parent's progress ring completes (or reopens) every to-do below it.
    public func toggleBranchTodos(_ id: NodeID) {
        guard let kids = canvas.nodes[id]?.children else { return }
        let todos = kids.filter { canvas.nodes[$0]?.todo != nil }
        guard !todos.isEmpty else { return }
        let allDone = todos.allSatisfy { canvas.nodes[$0]?.todo?.done == true }
        perform("To-Dos") { e in for t in todos { e.update(t) { $0.todo = Todo(done: !allDone) } } }
        if !allDone { showToast(Loc.t("Branch complete ✦")) }
    }

    // MARK: Links

    /// Topics that link to `id` (backlinks, shown in Data).
    public func backlinks(to id: NodeID) -> [(canvas: CanvasID, node: NodeID, text: String, canvasTitle: String)] {
        var out: [(CanvasID, NodeID, String, String)] = []
        for c in store.model.orderedCanvases {
            for (nid, n) in c.nodes {
                if let l = n.link, let t = TopicLink.parse(l), t.node == id, t.canvas == canvasID {
                    out.append((c.id, nid, n.text, c.title))
                }
            }
        }
        return out.sorted { $0.2 < $1.2 }
    }

    /// Following a topic link flies the camera there; ⌘[ flies back.
    public func followLink(of id: NodeID) {
        guard let link = canvas.nodes[id]?.link else { return }
        if let t = TopicLink.parse(link) {
            linkHistory.append((canvasID, id))
            if t.canvas != canvasID { switchCanvas(to: t.canvas) }
            if canvas.nodes[t.node] != nil { select(t.node) } else { showToast(Loc.t("That topic no longer exists")) }
        } else if let url = URL(string: link) {
            onOpenURL?(url)
        }
    }

    public func flyBack() {
        guard let (c, n) = linkHistory.popLast() else {
            showToast(Loc.t("Nothing to fly back to"))
            return
        }
        if c != canvasID { switchCanvas(to: c) }
        select(n)
    }

    // MARK: Direct manipulation

    public func moveTopic(_ id: NodeID, toParent parent: NodeID, at index: Int?, duplicate: Bool = false) {
        if duplicate {
            perform(Loc.t("Duplicate"), selectionAfter: { Selection($0) }) {
                try $0.duplicate(id, toParent: parent, at: index)
            }
        } else {
            perform(Loc.t("Move"), selectionAfter: { Selection(id) }) { try $0.move(id, toParent: parent, at: index) }
        }
        onReveal?(selection.primary)
    }

    public func detachTopic(_ id: NodeID, at point: CGPoint) {
        perform(Loc.t("Detach"), selectionAfter: { Selection(id) }) {
            try $0.detach(id, at: CanvasPoint(x: point.x, y: point.y))
        }
    }

    public func moveFloating(_ id: NodeID, to point: CGPoint) {
        perform(Loc.t("Move"), selectionAfter: { Selection(id) }) {
            try $0.moveFloating(id, to: CanvasPoint(x: point.x, y: point.y))
        }
    }

    public func moveZone(_ id: String, by delta: CGSize) {
        perform(Loc.t("Move Zone")) { $0.moveZone(id, by: delta.width, delta.height) }
    }

    /// Dragging one of several selected zones moves them all, one undo step (D228).
    public func moveZones(_ ids: [String], by delta: CGSize) {
        guard ids.count > 1 else {
            if let id = ids.first { moveZone(id, by: delta) }
            return
        }
        perform(Loc.t("Move Zones")) { e in for id in ids { e.moveZone(id, by: delta.width, delta.height) } }
    }

    /// Reset Style (⌥⌘R) on an element returns it to its defaults.
    public func resetElementStyle(_ ref: ElementRef) {
        switch ref {
        case .relationship(let id):
            updateRelationship(id) { r in
                let fresh = Relationship(id: r.id, from: r.from, to: r.to, label: r.label)
                r = fresh
            }
        case .boundary(let id):
            updateBoundary(id) { b in b = Boundary(id: b.id, nodes: b.nodes, title: b.title) }
        case .summary(let id):
            updateSummary(id) { s in
                s.width = 2
                s.color = nil
            }
        case .callout(let id):
            updateCallout(id) { k in
                k.shape = "rounded"
                k.side = "auto"
            }
        case .zone(let id):
            updateZones(zones(with: id)) { z in
                z.frame = "rounded"
                z.color = nil
                z.autoResize = true
            }
        }
    }

    /// Grow or shrink a summary's sibling range (⇧↑↓ in the design).
    public func extendSummary(_ id: String, by delta: Int) {
        guard let s = canvas.summaries.first(where: { $0.id == id }), let kids = canvas.nodes[s.parent]?.children,
            let lo = kids.firstIndex(of: s.from), let hi = kids.firstIndex(of: s.to)
        else { return }
        let newHi = min(max(lo, hi + delta), kids.count - 1)
        updateSummary(id) { $0.to = kids[newHi] }
    }

    // MARK: Element styling (Format › Elements)

    public func updateRelationship(_ id: String, _ body: @escaping (inout Relationship) -> Void) {
        perform(Loc.t("Relationship Style")) { $0.updateRelationship(id, body) }
    }

    public func updateBoundary(_ id: String, _ body: @escaping (inout Boundary) -> Void) {
        perform(Loc.t("Boundary Style")) { $0.updateBoundary(id, body) }
    }

    public func updateSummary(_ id: String, _ body: @escaping (inout Summary) -> Void) {
        perform(Loc.t("Summary Style")) { $0.updateSummary(id, body) }
    }

    public func updateCallout(_ id: String, _ body: @escaping (inout Callout) -> Void) {
        perform(Loc.t("Callout Style")) { $0.updateCallout(id, body) }
    }

    public func updateZone(_ id: String, _ body: @escaping (inout Zone) -> Void) {
        perform(Loc.t("Zone Style")) { $0.updateZone(id, body) }
    }

    /// The Format panel's zone section with several zones selected: one change to every
    /// one of them, one undo step (D260).
    public func updateZones(_ ids: [String], _ body: @escaping (inout Zone) -> Void) {
        guard ids.count > 1 else {
            if let id = ids.first { updateZone(id, body) }
            return
        }
        perform(Loc.t("Zone Style")) { e in for id in ids { e.updateZone(id, body) } }
    }

    /// The selected zones' common value, or nil when they differ (shown as mixed, D260).
    public func commonZoneValue<T: Equatable>(_ key: KeyPath<Zone, T>) -> T? {
        let values = selectedZones.compactMap { id in canvas.zones.first { $0.id == id }?[keyPath: key] }
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }
}
