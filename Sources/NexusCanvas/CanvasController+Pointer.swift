import AppKit
import NexusCore
import NexusFormat
import NexusInterchange

/// Paste and Zone where the empty-canvas menu opened (M26), as Xmind places them. ⌘V and
/// ⌥⌘Z keep their own placement: under the selection, and around the selected floating
/// topics or below the map.
@MainActor
extension CanvasController {
    /// Gap between pasted branches stacked under the pointer.
    static let pastedBranchGap: CGFloat = 24

    /// The empty-canvas menu's Paste (D222): what ⌘V would paste, as floating topics with
    /// the first where the menu opened and the rest stacked below it (one undo step). A
    /// copied zone lands with its top-left corner there; one line of text becomes one
    /// floating topic, and an image a floating topic holding it (D253).
    public func paste(at point: CGPoint) {
        if mode == .edit { return }
        let pb = pasteboard
        let at = CanvasPoint(x: Double(point.x), y: Double(point.y))
        var fragment: Canvas?
        var name = Loc.t("Paste")
        // Copied from this canvas in this document: outside dependencies are kept (D230).
        let same = pb.string(forType: .nexusFragmentSource) == fragmentSource
        if let data = pb.data(forType: .nexusFragment), let v = try? CanonicalJSON.parse(data),
            let f = try? Canvas(json: v, path: "clipboard")
        {
            if !f.zones.isEmpty {
                let name = f.zones.count > 1 ? Loc.t("Paste Zones") : Loc.t("Paste Zone")
                let ids = perform(name) { e in e.pasteZones(f, at: at, sameCanvas: same) }
                if let ids, !ids.isEmpty { selectZones(ids) }
                return
            }
            fragment = f
        } else if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            if let (ic, _) = Interchange.parsePasted(text) {
                var report = ImportReport(source: "Clipboard", format: "")
                let c = CanvasBuilder.build(ic, id: canvasID, report: &report)
                fragment = ic.synthesizedRoot ? c.fragment(c.nodes[c.root]?.children ?? []) : c.fragment([c.root])
                name = Loc.t("Paste Outline")
            } else {
                let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
                perform(Loc.t("Paste"), selectionAfter: { Selection($0) }) { e in e.addFloating(at: at, text: line) }
                return
            }
        }
        guard let f = fragment else { return pasteImage(at: at) }
        let root = canvas.root
        perform(name, selectionAfter: { (ids: [NodeID]) in Selection(primary: ids.first ?? root, nodes: ids) }) { e in
            let tops = try e.paste(f, under: root, sameCanvas: same)
            for t in tops { try e.detach(t, at: at) }
            guard tops.count > 1 else { return tops }
            // Every branch starts at the pointer; lay them out once to stack them.
            let laid = builder.build(e.canvas, env: styleEnvironment)
            var next: CGFloat?
            for t in tops {
                let r = e.canvas.subtree(t).compactMap { laid.nodes[$0]?.frame.rect }.reduce(CGRect.null) {
                    $0.union($1)
                }
                guard !r.isNull else { continue }
                // How far this branch reaches above and below its topic's position.
                let (above, below) = (point.y - r.minY, r.maxY - point.y)
                let y = next.map { $0 + above } ?? point.y
                if y != point.y { try e.moveFloating(t, to: CanvasPoint(x: Double(point.x), y: Double(y))) }
                next = y + below + Self.pastedBranchGap
            }
            return tops
        }
    }

    /// An image on the clipboard (what ⌘V would put on the selected topic) as a new
    /// floating topic holding it, at the point, selected, one undo step (D253).
    private func pasteImage(at point: CanvasPoint) {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type), let rep = NSBitmapImageRep(data: data),
                let png = rep.representation(using: .png, properties: [:])
            else { continue }
            let image = imageAsset(png, ext: "png", size: CGSize(width: rep.pixelsWide, height: rep.pixelsHigh))
            perform(Loc.t("Paste"), selectionAfter: { Selection($0) }) { e in
                let id = e.addFloating(at: point, text: "")
                e.update(id) { $0.image = image }
                return id
            }
            return
        }
    }

    /// The empty-canvas menu's Zone (D223): an empty zone, the size ⌥⌘Z gives one in free
    /// space, with its top-left corner where the menu opened; its title opens for typing.
    public func addZone(at point: CGPoint) {
        let origin = CanvasPoint(x: Double(point.x), y: Double(point.y))
        guard
            let id = perform(
                Loc.t("Zone"),
                { $0.addZone(title: Loc.t("Zone"), origin: origin, width: 420, height: 240, members: []) })
        else { return }
        beginEditingElement(.zone(id))
    }
}
