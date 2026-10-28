import AppKit
import Foundation
import SwiftUI
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat

/// Visual review of Settings (08, 29, 35–42), Welcome (14), roles (15), Home (16) and the
/// tutorial (31) against their artboards (env-gated).
@MainActor
@Suite(.serialized) struct SettingsSnapshotTests {
    nonisolated static var dir: URL? {
        ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    func shoot(
        _ view: some View, _ name: String, size: CGSize = CGSize(width: 1440, height: 900), dark: Bool = false
    ) async throws {
        let w = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: 40, y: 40), size: size), styleMask: [.titled], backing: .buffered,
            defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = NSHostingView(rootView: view)
        w.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(900))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(w.windowNumber)", Self.dir!.appendingPathComponent("m8-\(name).png").path]
        try? p.run()
        p.waitUntilExit()
        // Without Screen Recording, draw the window's view instead.
        let url = Self.dir!.appendingPathComponent("m8-\(name).png")
        if !FileManager.default.fileExists(atPath: url.path), let v = w.contentView,
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)
        {
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        w.orderOut(nil)
    }

    @Test(.enabled(if: dir != nil)) func panes() async throws {
        for (id, art) in [
            ("general", "35"), ("editing", "36"), ("appearance", "37"), ("files", "38"), ("ai", "29"),
            ("shortcuts", "08"),
            ("export", "39"), ("integrations", "40"), ("privacy", "41"), ("accessibility", "42"),
        ] {
            try await shoot(SettingsView(prefs: .isolated(), availability: .ready, pane: id), "\(art)-\(id)")
        }
    }

    @Test(.enabled(if: dir != nil)) func onboardingAndHome() async throws {
        try await shoot(
            WelcomeView(onTour: {}, onSkip: {}, onImport: {}), "14-welcome", size: CGSize(width: 1180, height: 760),
            dark: true)
        try await shoot(
            RolePickerView(initial: .security, onContinue: { _ in }, onSkip: { _ in }), "15-roles",
            size: CGSize(width: 1180, height: 760))
        // Home with a few real recents.
        let tmp = FileManager.default.temporaryDirectory.appending(path: "home-shot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var urls: [URL] = []
        for (id, name) in [
            ("threat", "Payments threat model"), ("c4", "Checkout system context"), ("bookNotes", "Reading notes"),
            ("retro", "Sprint 42 retro"),
        ] {
            guard let t = StarterLibrary.starter(id) else { continue }
            let u = tmp.appending(path: "\(name).nexus")
            try NexusPackage.write(t.document(), to: u)
            urls.append(u)
        }
        let m = HomeModel()
        m.load(urls)
        m.inboxCount = 3
        try await shoot(HomeView(model: m), "16-home")
        m.choosingStarter = true
        try await shoot(HomeView(model: m), "16-home-starters")
    }

    /// The starter picker (M40): the ⌘T sheet, light and dark, and a search.
    @Test(.enabled(if: dir != nil)) func starterPicker() async throws {
        let size = CGSize(width: 900, height: 600)
        let g = StarterGallery(purpose: .canvas, prefs: .isolated(), role: .security)
        try await shoot(StarterGalleryView(model: g), "m40-picker", size: size)
        try await shoot(StarterGalleryView(model: g), "m40-picker-dark", size: size, dark: true)
        g.section = .forYou
        try await shoot(StarterGalleryView(model: g), "m40-picker-foryou", size: size)
        g.section = .all
        g.query = "flow"
        try await shoot(StarterGalleryView(model: g), "m40-picker-search", size: size)
    }

    @Test(.enabled(if: dir != nil)) func tutorial() async throws {
        let h = CanvasHarness(model: StarterLibrary.tourDocument(.engineer))
        let tour = TourController(role: .engineer)
        tour.attach(h.controller)
        h.type("Checkout")
        h.press("return")
        h.press("tab")
        h.type("Cart")
        try await Task.sleep(for: .milliseconds(1000))
        h.snapshot(to: Self.dir!.appendingPathComponent("m8-31-tour.png"))
        h.press("esc")
        tour.pause()
        h.snapshot(to: Self.dir!.appendingPathComponent("m8-31-tour-paused.png"))
        tour.resume()
        for _ in 0..<6 { tour.skipLesson() }
        try await Task.sleep(for: .milliseconds(400))
        h.snapshot(to: Self.dir!.appendingPathComponent("m8-31-tour-finish.png"))
        // The tip toast after the third mouse use.
        let h2 = CanvasHarness(model: launchPlanDocument())
        for _ in 0..<3 { h2.controller.noteMouseUse(.addChild) }
        h2.snapshot(to: Self.dir!.appendingPathComponent("m8-tip.png"))
    }
}
