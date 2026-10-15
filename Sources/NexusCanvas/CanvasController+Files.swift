import AppKit
import NexusAI
import NexusCore
import NexusFormat
import NexusInterchange
import NexusKeys
import NexusTheme
import UniformTypeIdentifiers

// MARK: Export formats (artboard 30)

public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
    case png, jpeg, svg, pdf
    case mermaid, plantuml, drawio, json, opml
    case markdown, word, powerpoint, keynote, csv

    public var id: String { rawValue }

    public enum Group: String, CaseIterable, Sendable {
        case visual = "VISUAL", structural = "STRUCTURAL", document = "DOCUMENT"
    }

    public var group: Group {
        switch self {
        case .png, .jpeg, .svg, .pdf: .visual
        case .mermaid, .plantuml, .drawio, .json, .opml: .structural
        default: .document
        }
    }

    public var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .svg: "SVG"
        case .pdf: "PDF"
        case .mermaid: "Mermaid"
        case .plantuml: "PlantUML"
        case .drawio: "draw.io"
        case .json: "JSON · YAML"
        case .opml: "OPML"
        case .markdown: "Markdown"
        case .word: "Word"
        case .powerpoint: "PowerPoint"
        case .keynote: "Keynote"
        case .csv: "CSV · threats"
        }
    }

    public var ext: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .svg: "svg"
        case .pdf: "pdf"
        case .mermaid: "mmd"
        case .plantuml: "puml"
        case .drawio: "drawio"
        case .json: "json"
        case .opml: "opml"
        case .markdown: "md"
        case .word: "docx"
        case .powerpoint: "pptx"
        case .keynote: "key"
        case .csv: "csv"
        }
    }

    /// The written file's extension (Keynote opens the .pptx; D74).
    public var fileExt: String { self == .keynote ? "pptx" : self == .json ? "json" : ext }

    public var isText: Bool { [.svg, .mermaid, .plantuml, .drawio, .json, .opml, .markdown, .csv].contains(self) }
    public var isVisual: Bool { group == .visual }
}

/// The export sheet's settings; the last ones are remembered per format.
public struct ExportState: Equatable, Sendable {
    public var format: ExportFormat = .png
    public var image = ImageExporter.Options()
    public var jpegQuality = 0.85
    public var svg = SVGExporter.Options()
    public var mermaid: MermaidFormat.Flavour?
    public var markdown = MarkdownFormat.Options()
    public var yaml = false
    public var prettyJSON = true
    /// PDF: this canvas, every canvas, or the presentation.
    public var pdfScope = "canvas"
    /// Mask emails, keys and names in the exported copy (Settings › Export › Data masking).
    public var mask = false
    /// Show the masking toggle in the sheet (Data masking: Ask).
    public var askMask = false
    /// Settings › Export › Split by main branch (PNG and JPEG).
    public var split = false
    public init() {}
}

/// Map Shot (⌃⌘M, artboard 51).
public struct MapShotState: Equatable, Sendable {
    public enum Aspect: String, CaseIterable, Sendable {
        case square = "1:1", fourThree = "4:3", sixteenTen = "16:10", sixteenNine = "16:9", free = "Free"
        public var ratio: CGFloat? {
            switch self {
            case .square: 1
            case .fourThree: 4.0 / 3
            case .sixteenTen: 16.0 / 10
            case .sixteenNine: 16.0 / 9
            case .free: nil
            }
        }
    }
    /// The frame in world points.
    public var rect: CGRect
    public var aspect: Aspect = .sixteenTen
    /// Frame colour behind the shot: theme canvas, a soft gradient, or black.
    public var frame = "canvas"
    public var padding: Double = 12
    public var shadow = true
    public var scale: Double = 2
}

public struct MergeSource: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var kind: String
    public var detail: String
    public var canvases: [Canvas]
    public var assets: [String: Data]

    public static func == (a: MergeSource, b: MergeSource) -> Bool { a.name == b.name && a.canvases == b.canvases }
}

public struct MergeState: Equatable, Sendable {
    public var intoThisCanvas = false
    public var mapOfContent = true
    public var sources: [MergeSource] = []
}

extension NSPasteboard.PasteboardType {
    /// Copied topics as a canvas fragment (canonical JSON).
    public static let nexusFragment = NSPasteboard.PasteboardType("org.opennexus.fragment")
    /// A whole canvas (Copy canvas).
    public static let nexusCanvas = NSPasteboard.PasteboardType("org.opennexus.canvas")
}

extension CanvasController {
    // MARK: Export sheet (⇧⌘E)

    public func openExport(_ format: ExportFormat? = nil) {
        if mode == .edit { commitEdit() }
        var s = ExportState.remembered(format ?? ExportState.lastFormat(in: prefs.defaults), prefs: prefs)
        s.image.selection = selection.nodes
        if selection.nodes.count == 1, selection.primary != canvas.root, format == nil, s.image.scope == .selection {
            s.image.scope = .branch
        }
        exportState = s
    }

    public func closeExport() {
        if let s = exportState { s.remember(in: prefs.defaults) }
        exportState = nil
        onRestoreFocus?()
    }

    /// Updates the sheet (and the preview).
    public func setExport(_ s: ExportState) {
        var s = s
        s.image.selection = selection.nodes
        if let old = exportState, s.format != old.format {
            old.remember(in: prefs.defaults)
            s = ExportState.remembered(s.format, keeping: s, prefs: prefs)
        }
        exportState = s
    }

    /// Model to export from (with view-only state left out).
    var exportModel: DocumentModel { exportModel(exportState ?? ExportState()) }

    /// The exported copy: masked, without AI provenance or chats, per Settings.
    func exportModel(_ s: ExportState) -> DocumentModel {
        var m = store.model
        if s.mask {
            for (id, c) in m.canvases {
                var masked = Masker.maskedCopy(
                    c, hits: Masker.scan(c, options: maskOptions), id: id, options: maskOptions)
                masked.title = c.title
                m.canvases[id] = masked
            }
        }
        if prefs.bool("export.stripAI") {
            for (id, c) in m.canvases { for n in c.nodes.keys { m.canvases[id]?.nodes[n]?.ai = false } }
        }
        if prefs.bool("privacy.removeChatsOnExport") { m.chats = [] }
        return m
    }

    /// The text a structural or document format produces (the preview and Copy).
    public func exportText(_ s: ExportState) -> String? {
        let c = exportModel(s).canvases[canvasID] ?? canvas
        let top: NodeID? = s.image.scope == .branch ? s.image.selection.first : nil
        switch s.format {
        case .mermaid: return MermaidFormat.export(c, flavour: s.mermaid)
        case .plantuml: return PlantUMLFormat.export(c)
        case .drawio: return DrawIOFormat.export(c, frames: drawioFrames())
        case .json:
            return s.yaml
                ? DocumentJSON.yaml(exportModel(s)) : DocumentJSON.export(exportModel(s), pretty: s.prettyJSON)
        case .opml: return OPMLFormat.export(c, from: top)
        case .markdown: return MarkdownFormat.export(c, from: top, options: s.markdown)
        case .csv: return CSVFormat.export(c)
        case .svg: return SVGExporter.export(exportModel(s), canvas: canvasID, s.image, s.svg)
        default: return nil
        }
    }

    /// Node boxes and colours from the current layout, for draw.io.
    func drawioFrames() -> [NodeID: DrawIOFormat.Frame] {
        var out: [NodeID: DrawIOFormat.Frame] = [:]
        for (id, n) in scene.nodes where CanvasController.ghostIndex(id) == nil {
            let r = n.frame.rect
            out[id] = DrawIOFormat.Frame(
                x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height),
                fill: n.appearance.fill.representative.map(SVGExporter.hex), stroke: SVGExporter.hex(n.branchColor),
                shape: n.appearance.shape)
        }
        return out
    }

    /// The preview image for visual formats (scale 1 for speed; the size line shows the
    /// real output).
    public func exportPreview(_ s: ExportState) -> CGImage? {
        guard s.format.isVisual || s.format == .word || s.format == .powerpoint || s.format == .keynote else {
            return nil
        }
        var o = s.image
        o.scale = 1
        return ImageExporter.image(exportModel(s), canvas: canvasID, o)
    }

    /// "2880 × 1850 px · 412 KB".
    public func exportSizeLine(_ s: ExportState) -> String {
        switch s.format {
        case .png, .jpeg:
            let size = ImageExporter.pixelSize(exportModel, canvas: canvasID, s.image)
            let bytes = Int(size.width * size.height * (s.format == .png ? 0.33 : 0.12))
            return
                "\(Int(size.width)) × \(Int(size.height)) px · ~\(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
        case .pdf:
            let r = ImageExporter.contentRect(exportModel, canvas: canvasID, s.image)
            return
                "\(Int(r.width)) × \(Int(r.height)) pt · \(s.pdfScope == "all" ? exportModel.canvases.count : 1) page\(s.pdfScope == "all" && exportModel.canvases.count > 1 ? "s" : "")"
        default:
            if let t = exportText(s) {
                return
                    "\(t.split(separator: "\n").count) lines · \(ByteCountFormatter.string(fromByteCount: Int64(t.utf8.count), countStyle: .file))"
            }
            return ""
        }
    }

    /// The file for the chosen format.
    public func exportData(_ s: ExportState) -> Data? {
        let m = exportModel(s)
        switch s.format {
        case .png: return ImageExporter.image(m, canvas: canvasID, s.image).map(ImageExporter.png)
        case .jpeg:
            let matte = s.image.background == .transparent ? RGBA(r: 1, g: 1, b: 1, a: 1) : scene.canvasColor
            return ImageExporter.image(m, canvas: canvasID, s.image).map {
                ImageExporter.jpeg($0, quality: s.jpegQuality, matte: matte)
            }
        case .pdf:
            switch s.pdfScope {
            case "presentation": return SlideExporter.pdf(SlideExporter.renderSlides(m, canvas: canvasID))
            case "all":
                var o = s.image
                o.scope = .canvas
                let pages = m.canvasOrder.compactMap { ImageExporter.image(m, canvas: $0, o) }
                return Self.pdfPages(pages)
            default: return PrintLayout.singlePage(m, canvas: canvasID, s.image, links: prefs.bool("export.pdfLinks"))
            }
        case .word:
            var images: [CanvasID: (Data, Int, Int)] = [:]
            var o = s.image
            o.scope = .canvas
            o.scale = 2
            for id in m.canvasOrder {
                if let img = ImageExporter.image(m, canvas: id, o) {
                    images[id] = (ImageExporter.png(img), img.width, img.height)
                }
            }
            return WordFormat.export(m, images: images.mapValues { (png: $0.0, width: $0.1, height: $0.2) })
        case .powerpoint, .keynote:
            let slides = SlideExporter.renderSlides(m, canvas: canvasID)
            return SlideExporter.pptx(slides, titles: self.slides.filter { !$0.skipped }.map(\.title))
        default:
            return exportText(s).map { Data($0.utf8) }
        }
    }

    static func pdfPages(_ images: [CGImage]) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
            let ctx = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { return Data() }
        for img in images {
            var box = CGRect(x: 0, y: 0, width: CGFloat(img.width) / 2, height: CGFloat(img.height) / 2)
            ctx.beginPDFPage(
                [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            ctx.draw(img, in: box)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    public var exportFileName: String {
        let t = canvas.title.isEmpty ? canvas.nodes[canvas.root]?.text ?? "Map" : canvas.title
        return t.replacingOccurrences(of: "/", with: "-")
    }

    /// Export… (save panel in the app).
    public func runExport(_ s: ExportState) {
        s.remember(in: prefs.defaults)
        if s.split, s.format == .png || s.format == .jpeg, s.image.scope == .canvas {
            exportState = nil
            splitByBranch()
            return
        }
        guard let data = exportData(s) else {
            showToast("Nothing to export")
            return
        }
        let name =
            exportFileName
            + (s.image.scope == .branch
                ? " – " + (canvas.nodes[s.image.selection.first ?? canvas.root]?.text ?? "") : "")
        exportState = nil
        onSaveFile?(data, name + "." + (s.format == .json && s.yaml ? "yaml" : s.format.fileExt))
        if s.format == .keynote { showToast("Keynote opens this .pptx directly") }
    }

    /// Copy (the sheet's left button): an image or text on the clipboard.
    public func copyExport(_ s: ExportState) {
        s.remember(in: prefs.defaults)
        let pb = pasteboard
        pb.clearContents()
        if s.format.isVisual, s.format != .svg {
            if let img = ImageExporter.image(exportModel, canvas: canvasID, s.image) {
                pb.setData(ImageExporter.png(img), forType: .png)
                showToast("Copied image")
            }
        } else if let t = exportText(s) {
            pb.setString(t, forType: .string)
            showToast("Copied \(s.format.title)")
        }
    }

    // MARK: Split by branch, branch export (artboard 51)

    public func splitByBranch() {
        var o = exportState?.image ?? ImageExporter.Options()
        o.scale = max(o.scale, 2)
        let files = ImageExporter.splitByBranch(exportModel, canvas: canvasID, o)
        guard !files.isEmpty else {
            showToast("This canvas has no branches")
            return
        }
        onSaveFolder?(files.map { ($0.name, $0.png) })
    }

    public func exportBranch(_ format: ExportFormat) {
        var s = ExportState.remembered(format, prefs: prefs)
        s.image.scope = .branch
        s.image.selection = [selection.primary]
        runExport(s)
    }

    /// ⌃⌘C: the selection (or its branch) as an image; Map Shot owns ⌃⌘C while it's open.
    public func copyAsImage() {
        var o = ImageExporter.Options()
        o.scope = selection.nodes.count > 1 ? .selection : selection.primary == canvas.root ? .canvas : .branch
        o.selection = selection.nodes
        guard let img = ImageExporter.image(exportModel, canvas: canvasID, o) else { return }
        let pb = pasteboard
        pb.clearContents()
        pb.setData(ImageExporter.png(img), forType: .png)
        showToast("Copied as image")
    }

    public func copyAsMarkdown() {
        let pb = pasteboard
        pb.clearContents()
        let top = selection.primary == canvas.root ? nil : selection.primary
        pb.setString(MarkdownFormat.export(canvas, from: top), forType: .string)
        showToast("Copied as Markdown")
    }

    // MARK: Copy, cut and paste topics

    public func copySelection() {
        let ids = selection.nodes.filter { canvas.nodes[$0] != nil }
        guard !ids.isEmpty else { return }
        let f = canvas.fragment(ids)
        let pb = pasteboard
        pb.clearContents()
        pb.setData(CanonicalJSON.data(f.json), forType: .nexusFragment)
        var text = ""
        for top in f.nodes[f.root]?.children ?? [] { text += IndentedText.export(f, from: top) }
        pb.setString(text, forType: .string)
    }

    public func cutSelection() {
        copySelection()
        let ids = selection.nodes.filter { $0 != canvas.root }
        guard !ids.isEmpty else { return }
        perform("Cut", selectionAfter: { Selection($0) }) { e in try e.delete(ids) }
    }

    /// ⌘V: copied topics, Markdown, indented text, OPML or Mermaid become a branch under
    /// the selection (one undo); one line becomes a topic; an image goes on the topic.
    public func paste() {
        if mode == .edit { return }
        let pb = pasteboard
        let parent = selection.primary
        if let data = pb.data(forType: .nexusFragment), let v = try? CanonicalJSON.parse(data),
            let f = try? Canvas(json: v, path: "clipboard")
        {
            perform("Paste", selectionAfter: { (ids: [NodeID]) in Selection(primary: ids.first ?? parent, nodes: ids) })
            { e in
                try e.paste(f, under: parent)
            }
            return
        }
        if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let (ic, _) = Interchange.parsePasted(text) {
                var report = ImportReport(source: "Clipboard", format: "")
                let c = CanvasBuilder.build(ic, id: canvasID, report: &report)
                let f = ic.synthesizedRoot ? c.fragment(c.nodes[c.root]?.children ?? []) : c.fragment([c.root])
                perform(
                    "Paste Outline",
                    selectionAfter: { (ids: [NodeID]) in Selection(primary: ids.first ?? parent, nodes: ids) }
                ) { e in
                    try e.paste(f, under: parent)
                }
            } else {
                let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
                perform("Paste", selectionAfter: { Selection($0) }) { e in try e.addChild(of: parent, text: line) }
            }
            return
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type), let rep = NSBitmapImageRep(data: data),
                let png = rep.representation(using: .png, properties: [:])
            {
                setImage(png, ext: "png", size: CGSize(width: rep.pixelsWide, height: rep.pixelsHigh), on: parent)
                return
            }
        }
    }

    // MARK: Map Shot (⌃⌘M)

    public func openMapShot() {
        if mode == .edit { commitEdit() }
        let b = scene.bounds.insetBy(dx: -40, dy: -40)
        var r = b.isNull ? CGRect(x: -400, y: -250, width: 800, height: 500) : b
        let ratio = MapShotState.Aspect.sixteenTen.ratio!
        if r.width / r.height > ratio {
            let h = r.width / ratio
            r = CGRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h)
        } else {
            let w = r.height * ratio
            r = CGRect(x: r.midX - w / 2, y: r.minY, width: w, height: r.height)
        }
        mapShot = MapShotState(rect: r.integral)
    }

    public func closeMapShot() {
        mapShot = nil
        onRestoreFocus?()
    }

    /// Keeps the frame's ratio when an aspect is chosen.
    public func setMapShotAspect(_ a: MapShotState.Aspect) {
        guard var s = mapShot else { return }
        s.aspect = a
        if let k = a.ratio {
            let c = CGPoint(x: s.rect.midX, y: s.rect.midY)
            let w = max(s.rect.width, s.rect.height * k)
            s.rect = CGRect(x: c.x - w / 2, y: c.y - w / k / 2, width: w, height: w / k).integral
        }
        mapShot = s
    }

    /// The shot as PNG: the framed area with optional padding frame and shadow.
    public func mapShotImage(_ s: MapShotState) -> CGImage? {
        var o = ImageExporter.Options()
        o.scale = s.scale
        guard let shot = ImageExporter.image(exportModel, canvas: canvasID, o, crop: s.rect) else { return nil }
        guard s.padding > 0 || s.frame != "canvas" else { return shot }
        let k = CGFloat(s.scale)
        let pad = CGFloat(s.padding) * k
        let w = CGFloat(shot.width) + pad * 2
        let h = CGFloat(shot.height) + pad * 2
        guard
            let ctx = CGContext(
                data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return shot }
        switch s.frame {
        case "gradient":
            let colors = [RGBA(hex: "#C9C3F7").cgColor, RGBA(hex: "#BFE7E3").cgColor] as CFArray
            if let g = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])
            {
                ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
            }
        case "black":
            ctx.setFillColor(RGBA(hex: "#1D1D22").cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        default:
            ctx.setFillColor(scene.canvasColor.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        let inner = CGRect(x: pad, y: pad, width: CGFloat(shot.width), height: CGFloat(shot.height))
        if s.shadow && s.frame != "canvas" {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -6 * k), blur: 18 * k, color: CGColor(gray: 0, alpha: 0.25))
            ctx.setFillColor(scene.canvasColor.cgColor)
            ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 10 * k, cornerHeight: 10 * k, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        if s.frame != "canvas" {
            ctx.addPath(CGPath(roundedRect: inner, cornerWidth: 10 * k, cornerHeight: 10 * k, transform: nil))
            ctx.clip()
        }
        ctx.draw(shot, in: inner)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// Keyboard first: arrows move the frame (⇧ by 50), ⌥-arrows resize it, 1–5 pick an
    /// aspect, ↩ copy & save, ⌥↩ copy only, Esc cancels.
    func handleMapShotKey(_ chord: KeyChord) -> Bool {
        guard var s = mapShot else { return false }
        let step: CGFloat = chord.modifiers.contains(.shift) ? 50 : 10
        let resize = chord.modifiers.contains(.option)
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        switch chord.key {
        case .escape:
            closeMapShot()
            return true
        case .return:
            commitMapShot(copyOnly: chord.modifiers.contains(.option))
            return true
        case .left: dx = -step
        case .right: dx = step
        case .up: dy = -step
        case .down: dy = step
        case .character(let c) where ("1"..."5").contains(c):
            setMapShotAspect(MapShotState.Aspect.allCases[Int(String(c))! - 1])
            return true
        default:
            return chord.modifiers.contains(.command) ? false : true
        }
        if resize {
            var w = max(80, s.rect.width + dx * 2)
            var h = max(60, s.rect.height + dy * 2)
            if let k = s.aspect.ratio { if dx != 0 { h = w / k } else { w = h * k } }
            s.rect = CGRect(x: s.rect.midX - w / 2, y: s.rect.midY - h / 2, width: w, height: h).integral
        } else {
            s.rect = s.rect.offsetBy(dx: dx, dy: dy)
        }
        mapShot = s
        return true
    }

    public func setMapShot(_ s: MapShotState) { mapShot = s }

    /// ↩ copies and saves to the Map Shot folder; ⌥↩ copies only.
    public func commitMapShot(copyOnly: Bool = false) {
        guard let s = mapShot, let img = mapShotImage(s) else { return }
        let png = ImageExporter.png(img)
        let pb = pasteboard
        pb.clearContents()
        pb.setData(png, forType: .png)
        mapShot = nil
        onRestoreFocus?()
        if copyOnly {
            showToast("Map Shot copied")
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            onSaveMapShot?(png, "Map Shot \(f.string(from: Date())).png")
        }
    }

    // MARK: Print (⌘P)

    public func openPrint(branch: Bool = false) {
        if mode == .edit { commitEdit() }
        var o = PrintLayout.Options()
        // Settings › Export › PDF & print.
        o.content = prefs.string("export.pdfContent") == "outline" ? .outline : .canvas
        o.paper = PrintLayout.Paper(rawValue: prefs.string("export.pageSize")) ?? .a4
        o.fitPage = prefs.string("export.pdfFit") == "fit"
        o.tile = prefs.string("export.pdfFit") == "tile"
        o.notesAppendix = prefs.bool("export.notesAppendix")
        if branch, selection.primary != canvas.root {
            o.content = .branch
            o.branch = selection.primary
        }
        o.branch = o.branch ?? (selection.primary == canvas.root ? nil : selection.primary)
        printState = o
    }

    public func closePrint() {
        printState = nil
        onRestoreFocus?()
    }

    public func printPDF(_ o: PrintLayout.Options) -> (data: Data, pages: Int) {
        PrintLayout.pdf(exportModel, canvas: canvasID, o)
    }

    public func runPrint(_ o: PrintLayout.Options, savePDF: Bool = false) {
        let (data, _) = printPDF(o)
        printState = nil
        if savePDF { onSaveFile?(data, exportFileName + ".pdf") } else { onPrintPDF?(data, exportFileName) }
    }

    // MARK: Merge (Tools › Merge…, artboard 50)

    public func openMerge() {
        if mode == .edit { commitEdit() }
        mergeState = MergeState()
    }

    public func closeMerge() {
        mergeState = nil
        onRestoreFocus?()
    }

    /// Reads a document chosen in the merge sheet (.nexus, .xmind, OPML, Markdown and the
    /// other importable formats).
    public func addMergeSource(_ url: URL) {
        guard mergeState != nil else { return }
        do {
            let name = url.lastPathComponent
            var files: [String: Data]?
            var data: Data?
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let w = try FileWrapper(url: url, options: .immediate)
                files = Self.flatten(w)
            } else {
                data = try Data(contentsOf: url)
            }
            let im = try Interchange.importFile(name: name, data: data, files: files)
            let fmt = InterchangeFormat.detect(name: name)
            let topics = im.canvases.reduce(0) { $0 + $1.nodes.count }
            let detail: String =
                switch fmt {
                case .nexus?:
                    "\(topics) \(topics == 1 ? "topic" : "topics") · \(im.canvases.count) canvas\(im.canvases.count == 1 ? "" : "es")"
                case .markdown?: "\(im.canvases.first.map { $0.nodes.count - 1 } ?? 0) headings"
                default: "\(topics) \(topics == 1 ? "topic" : "topics") · \(fmt?.title ?? "") import"
                }
            let kind: String =
                switch fmt {
                case .nexus?: "NX"
                case .xmind?: "XM"
                case .markdown?: "MD"
                case .opml?: "OP"
                default: String((fmt?.title ?? "??").prefix(2)).uppercased()
                }
            mergeState?.sources.removeAll { $0.name == name }
            mergeState?.sources.append(
                MergeSource(name: name, kind: kind, detail: detail, canvases: im.canvases, assets: im.assets))
        } catch {
            showToast("\(url.lastPathComponent): \(error)")
        }
    }

    static func flatten(_ w: FileWrapper, prefix: String = "") -> [String: Data] {
        var out: [String: Data] = [:]
        for (name, child) in w.fileWrappers ?? [:] {
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            if child.isDirectory {
                out.merge(flatten(child, prefix: path)) { a, _ in a }
            } else if let d = child.regularFileContents {
                out[path] = d
            }
        }
        return out
    }

    public func removeMergeSource(_ name: String) { mergeState?.sources.removeAll { $0.name == name } }

    /// Merge · one undo.
    public func applyMerge() {
        guard let m = mergeState, !m.sources.isEmpty else { return }
        mergeState = nil
        if m.intoThisCanvas {
            let target = canvas.root
            let incoming = m.sources.flatMap(\.canvases)
            for s in m.sources {
                for (k, v) in s.assets where store.model.assets[k] == nil { store.updateDocument { $0.assets[k] = v } }
            }
            perform(
                "Merge Documents",
                selectionAfter: { (ids: [NodeID]) in Selection(primary: ids.first ?? target, nodes: ids) }
            ) { e in
                var out: [NodeID] = []
                for c in incoming {
                    out.append(try e.graft(c, top: c.root, under: target))
                    for f in c.floating { out.append(try e.graft(c, top: f, under: target)) }
                }
                return out
            }
            showToast("Merged \(m.sources.count) document\(m.sources.count == 1 ? "" : "s") into this canvas")
            return
        }
        var focus = canvasID
        store.commitDocument("Merge Documents", focus: canvasID) { d in
            var added: [CanvasID] = []
            for s in m.sources { added += d.add(s.canvases, assets: s.assets) }
            if m.mapOfContent, !added.isEmpty {
                var index = Canvas(id: "moc", title: "Map of Content", rootText: "Map of Content")
                var undo = UndoStack()
                index.edit("Index", undo: &undo) { e in
                    for id in added {
                        guard let c = d.canvases[id] else { continue }
                        let t = try! e.addChild(of: e.canvas.root, text: c.nodes[c.root]?.text ?? c.title)
                        e.update(t) { $0.link = TopicLink.make(canvas: id, node: c.root) }
                    }
                }
                let ids = d.add([index])
                focus = ids[0]
            } else if let first = added.first {
                focus = first
            }
        }
        if focus != canvasID { switchCanvas(to: focus) }
        showToast("Merged \(m.sources.count) document\(m.sources.count == 1 ? "" : "s") · one undo")
    }

    // MARK: Canvas tab menu (artboard 50)

    /// ⌥⌘N: the selected topic's branch as a new canvas (the original stays).
    public func newCanvasFromTopic() {
        let id = selection.primary
        guard let n = canvas.nodes[id] else { return }
        let src = canvas
        var target = CanvasID("")
        store.commitDocument("New Canvas from Topic", focus: canvasID) { d in
            var c = Canvas(id: "tmp", title: n.text, type: src.type, rootText: n.text)
            c.style = src.style
            var undo = UndoStack()
            c.edit("Copy", undo: &undo) { e in
                for ch in n.children { _ = try? e.graft(src, top: ch, under: e.canvas.root) }
                e.update(e.canvas.root) {
                    $0.note = n.note
                    $0.markers = n.markers
                    $0.labels = n.labels
                }
            }
            let at = d.canvasOrder.firstIndex(of: src.id)
            target = d.add([c], after: at)[0]
        }
        switchCanvas(to: target)
    }

    public func duplicateCanvas() {
        let src = canvas
        var target = CanvasID("")
        store.commitDocument("Duplicate Canvas", focus: canvasID) { d in
            var c = src
            c.title = (src.title.isEmpty ? src.nodes[src.root]?.text ?? "Map" : src.title) + " copy"
            target = d.add([c], after: d.canvasOrder.firstIndex(of: src.id))[0]
        }
        switchCanvas(to: target)
    }

    public func renameCanvas(_ title: String) {
        perform("Rename Canvas") { e in e.updateMeta { $0.title = title } }
    }

    /// Delete canvas…: one undo; the last canvas can't go.
    public func deleteCanvas(_ id: CanvasID? = nil) {
        let id = id ?? canvasID
        guard store.model.canvases.count > 1 else {
            showToast("A document keeps at least one canvas")
            return
        }
        let order = store.model.canvasOrder
        let next =
            order.firstIndex(of: id).flatMap { i in i + 1 < order.count ? order[i + 1] : i > 0 ? order[i - 1] : nil }
            ?? order.first!
        store.commitDocument("Delete Canvas", focus: next) { d in
            d.canvases[id] = nil
            d.canvasOrder.removeAll { $0 == id }
        }
        if canvasID != next, store.canvas(canvasID) == nil { switchCanvas(to: next) }
    }

    public func copyCanvas() {
        let pb = pasteboard
        pb.clearContents()
        pb.setData(CanonicalJSON.data(canvas.json), forType: .nexusCanvas)
        pb.setString(MarkdownFormat.export(canvas), forType: .string)
        showToast("Canvas copied")
    }

    public var canPasteCanvas: Bool { pasteboard.data(forType: .nexusCanvas) != nil }

    public func pasteCanvas() {
        guard let data = pasteboard.data(forType: .nexusCanvas), let v = try? CanonicalJSON.parse(data),
            let c = try? Canvas(json: v, path: "clipboard")
        else { return }
        var target = CanvasID("")
        store.commitDocument("Paste Canvas", focus: canvasID) { d in
            target = d.add([c], after: d.canvasOrder.firstIndex(of: canvasID))[0]
        }
        switchCanvas(to: target)
    }

    /// Save canvas as document…: a one-canvas document (the app shows the save panel).
    public func saveCanvasAsDocument() {
        var doc = DocumentModel(canvases: [canvas], theme: store.model.theme)
        let used = Set(
            canvas.nodes.values.flatMap { n in
                [n.image?.asset, n.sticker?.asset, n.audio?.asset].compactMap { $0 } + n.attachments.map(\.asset)
            })
        doc.assets = store.model.assets.filter { used.contains($0.key) }
        onSaveDocument?(doc, exportFileName)
    }

    // MARK: Import report (artboard 33)

    public func showImportReport(_ r: ImportReport) { importReport = r }
    public func closeImportReport() { importReport = nil }
}

// MARK: Remembered settings

extension ExportState {
    static let defaultsKey = "export.lastSettings"
    static func lastFormat(in store: UserDefaults) -> ExportFormat {
        ExportFormat(rawValue: store.string(forKey: "export.lastFormat") ?? "") ?? .png
    }

    /// The last settings used for `format` (artboard 30: "remembered per format").
    @MainActor static func remembered(
        _ format: ExportFormat, keeping current: ExportState? = nil, prefs: Preferences = .shared
    ) -> ExportState {
        var s = current ?? ExportState()
        s.format = format
        // Settings › Export are the defaults until a format remembers its own.
        s.image.scale = Double(prefs.string("export.scale")) ?? 2
        s.image.background = ImageExporter.Background(rawValue: prefs.string("export.background")) ?? .theme
        s.image.padding = prefs.number("export.padding")
        s.image.frame = prefs.string("export.frame")
        s.image.aspect = prefs.string("export.aspect")
        s.image.mat = RGBA(hex: prefs.string("export.matColor"))
        s.image.displayP3 = prefs.string("export.colorProfile") == "displayP3"
        s.markdown.headings = prefs.string("export.markdown") != "bullets"
        s.markdown.notes = prefs.bool("export.markdownNotes")
        s.markdown.mermaidBlock = prefs.bool("export.markdownMermaid")
        let flavour = prefs.string("export.flavour")
        s.mermaid = flavour == "auto" ? nil : MermaidFormat.Flavour(rawValue: flavour)
        s.prettyJSON = prefs.string("export.json") != "compact"
        s.split = prefs.bool("export.split")
        let masking = prefs.string("export.masking")
        s.mask = masking == "always" || (masking == "ask" && (current?.mask ?? false))
        s.askMask = masking == "ask"
        let d = prefs.defaults.dictionary(forKey: "\(defaultsKey).\(format.rawValue)") ?? [:]
        if let v = d["scope"] as? String, let sc = ImageExporter.Scope(rawValue: v) { s.image.scope = sc }
        if let v = d["scale"] as? Double { s.image.scale = v }
        if let v = d["background"] as? String, let b = ImageExporter.Background(rawValue: v) { s.image.background = b }
        if let v = d["padding"] as? Double { s.image.padding = v }
        s.image.theme = d["theme"] as? String
        if let v = d["quality"] as? Double { s.jpegQuality = v }
        if let v = d["outline"] as? Bool { s.svg.outlineText = v }
        if let v = d["metadata"] as? Bool { s.svg.metadata = v }
        if let v = d["flavour"] as? String { s.mermaid = MermaidFormat.Flavour(rawValue: v) }
        if let v = d["headings"] as? Bool { s.markdown.headings = v }
        if let v = d["notes"] as? Bool { s.markdown.notes = v }
        if let v = d["mermaidBlock"] as? Bool { s.markdown.mermaidBlock = v }
        if let v = d["yaml"] as? Bool { s.yaml = v }
        if let v = d["pretty"] as? Bool { s.prettyJSON = v }
        if let v = d["pdfScope"] as? String { s.pdfScope = v }
        return s
    }

    /// Per-format choices live beside the preferences, so tests stay isolated.
    func remember(in store: UserDefaults) {
        var d: [String: Any] = [
            "scope": image.scope.rawValue, "scale": image.scale, "background": image.background.rawValue,
            "padding": image.padding, "quality": jpegQuality, "outline": svg.outlineText, "metadata": svg.metadata,
            "headings": markdown.headings, "notes": markdown.notes, "mermaidBlock": markdown.mermaidBlock, "yaml": yaml,
            "pretty": prettyJSON, "pdfScope": pdfScope,
        ]
        if let t = image.theme { d["theme"] = t }
        if let f = mermaid { d["flavour"] = f.rawValue }
        store.set(d, forKey: "\(Self.defaultsKey).\(format.rawValue)")
        store.set(format.rawValue, forKey: "export.lastFormat")
    }
}
