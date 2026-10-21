import AppKit
import NexusAI
import NexusCore
import NexusInterchange

/// Image to mind map (M12): Vision reads the text and the layout heuristics rebuild the
/// hierarchy; when the layout shows none, Apple Intelligence, if it can run, picks the
/// lines that head groups (D150–D154). Everything happens on this Mac.
public enum ImageToMap {
    /// Settings › AI: group flat text from images with the on-device model (off by default;
    /// it guesses wrong too often to run unasked, D152).
    public static let refineKey = "ai.structureImages"
    /// How long the model may take before the heuristic outline is used as it is.
    static let refineTimeout: Duration = .seconds(30)

    public static func isImage(name: String) -> Bool { InterchangeFormat.detect(name: name) == .image }

    /// Reads the image off the main thread and returns one canvas with its report.
    public static func importImage(_ data: Data, name: String, refine: Bool) async throws -> Imported {
        let outline = try await Task.detached(priority: .userInitiated) {
            try ImageOutline.read(data, name: name)
        }.value
        let source = (name as NSString).lastPathComponent
        let topics = outline.canvas.root.children.map(\.text)
        guard refine, outline.isFlat, topics.count <= ImageStructurer.maxLines, ImageStructurer.isAvailable
        else { return outline.imported(source: source) }
        let title = outline.canvas.root.text
        let picked = try? await withThrowingTaskGroup(of: [Int]?.self) { group in
            group.addTask { try await ImageStructurer.headings(title: title, lines: topics) }
            group.addTask {
                try await Task.sleep(for: refineTimeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if let picked, let ic = outline.grouped(headings: picked) {
            return outline.imported(canvas: ic, source: source, grouped: true)
        }
        return outline.imported(source: source)
    }

    /// An image on the pasteboard: a copied picture, or a copied image file.
    public static func image(on pb: NSPasteboard) -> (data: Data, name: String)? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
            let url = urls.first(where: { isImage(name: $0.lastPathComponent) }),
            let data = try? Data(contentsOf: url)
        {
            return (data, url.lastPathComponent)
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.heic")] {
            if let data = pb.data(forType: type), let rep = NSBitmapImageRep(data: data),
                let png = rep.representation(using: .png, properties: [:])
            {
                return (png, Loc.t("Pasted Image") + ".png")
            }
        }
        if let pdf = pb.data(forType: .pdf) { return (pdf, Loc.t("Pasted Image") + ".pdf") }
        return nil
    }
}

extension CanvasController {
    /// Image to mind map into this document, as one undo: this canvas while it is still an
    /// untouched mind map, otherwise a new canvas after it. The import report follows.
    public func importImage(_ data: Data, name: String) {
        if mode == .edit { commitEdit() }
        showToast(Loc.t("Reading the text in the image…"))
        let refine = prefs.bool(ImageToMap.refineKey)
        Task { @MainActor [weak self] in
            do {
                let im = try await ImageToMap.importImage(data, name: name, refine: refine)
                self?.addImageCanvas(im)
            } catch {
                self?.showToast(Loc.f("Couldn’t import “%@”: %@", name, String(describing: error)))
            }
        }
    }

    /// ⇧⌘V: the picture on the clipboard becomes a map.
    public func pasteImageAsMap() {
        guard let (data, name) = ImageToMap.image(on: pasteboard) else {
            showToast(Loc.t("Copy a picture or an image file first"))
            return
        }
        importImage(data, name: name)
    }

    func addImageCanvas(_ im: Imported) {
        guard var incoming = im.canvases.first else { return }
        let current = canvas
        let pristine = current.type == .mindmap && current.nodes.count == 1 && current.zones.isEmpty
        var target = canvasID
        store.commitDocument(Loc.t("Image to Map"), focus: canvasID) { d in
            if pristine {
                incoming.id = current.id
                incoming.style = current.style
                d.canvases[current.id] = incoming
            } else {
                target = d.add([incoming], assets: im.assets, after: d.canvasOrder.firstIndex(of: current.id))[0]
            }
        }
        if target != canvasID { switchCanvas(to: target) }
        selection = Selection(canvas.root)
        refreshView(frame: Array(canvas.nodes.keys))
        showImportReport(im.report)
    }
}
