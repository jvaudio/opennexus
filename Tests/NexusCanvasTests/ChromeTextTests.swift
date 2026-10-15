import AppKit
import Foundation
import SwiftUI
import Testing

@testable import NexusCanvas
@testable import NexusCore

/// M10: Dynamic Type for the chrome.
@MainActor
@Suite(.serialized) struct ChromeTextTests {
    func height(_ view: some View, width: CGFloat) -> CGFloat {
        let h = NSHostingView(rootView: view.frame(width: width))
        h.layoutSubtreeIfNeeded()
        return h.fittingSize.height
    }

    @Test func chromeScalesAndClamps() {
        defer { ChromeText.shared.scale = 1 }
        ChromeText.apply(followSystem: false)
        #expect(ChromeText.shared.scale == 1)
        ChromeText.apply(followSystem: true)
        #expect(ChromeText.range.contains(ChromeText.shared.scale))
        // Real screens grow with the scale (nothing is pinned to fixed point sizes).
        // Fonts are computed in body, so build the view after setting the scale.
        func row() -> some View {
            VStack(alignment: .leading) {
                Text("Global shortcut").font(.chrome(13.5))
                Text("Lives in the menu bar").font(.chrome(11.5))
            }
        }
        ChromeText.shared.scale = 1
        let base = height(row(), width: 400)
        ChromeText.shared.scale = 1.5
        #expect(height(row(), width: 400) > base * 1.3)
        ChromeText.shared.scale = 1
        let settings = height(SettingsView(prefs: .isolated(), availability: .ready, pane: "general"), width: 1240)
        ChromeText.shared.scale = 1.4
        #expect(
            height(SettingsView(prefs: .isolated(), availability: .ready, pane: "general"), width: 1240) >= settings)
    }

    nonisolated static var dir: URL? {
        ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    /// For review: screens at 1.3× and 1.6× must not clip or overlap.
    @Test(.enabled(if: dir != nil)) func largeTextSnapshots() async throws {
        defer { ChromeText.shared.scale = 1 }
        for scale in [1.3, 1.6] as [CGFloat] {
            ChromeText.shared.scale = scale
            let screens: [(String, AnyView, CGSize)] = [
                (
                    "general", AnyView(SettingsView(prefs: .isolated(), availability: .ready, pane: "general")),
                    CGSize(width: 1440, height: 900)
                ),
                (
                    "accessibility",
                    AnyView(SettingsView(prefs: .isolated(), availability: .ready, pane: "accessibility")),
                    CGSize(width: 1440, height: 900)
                ),
                ("home", AnyView(HomeView(model: HomeModel())), CGSize(width: 1440, height: 900)),
            ]
            for (name, view, size) in screens {
                let w = NSWindow(
                    contentRect: CGRect(origin: CGPoint(x: 40, y: 40), size: size), styleMask: [.titled],
                    backing: .buffered, defer: false)
                w.appearance = NSAppearance(named: .aqua)
                w.contentView = NSHostingView(rootView: view)
                w.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(700))
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = [
                    "-x", "-o", "-l", "\(w.windowNumber)",
                    Self.dir!.appendingPathComponent("m10-text-\(scale)-\(name).png").path,
                ]
                try? p.run()
                p.waitUntilExit()
                w.orderOut(nil)
            }
        }
    }
}

@MainActor
@Suite(.serialized) struct ReduceMotionTests {
    /// Settings › Accessibility › Reduce motion turns chrome animations off (and System
    /// defers to macOS).
    @Test func chromeAnimationsFollowTheSetting() {
        let p = Preferences.shared
        let old = p.string("accessibility.reduceMotion")
        defer { p.set("accessibility.reduceMotion", old) }
        p.set("accessibility.reduceMotion", "on")
        #expect(UIMotion.reduce && UIMotion.animation(.default) == nil)
        p.set("accessibility.reduceMotion", "off")
        #expect(!UIMotion.reduce && UIMotion.animation(.default) != nil)
        p.set("accessibility.reduceMotion", "system")
        #expect(UIMotion.reduce == NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    /// No SwiftUI animation in the chrome bypasses UIMotion.
    @Test func everyChromeAnimationIsGated() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Sources/NexusCanvas")
        var ungated: [String] = []
        for f in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        where f.pathExtension == "swift" {
            let lines = try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n")
            for (i, l) in lines.enumerated()
            where (l.contains("withAnimation(") || l.contains(".animation(.")) && !l.contains("UIMotion") {
                ungated.append("\(f.lastPathComponent):\(i + 1)")
            }
        }
        #expect(ungated.isEmpty, "\(ungated)")
    }
}
