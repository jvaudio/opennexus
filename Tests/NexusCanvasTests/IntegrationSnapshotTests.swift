import AppKit
import Foundation
import SwiftUI
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusWidgetsUI

/// Visual review of M9 against artboards 33 (Quick Capture, widgets) and 40 (Settings ›
/// Integrations). Env-gated by NEXUS_SNAPSHOT_DIR.
@MainActor
@Suite(.serialized) struct IntegrationSnapshotTests {
    nonisolated static var dir: URL? {
        ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    func shoot(_ view: some View, _ name: String, size: CGSize) async throws {
        let w = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 40, y: 40), size: size), styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        w.appearance = NSAppearance(named: .aqua)
        w.contentView = NSHostingView(rootView: view)
        w.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(900))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", Self.dir!.appendingPathComponent("m9-\(name).png").path]
        try? p.run()
        p.waitUntilExit()
        w.orderOut(nil)
    }

    @Test(.enabled(if: dir != nil)) func quickCaptureAndWidgets() async throws {
        let model = QuickCaptureModel(
            targets: CaptureTargets(recents: [URL(fileURLWithPath: "/m/Product ideas.nexus")]))
        model.text = "Try a pricing page A/B test"
        let capture = ZStack {
            LinearGradient(
                colors: [Color(hex: "#9AA7E6"), Color(hex: "#C7B2E2"), Color(hex: "#EEC6B3")], startPoint: .topLeading,
                endPoint: .bottomTrailing)
            QuickCaptureView(model: model)
        }
        try await shoot(capture, "33-quick-capture", size: CGSize(width: 860, height: 460))

        let snap = WidgetSnapshot(
            inbox: ["A/B pricing page", "Webhook retries"], inboxCount: 7,
            recents: [
                .init(token: "a", title: "Checkout DFD", detail: "Data Flow · 18 topics", thumbnail: nil),
                .init(token: "b", title: "Q1 roadmap", detail: "Timeline · 48 topics", thumbnail: nil),
            ])
        var thumbs: [String: NSImage] = [:]
        if let png = HeadlessExport.previewPNG(launchPlanDocument(), maxWidth: 400), let img = NSImage(data: png) {
            thumbs["a"] = img
            thumbs["b"] = img
        }
        let widgets = HStack(spacing: 22) {
            InboxWidgetView(snapshot: snap, compact: true).padding(16).frame(width: 170, height: 170)
                .background(InboxWidgetView.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            RecentMapsWidgetView(snapshot: snap, thumbnails: thumbs, large: false).padding(16).frame(
                width: 330, height: 170
            )
            .background(RecentMapsWidgetView.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Color(hex: "#2A3350"), Color(hex: "#1B2036")], startPoint: .top, endPoint: .bottom))
        try await shoot(widgets, "33-widgets", size: CGSize(width: 620, height: 240))
    }

    @Test(.enabled(if: dir != nil)) func integrationsPane() async throws {
        let p = Preferences.isolated()
        p.set("integrations.mcp", true)
        p.set("integrations.captureAtLogin", true)
        AgentFolders.set(["/Users/x/Maps", "/Users/x/Notes"], p)
        try await shoot(
            SettingsView(prefs: p, availability: .ready, pane: "integrations"), "40-integrations",
            size: CGSize(width: 1440, height: 900))
    }
}
