import NexusCanvas
import NexusCore
import NexusKeys
import UIKit

@testable import NexusTouch

/// The repository's root, read in place: the simulator runs on this Mac, so the tests
/// compare against the Mac's committed goldens and fixtures without copying them.
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

/// The NS artboard's sample map (the Mac's `nodeStyleSampleDocument`).
func nodeStyleSampleDocument(theme: String, style: String) -> DocumentModel {
    var c = NexusCore.Canvas(id: "c1", title: "Launch plan", rootText: "Launch plan")
    c.layout.structure = .logicRight
    c.style.theme = theme
    c.style.nodeStyle = style
    var undo = UndoStack()
    c.edit("Sample", undo: &undo) { e in
        let tree: [(String, [String])] = [
            ("Positioning", ["Devs", "Teams"]), ("Pricing", ["Free"]), ("Channels", []), ("Timeline", []),
        ]
        for (m, subs) in tree {
            let id = try! e.addChild(of: e.canvas.root, text: m)
            for s in subs { try! e.addChild(of: id, text: s) }
        }
    }
    return DocumentModel(canvases: [c])
}

/// A touch canvas on a document, as the Mac's `CanvasHarness` is: a memory host, named
/// themes whatever the appearance, no motion, keys through `pressesBegan`'s own path.
@MainActor
final class TouchHarness {
    let store: DocumentStore
    let undo = StackUndoRegistrar()
    let controller: CanvasController
    let view: TouchCanvasView

    init(model: DocumentModel = .blank(), width: CGFloat = 1032, height: CGFloat = 800) {
        store = DocumentStore(model: model)
        store.undoRegistrar = undo
        controller = CanvasController(store: store)
        controller.host = MemoryCanvasHost()
        let prefs = Preferences.isolated()
        prefs.set("appearance.followSystem", false)
        controller.prefs = prefs
        view = TouchCanvasView(controller: controller)
        view.reduceMotionOverride = true
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        view.layoutIfNeeded()
        // Undo and redo are the window's, as the document screen runs them (⌘Z, ⇧⌘Z).
        view.onWindowCommand = { [store, undo] id in
            switch id {
            case .undo: undo.undo(store)
            case .redo: undo.redo(store)
            default: false
            }
        }
    }

    /// One chord as the canvas's `pressesBegan` takes it (the window's commands included).
    @discardableResult
    func key(_ spec: String) -> Bool {
        guard let chord = KeyChord(spec) else { fatalError("bad key \(spec)") }
        let chars: String? =
            switch chord.key {
            case .character(let c): String(c)
            default: nil
            }
        return view.handle(chord, characters: chars)
    }

    var canvas: NexusCore.Canvas { controller.canvas }

    func text(_ id: NodeID) -> String { canvas.nodes[id]?.text ?? "∅" }

    /// One chord through the controller, as a hardware key reaches it.
    @discardableResult
    func press(_ spec: String) -> CanvasController.KeyResult {
        guard let chord = KeyChord(spec) else { fatalError("bad key \(spec)") }
        let chars: String? =
            switch chord.key {
            case .character(let c): String(c)
            default: nil
            }
        return controller.handleKey(chord, characters: chars)
    }

    /// Types into the open editor, as the keyboard does.
    func type(_ text: String) {
        controller.editorTextDidChange(text)
    }
}

/// Pixel comparison with tolerance for anti-aliasing (the Mac's `ImageDiff`).
enum ImageDiff {
    struct Result {
        var sizeMatches: Bool
        var meanDelta: Double
        var changedFraction: Double
    }

    static func compare(_ a: CGImage, _ b: CGImage) -> Result {
        guard a.width == b.width, a.height == b.height, let pa = rgba(a), let pb = rgba(b) else {
            return Result(sizeMatches: false, meanDelta: 1, changedFraction: 1)
        }
        var total = 0
        var changed = 0
        let n = pa.count / 4
        for i in 0..<n {
            let d =
                (abs(Int(pa[i * 4]) - Int(pb[i * 4])) + abs(Int(pa[i * 4 + 1]) - Int(pb[i * 4 + 1]))
                    + abs(Int(pa[i * 4 + 2]) - Int(pb[i * 4 + 2]))) / 3
            total += d
            if d > 30 { changed += 1 }
        }
        return Result(
            sizeMatches: true, meanDelta: Double(total) / Double(n) / 255,
            changedFraction: Double(changed) / Double(n))
    }

    /// Redraws an image into one canonical sRGB RGBA8 buffer.
    static func rgba(_ cg: CGImage) -> [UInt8]? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = cg.width
        let h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard
                let ctx = CGContext(
                    data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? buf : nil
    }
}
