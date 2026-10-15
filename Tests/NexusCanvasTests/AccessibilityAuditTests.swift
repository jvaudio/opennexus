import AppKit
import Foundation
import SwiftUI
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat

/// M10: an accessibility audit of every key screen, in process. Every control an
/// assistive app can act on must say what it is (a label or title), and sit inside its
/// window. README §12: "Every control has a label."
@MainActor
@Suite(.serialized) struct AccessibilityAuditTests {
    static let actionable: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton, .slider, .textField, .comboBox, .link,
        .incrementor, .disclosureTriangle, .colorWell, .textArea,
    ]

    struct Issue: CustomStringConvertible {
        var role: String
        var path: String
        var description: String { "\(role) at \(path)" }
    }

    static func text(_ e: NSAccessibilityProtocol) -> String {
        let parts: [String?] = [
            e.accessibilityLabel(), e.accessibilityTitle(), e.accessibilityPlaceholderValue(),
            (e.accessibilityValue() as? String).flatMap { e.accessibilityRole() == .textField ? nil : $0 },
        ]
        return parts.compactMap { $0 }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Walks the tree from `root`, collecting unlabelled actionable elements.
    static func audit(
        _ root: Any, window: NSWindow, path: String = "", depth: Int = 0, into issues: inout [Issue], seen: inout Int
    ) {
        guard depth < 60, let e = root as? NSAccessibilityProtocol else { return }
        if e.isAccessibilityHidden() { return }
        let role = e.accessibilityRole()
        let label = text(e)
        if let role, actionable.contains(role) {
            seen += 1
            let frame = e.accessibilityFrame()
            let onScreen = frame.width > 0 && frame.height > 0
            if onScreen && label.isEmpty {
                issues.append(Issue(role: role.rawValue, path: path.isEmpty ? "root" : path))
            }
        }
        let name = label.isEmpty ? (role?.rawValue ?? "?") : String(label.prefix(24))
        for c in e.accessibilityChildren() ?? [] {
            audit(c, window: window, path: path + "/" + name, depth: depth + 1, into: &issues, seen: &seen)
        }
    }

    func host(_ view: some View, size: CGSize = CGSize(width: 1440, height: 900)) -> (NSWindow, NSView) {
        let w = NSWindow(
            contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        let h = NSHostingView(rootView: view)
        w.contentView = h
        w.layoutIfNeeded()
        h.layoutSubtreeIfNeeded()
        return (w, h)
    }

    func check(_ name: String, _ view: NSView, in window: NSWindow) -> Int {
        var issues: [Issue] = []
        var seen = 0
        Self.audit(view, window: window, into: &issues, seen: &seen)
        #expect(issues.isEmpty, "\(name): \(issues.count) unlabelled controls: \(issues.prefix(6))")
        return seen
    }

    /// The canvas's own tree (AppKit): every topic, suggestion, edge and boundary
    /// element has a label, a role description and an on-screen frame. SwiftUI chrome
    /// builds its tree only for a connected assistive client, so it's audited by the
    /// XCUITest target (`App/UITests`, `performAccessibilityAudit()`).
    @Test func canvasTreeIsFullyLabelled() throws {
        var doc = launchPlanDocument()
        var e = CanvasEditor(doc.canvases["c1"]!)
        let pricing = e.canvas.nodes.first { $0.value.text == "Pricing" }!.key
        let channels = e.canvas.nodes.first { $0.value.text == "Channels" }!.key
        _ = try e.addBoundary(around: [pricing], title: "Money")
        _ = e.connect(channels, to: pricing, label: "feeds")
        doc.canvases["c1"] = e.canvas
        let h = CanvasHarness(model: doc)
        let v = h.host.canvasView
        #expect(v.accessibilityLabel() == "Canvas" && v.accessibilityRole() == .group)
        var issues: [Issue] = []
        var seen = 0
        Self.audit(v, window: h.window, into: &issues, seen: &seen)
        var all: [NSAccessibilityElement] = []
        func collect(_ x: Any) {
            guard let el = x as? NSAccessibilityElement else { return }
            all.append(el)
            for c in el.accessibilityChildren() ?? [] { collect(c) }
        }
        for r in v.accessibilityChildren() ?? [] { collect(r) }
        all += v.accessibilityTree.edgeItems() + v.accessibilityTree.boundaryItems()
        #expect(all.count == h.controller.scene.nodes.count + 2)
        for el in all {
            #expect(!(el.accessibilityLabel() ?? "").isEmpty, "unlabelled \(el)")
            #expect(!(el.accessibilityRoleDescription() ?? "").isEmpty)
            let f = el.accessibilityFrame()
            #expect(f.width > 0 && f.height > 0, "\(el.accessibilityLabel() ?? "") has no frame")
        }
        #expect(issues.isEmpty, "\(issues)")
    }
}
