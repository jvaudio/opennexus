import AppKit
import Foundation
import SwiftUI
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusTheme

/// The NS artboard's sample map.
func nodeStyleSampleDocument(theme: String, style: String) -> DocumentModel {
    var c = Canvas(id: "c1", title: "Launch plan", rootText: "Launch plan")
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

@MainActor
@Suite(.serialized) struct StyleSnapshotTests {
    /// Renders 9 node styles × 4 required themes into a contact sheet for review.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"] != nil))
    func styleMatrixContactSheet() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"]!)
        var tiles: [[NSImage]] = []
        for theme in Theme.required {
            var row: [NSImage] = []
            for style in NodeStyle.allCases {
                let h = CanvasHarness(
                    model: nodeStyleSampleDocument(theme: theme.id, style: style.rawValue), width: 560,
                    height: 340)
                h.host.canvasView.fitToWindow()
                h.controller.select(h.canvas.nodes[h.canvas.root]!.children[1])
                let url = dir.appendingPathComponent("ns-\(theme.id)-\(style.rawValue).png")
                h.snapshot(to: url)
                if let img = NSImage(contentsOf: url) { row.append(img) }
                h.window.orderOut(nil)
            }
            tiles.append(row)
        }
        // Compose a contact sheet: themes as rows, styles as columns.
        let tw: CGFloat = 560
        let th: CGFloat = 340
        let sheet = NSImage(size: CGSize(width: tw * 9, height: th * CGFloat(tiles.count)))
        sheet.lockFocus()
        for (r, row) in tiles.enumerated() {
            for (c, img) in row.enumerated() {
                img.draw(in: CGRect(x: CGFloat(c) * tw, y: CGFloat(tiles.count - 1 - r) * th, width: tw, height: th))
            }
        }
        sheet.unlockFocus()
        if let tiff = sheet.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("ns-sheet.png"))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"] != nil))
    func formatPanelSnapshots() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"]!)
        let h = CanvasHarness(model: nodeStyleSampleDocument(theme: "classic", style: "outline"))
        h.controller.select(h.canvas.nodes[h.canvas.root]!.children[1])
        for tab in ["style", "map", "data"] {
            UserDefaults.standard.set(tab, forKey: "format.tab")
            let panel = NSHostingView(rootView: FormatPanel(controller: h.controller))
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 330, height: 1000), styleMask: [.borderless],
                backing: .buffered, defer: false)
            w.contentView = panel
            w.appearance = NSAppearance(named: .aqua)
            w.setFrameOrigin(NSPoint(x: 900, y: 0))
            w.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", dir.appendingPathComponent("panel-\(tab).png").path]
            try p.run()
            p.waitUntilExit()
            w.orderOut(nil)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"] != nil))
    func offscreenProbe() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"]!)
        let h = CanvasHarness(
            model: nodeStyleSampleDocument(theme: "classic", style: "brutal"), width: 560, height: 340)
        h.host.canvasView.fitToWindow()
        let rep = try #require(h.renderOffscreen(scale: 2))
        try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("offscreen.png"))
    }
}
