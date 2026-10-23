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
    /// with the report. `progress` gets (pages read, pages to read) after each page, and
    /// `grouping` is called once the reading is done if the on-device model then groups a
    /// flat list (D272). Cancelling the calling task stops the reading between pages.
    public static func importImage(
        _ data: Data, name: String, refine: Bool, progress: (@Sendable (Int, Int) -> Void)? = nil,
        grouping: (@Sendable () -> Void)? = nil
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
        if result.outlines.contains(where: groupable) { grouping?() }
        var canvases = result.outlines.map(\.canvas)
        var grouped = false
        for (i, outline) in result.outlines.enumerated() {
            if let ic = await refined(outline) {
                canvases[i] = ic
                grouped = true
            }
            // Cancel abandons the grouping too.
            try Task.checkCancellation()
        }
        return result.imported(canvases: canvases, source: source, grouped: grouped)
    }

    /// A flat list short enough for the on-device model to group (D152).
    static func groupable(_ outline: ImageOutline) -> Bool {
        outline.isFlat && outline.canvas.root.children.count <= ImageStructurer.maxLines
    }

    /// A flat outline grouped under the headings the on-device model picks, or nil (D152).
    static func refined(_ outline: ImageOutline) async -> ICanvas? {
        guard groupable(outline) else { return nil }
        let topics = outline.canvas.root.children.map(\.text)
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
/// pages read so far, the on-device grouping, and Cancel. The app shows it in a small
/// window once the source turns out to have two or more pages, or once the import has
/// taken longer than `showAfter`, a single picture too (D272).
@MainActor
@Observable
public final class ImageImportProgress: Identifiable {
    /// How an import ended: its document, an error, or cancelled (nothing opens).
    public enum Outcome {
        case imported(Imported)
        case failed(any Error)
        case cancelled
    }

    /// What a reader reports: (pages read, pages to read), or that the on-device model is
    /// grouping a flat list, which takes as long as it takes.
    public enum Step: Sendable, Equatable {
        case pages(Int, Int)
        case grouping
    }

    /// Reads a picture or PDF, reporting its steps. `ImageToMap.importImage` in the app;
    /// tests pass their own.
    public typealias Reader =
        @Sendable (Data, String, Bool, @escaping @Sendable (Step) -> Void) async throws -> Imported

    /// How long an import runs before its window shows: a picture read sooner opens
    /// without one, so the window doesn't flash.
    public static let showAfter: Duration = .milliseconds(500)

    public let id = UUID()
    public let name: String
    public private(set) var done = 0
    /// Pages to read; 0 until the source is opened.
    public private(set) var total = 0
    /// The pages are read and the on-device model is grouping a flat list.
    public private(set) var grouping = false
    public private(set) var cancelled = false
    public private(set) var finished = false
    /// Called once, when the window should show: the source has two or more pages, or the
    /// import is still running after `showAfter`.
    @ObservationIgnored public var onShow: (() -> Void)?
    @ObservationIgnored public var showAfter = ImageImportProgress.showAfter
    @ObservationIgnored private var shown = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let read: Reader

    public init(name: String, read: Reader? = nil) {
        self.name = name
        self.read =
            read ?? { data, name, refine, report in
                try await ImageToMap.importImage(
                    data, name: name, refine: refine, progress: { report(.pages($0, $1)) },
                    grouping: { report(.grouping) })
            }
    }

    /// The share of pages read (0–1).
    public var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

    /// No share to show: one picture being read, or the model grouping, whose length
    /// nobody knows.
    public var indeterminate: Bool { grouping || total <= 1 }

    /// "Reading page 2 of 5…", the same words as the merge sheet's row (D191), then
    /// "Grouping…" while the model works.
    public var detail: String {
        if grouping { return Loc.t("Grouping…") }
        return total > 1
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
                let im = try await read(data, name, refine) { step in
                    Task { @MainActor in self?.report(step) }
                }
                outcome = Task.isCancelled ? .cancelled : .imported(im)
            } catch {
                outcome = Task.isCancelled || error is CancellationError ? .cancelled : .failed(error)
            }
            self?.finished = true
            finish(outcome)
        }
        task = t
        let delay = showAfter
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            self?.show()
        }
        return t
    }

    /// Cancel: the reading stops between pages, or the grouping is abandoned, and nothing
    /// opens.
    public func cancel() {
        guard !finished, !cancelled else { return }
        cancelled = true
        task?.cancel()
    }

    func report(_ step: Step) {
        guard !cancelled else { return }
        switch step {
        case .pages(let d, let t):
            total = t
            done = max(done, min(d, t))
            if t > 1 { show() }
        case .grouping:
            grouping = true
        }
    }

    /// Asks for the window, once, while the import runs.
    private func show() {
        guard !shown, !finished, !cancelled else { return }
        shown = true
        onShow?()
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
                let im = try await ImageToMap.importImage(
                    data, name: name, refine: refine,
                    progress: { done, total in
                        guard total > 1, done < total else { return }
                        Task { @MainActor in self?.showToast(Loc.f("Reading page %lld of %lld…", done + 1, total)) }
                    },
                    grouping: { Task { @MainActor in self?.showToast(Loc.t("Grouping…")) } })
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
