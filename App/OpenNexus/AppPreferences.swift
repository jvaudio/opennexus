import AppKit
import NexusAI
import NexusCanvas
import NexusCore
import NexusFormat
import NexusKeys
import SwiftUI

/// App-wide settings that live outside a document window (M8): appearance, language,
/// launch behaviour, tabs, the menu bar's shortcuts, and the Settings buttons' actions.
@MainActor
final class AppPreferences {
    static let shared = AppPreferences()
    let prefs = Preferences.shared
    private var observer: (any NSObjectProtocol)?
    private var settingsWindow: NSWindow?
    private var infoWindow: NSWindow?

    func start() {
        apply(nil)
        observer = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: prefs, queue: .main) {
            n in
            let key = n.userInfo?["key"] as? String
            MainActor.assumeIsolated { AppPreferences.shared.apply(key) }
        }
        // The system text size can change while OpenNexus is in the background.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ChromeText.apply(followSystem: AppPreferences.shared.prefs.bool("accessibility.systemTextSize"))
            }
        }
    }

    func apply(_ key: String?) {
        func touched(_ prefix: String) -> Bool { key == nil || key!.hasPrefix(prefix) }
        if touched("general.appearance") {
            switch prefs.string("general.appearance") {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: NSApp.appearance = nil
            }
        }
        if touched("general.language") {
            let l = prefs.string("general.language")
            if l == "system" {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([l], forKey: "AppleLanguages")
            }
        }
        if touched("general.restoreWindows") {
            UserDefaults.standard.set(prefs.bool("general.restoreWindows"), forKey: "NSQuitAlwaysKeepsWindows")
        }
        if touched("general.openIn") {
            let mode: NSWindow.TabbingMode = prefs.string("general.openIn") == "windows" ? .disallowed : .preferred
            for w in NSApp.windows where w.windowController is DocumentWindowController { w.tabbingMode = mode }
        }
        if touched("shortcuts") || touched("accessibility.stickyHyper") {
            var c = prefs.data("shortcuts.custom").flatMap(KeyCustomization.decode) ?? KeyCustomization()
            c.profile = prefs.string("shortcuts.profile")
            NSApp.mainMenu = MainMenu.build(registry: c.apply(to: .standard), profile: c.keyProfile, custom: c.custom)
        }
        if touched("appearance.toolbar") || touched("appearance.glass") || touched("general.spelling")
            || touched("general.autocorrect") || touched("general.smartQuotes") || touched("ai.statusChip")
        {
            for w in NSApp.windows { (w.windowController as? DocumentWindowController)?.applyWindowPreferences() }
        }
        if touched("accessibility.fullKeyboard") {
            // Settings › Accessibility › Full keyboard access to panels: Tab reaches every
            // control in OpenNexus, whatever the system's Keyboard navigation setting.
            if prefs.bool("accessibility.fullKeyboard") {
                UserDefaults.standard.set(2, forKey: "AppleKeyboardUIMode")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleKeyboardUIMode")
            }
        }
        if touched("accessibility.systemTextSize") {
            ChromeText.apply(followSystem: prefs.bool("accessibility.systemTextSize"))
        }
        if touched("files.snapshotKeep") {
            SnapshotStore.prune(olderThan: Double(prefs.string("files.snapshotKeep")) ?? 7)
        }
    }

    // MARK: Integrations

    private var foldersWindow: NSWindow?

    /// Settings › Integrations › Allowed folders: where `nexus mcp` may read and write.
    func showAllowedFolders() {
        let view = AllowedFoldersView(prefs: prefs) { [weak self] in self?.foldersWindow?.close() }
        let w =
            foldersWindow
            ?? NSPanel(
                contentRect: CGRect(x: 0, y: 0, width: 520, height: 360), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
        w.title = Loc.t("Allowed Folders")
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: view)
        if let s = settingsWindow, s.isVisible {
            s.beginSheet(w)
        } else {
            w.center()
            w.makeKeyAndOrderFront(nil)
        }
        foldersWindow = w
    }

    /// The `nexus` tool ships inside the app (Contents/Helpers). A sandboxed app can't
    /// write to /usr/local/bin, so Install… gives the one command to link it (D118).
    func installCLI() {
        let tool = Bundle.main.bundleURL.appending(path: "Contents/Helpers/nexus")
        let command = "sudo mkdir -p /usr/local/bin && sudo ln -sf '\(tool.path)' /usr/local/bin/nexus"
        let a = NSAlert()
        a.messageText = Loc.t("Install the nexus command-line tool")
        a.informativeText =
            FileManager.default.isExecutableFile(atPath: tool.path)
            ? Loc.f(
                "Run this in Terminal to link the tool into your PATH (it asks for your password):\n\n%@\n\nThen MCP clients can use { \"command\": \"nexus\", \"args\": [\"mcp\"] }.",
                command)
            : Loc.t("This build doesn't include the tool. Build it with:\n\nswift build -c release --product nexus")
        a.addButton(withTitle: Loc.t("Copy Command"))
        a.addButton(withTitle: Loc.t("Done"))
        if a.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
    }

    // MARK: Settings window

    func showSettings(pane: String = "general") {
        if settingsWindow == nil {
            let w = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1240, height: 820),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.title = Loc.t("Settings")
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("OpenNexusSettings")
            settingsWindow = w
        }
        settingsWindow?.contentView = NSHostingView(
            rootView: SettingsView(prefs: prefs, availability: AppleEngine().availability, pane: pane) {
                [weak self] action in
                self?.run(action)
            })
        settingsWindow?.contentView?.setAccessibilityLabel(Loc.t("Settings"))
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Buttons in Settings

    var frontDocument: (NexusDocument, DocumentWindowController)? {
        for d in NSDocumentController.shared.documents {
            if let nx = d as? NexusDocument, let wc = nx.windowControllers.first as? DocumentWindowController {
                return (nx, wc)
            }
        }
        return nil
    }

    func run(_ action: String) {
        switch action {
        case "general.replayTour":
            (NSApp.delegate as? AppDelegate)?.showWelcome(nil)
        case "general.whatsNew", "about.notes":
            showInfo(Loc.t("What’s new in OpenNexus 1.0"), WhatsNew.text)
        case "about.source":
            showInfo(Loc.t("OpenNexus is open source"), Self.licence)
        case "about.issue":
            let info = """
                OpenNexus \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))
                macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
                Apple Intelligence: \(AppleEngine().availability.chip)
                """
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(info, forType: .string)
            showInfo(
                Loc.t("Report an issue"),
                Loc.f(
                    "Version details are on the clipboard. Paste them into your report so it’s easy to reproduce. OpenNexus never sends anything itself.\n\n%@",
                    info)
            )
        case "files.openRecovery":
            if let (doc, wc) = frontDocument {
                wc.controller.snapshots = doc.snapshots
                wc.window?.makeKeyAndOrderFront(nil)
            } else {
                showInfo(Loc.t("Recovery"), Loc.t("Open a document to browse its recovery snapshots."))
            }
        case "files.deleteSnapshots":
            let a = NSAlert()
            a.messageText = Loc.t("Delete all recovery snapshots?")
            a.informativeText =
                Loc.t("Snapshots of every document are removed. Your documents and their versions are not affected.")
            a.addButton(withTitle: Loc.t("Delete"))
            a.addButton(withTitle: Loc.t("Cancel"))
            a.buttons[0].hasDestructiveAction = true
            if a.runModal() == .alertFirstButtonReturn { SnapshotStore.deleteAll() }
            prefs.set("files.lastCleared", Date().timeIntervalSince1970)
        case "integrations.folders":
            showAllowedFolders()
        case "integrations.cli":
            installCLI()
        case "privacy.clearChats":
            let a = NSAlert()
            a.messageText = Loc.t("Clear all AI chats?")
            a.informativeText = Loc.t("Chats in open documents and those kept on this Mac are removed.")
            a.addButton(withTitle: Loc.t("Clear"))
            a.addButton(withTitle: Loc.t("Cancel"))
            if a.runModal() == .alertFirstButtonReturn {
                for d in NSDocumentController.shared.documents {
                    if let nx = d as? NexusDocument {
                        nx.store.updateDocument { $0.chats = [] }
                        nx.updateChangeCount(.changeDone)
                    }
                }
                ChatStore.clearAll()
            }
        case "privacy.log":
            showInfo(
                Loc.t("Network activity"),
                Loc.t(
                    "No outbound requests. OpenNexus has no network entitlement, so macOS blocks any connection it might try."
                )
            )
        default:
            if action.hasPrefix("snapshot.copy:") || action.hasPrefix("snapshot.compare:") {
                let path = String(action.split(separator: ":", maxSplits: 1)[1])
                (NSApp.delegate as? AppDelegate)?.openSnapshotCopy(
                    URL(fileURLWithPath: path), sideBySide: action.hasPrefix("snapshot.compare:"))
            }
        }
    }

    func showInfo(_ title: String, _ body: String) {
        let w = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(
            rootView: ScrollView {
                Text(.init(body)).font(.chrome(14)).textSelection(.enabled).frame(
                    maxWidth: .infinity, alignment: .leading
                ).padding(24)
            }
            .accessibilityLabel(title))
        w.center()
        w.makeKeyAndOrderFront(nil)
        infoWindow = w
    }

    static let licence = """
        **MIT License**

        Copyright (c) 2026 Jerry Voelker

        Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the “Software”), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
        """
}

enum WhatsNew {
    static let text = """
        **Keyboard first.** ⇥ child, ↩ sibling, ⇧⌘L Connect mode, ⌥⌘T convert between eleven diagram types. Hold ⌘ for every key.

        **Technical diagrams.** Flowcharts, data flow with live rule checks, threat models with STRIDE, architecture, sequence and swimlanes.

        **On-device AI.** Ghost suggestions (⌥Space), the prompt bar (⇧⌘Space) and the AI panel (⇧⌘J). Nothing leaves this Mac.

        **Files that outlive the app.** Diff-friendly .nexus packages, Xmind import with a report, export to PNG, SVG, PDF, Mermaid, PlantUML, draw.io, Markdown, Word and more — never with a watermark.

        **Settings and Home.** Ten settings panes with search, a template shelf for your role, and a four-minute tour you build yourself.
        """
}

/// AI chats kept on this Mac rather than in the document (Settings › Privacy & Data).
enum ChatStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(
            path: "OpenNexus/Chats")
    }

    static func url(_ id: String) -> URL { directory.appending(path: "\(id).json") }

    static func save(_ chats: [AIChat], documentID: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? CanonicalJSON.data(.object(["chats": .array(chats.map(\.json))])).write(
            to: url(documentID), options: .atomic)
    }

    static func load(documentID: String) -> [AIChat] {
        guard let d = try? Data(contentsOf: url(documentID)), let v = try? CanonicalJSON.parse(d),
            var r = try? ObjectReader(v, path: "chats"),
            let list = try? r.array("chats")
        else { return [] }
        return list.enumerated().compactMap { try? AIChat(json: $1, path: "chats[\($0)]") }
    }

    static func clearAll() { try? FileManager.default.removeItem(at: directory) }
}
