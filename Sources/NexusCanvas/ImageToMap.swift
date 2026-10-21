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

    /// Reads the image, or every page of a PDF, off the main thread and returns its canvases
    /// with the report. `progress` gets (pages read, pages to read) after each page.
    /// Cancelling the calling task stops the reading between pages.
    public static func importImage(
        _ data: Data, name: String, refine: Bool, progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> Imported {
        let reading = Task.detached(priority: .userInitiated) {
            try ImageOutline.read(data, name: name, progress: progress)
        }
        let result = try await withTaskCancellationHandler {
            try await reading.value
        } onCancel: {
            reading.cancel()
        }
        let source = (name as NSString).lastPathComponent
        guard refine, ImageStructurer.isAvailable else { return result.imported(source: source) }
        var canvases = result.outlines.map(\.canvas)
        var grouped = false
        for (i, outline) in result.outlines.enumerated() {
            if let ic = await refined(outline) {
                canvases[i] = ic
                grouped = true
            }
        }
        return result.imported(canvases: canvases, source: source, grouped: grouped)
    }

    /// A flat outline grouped under the headings the on-device model picks, or nil (D152).
    static func refined(_ outline: ImageOutline) async -> ICanvas? {
        let topics = outline.canvas.root.children.map(\.text)
        guard outline.isFlat, topics.count <= ImageStructurer.maxLines else { return nil }
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
        return picked.flatMap { outline.grouped(headings: $0) }
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
                let im = try await ImageToMap.importImage(data, name: name, refine: refine) { done, total in
                    guard total > 1, done < total else { return }
                    Task { @MainActor in self?.showToast(Loc.f("Reading page %lld of %lld…", done + 1, total)) }
                }
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

    /// Every page's canvas, after this one; the first fills this canvas while it is untouched.
    func addImageCanvas(_ im: Imported) {
        guard var first = im.canvases.first else { return }
        let current = canvas
        let pristine = current.type == .mindmap && current.nodes.count == 1 && current.zones.isEmpty
        var target = canvasID
        store.commitDocument(Loc.t("Image to Map"), focus: canvasID) { d in
            var rest = im.canvases
            if pristine {
                first.id = current.id
                first.style = current.style
                d.canvases[current.id] = first
                rest.removeFirst()
            }
            guard !rest.isEmpty else { return }
            let added = d.add(rest, assets: im.assets, after: d.canvasOrder.firstIndex(of: current.id))
            if !pristine { target = added[0] }
        }
        if target != canvasID { switchCanvas(to: target) }
        selection = Selection(canvas.root)
        refreshView(frame: Array(canvas.nodes.keys))
        showImportReport(im.report)
    }
}
