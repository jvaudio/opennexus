import AppKit
import NexusAI
import NexusCore
import NexusInterchange
import Observation

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

/// File › Import… of a picture or PDF (M29, D238): the reading off the main thread, the
/// pages read so far, and Cancel. The app shows it in a small window once the source turns
/// out to have two or more pages; a single picture reads in under a second, as before.
@MainActor
@Observable
public final class ImageImportProgress: Identifiable {
    /// How an import ended: its document, an error, or cancelled (nothing opens).
    public enum Outcome {
        case imported(Imported)
        case failed(any Error)
        case cancelled
    }

    /// Reads a picture or PDF, reporting (pages read, pages to read). `ImageToMap.importImage`
    /// in the app; tests pass their own.
    public typealias Reader =
        @Sendable (Data, String, Bool, @escaping @Sendable (Int, Int) -> Void) async throws -> Imported

    public let id = UUID()
    public let name: String
    public private(set) var done = 0
    /// Pages to read; 0 until the source is opened.
    public private(set) var total = 0
    public private(set) var cancelled = false
    public private(set) var finished = false
    /// Called once, when the source turns out to have two or more pages.
    @ObservationIgnored public var onManyPages: (() -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let read: Reader

    public init(name: String, read: Reader? = nil) {
        self.name = name
        self.read =
            read ?? { data, name, refine, progress in
                try await ImageToMap.importImage(data, name: name, refine: refine, progress: progress)
            }
    }

    /// The share of pages read (0–1).
    public var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

    /// "Reading page 2 of 5…", the same words as the merge sheet's row (D191).
    public var detail: String {
        total > 1
            ? Loc.f("Reading page %lld of %lld…", min(done + 1, total), total)
            : Loc.t("Reading the text in the image…")
    }

    /// Starts reading; `finish` gets the outcome once, on the main actor. The returned task
    /// ends when it has.
    @discardableResult
    public func start(
        _ data: Data, refine: Bool, finish: @escaping @MainActor (Outcome) -> Void
    ) -> Task<Void, Never> {
        let read = read
        let name = name
        let t = Task { @MainActor [weak self] in
            let outcome: Outcome
            do {
                let im = try await read(data, name, refine) { done, total in
                    Task { @MainActor in self?.pages(done, of: total) }
                }
                outcome = Task.isCancelled ? .cancelled : .imported(im)
            } catch {
                outcome = Task.isCancelled || error is CancellationError ? .cancelled : .failed(error)
            }
            self?.finished = true
            finish(outcome)
        }
        task = t
        return t
    }

    /// Cancel: the reading stops between pages and nothing opens.
    public func cancel() {
        guard !finished, !cancelled else { return }
        cancelled = true
        task?.cancel()
    }

    func pages(_ d: Int, of t: Int) {
        guard !cancelled else { return }
        let first = total <= 1 && t > 1
        total = t
        done = max(done, min(d, t))
        if first { onManyPages?() }
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
