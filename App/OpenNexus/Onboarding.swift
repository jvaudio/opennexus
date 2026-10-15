import AppKit
import NexusAI
import NexusCanvas
import NexusCore
import NexusFormat
import NexusInterchange
import SwiftUI

/// First run (F5): Welcome → role picker → the tour in a real document. Afterwards
/// launches follow Settings › General › At launch.
@MainActor
enum Onboarding {
    static let doneKey = "onboarding.done"
    static var done: Bool { UserDefaults.standard.bool(forKey: doneKey) }
    private static var window: NSWindow?

    static func launch() {
        if !done {
            showWelcome()
        } else if Preferences.shared.string("general.launch") == "home",
            NSDocumentController.shared.documents.isEmpty
        {
            HomeWindow.shared.show()
        }
    }

    static func present(_ view: some View, size: CGSize) {
        let w =
            window
            ?? NSWindow(
                contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isReleasedWhenClosed = false
        w.isMovableByWindowBackground = true
        w.setContentSize(size)
        w.contentView = NSHostingView(rootView: view)
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    static func close() {
        window?.orderOut(nil)
        window = nil
    }

    static func showWelcome() {
        present(
            WelcomeView(
                // Deferred: the same Return must not also press the role picker's default button.
                onTour: { DispatchQueue.main.async { MainActor.assumeIsolated { showRoles() } } },
                onSkip: {
                    finish()
                    NSDocumentController.shared.newDocument(nil)
                },
                onImport: {
                    finish()
                    (NSApp.delegate as? AppDelegate)?.importDocument(nil)
                }),
            size: CGSize(width: 1180, height: 760))
        window?.appearance = NSAppearance(named: .darkAqua)
    }

    static func showRoles() {
        let current = Role(rawValue: Preferences.shared.string("general.role")) ?? .engineer
        present(
            RolePickerView(
                initial: current,
                onContinue: { role in
                    Preferences.shared.set("general.role", role.rawValue)
                    // Deferred, so the Return that pressed Continue doesn't reach the new map.
                    DispatchQueue.main.async { MainActor.assumeIsolated { startTour(role) } }
                },
                onSkip: { role in
                    Preferences.shared.set("general.role", role.rawValue)
                    finish()
                    NSDocumentController.shared.newDocument(nil)
                }),
            size: CGSize(width: 1180, height: 760))
        window?.appearance = nil
    }

    /// The tour builds the user's first document.
    static func startTour(_ role: Role) {
        close()
        guard
            let nx = try? NSDocumentController.shared.makeUntitledDocument(ofType: "com.opennexus.document")
                as? NexusDocument
        else { return }
        nx.store.replace(with: TemplateLibrary.tourDocument(role))
        nx.markImported()
        NSDocumentController.shared.addDocument(nx)
        nx.makeWindowControllers()
        nx.showWindows()
        guard let wc = nx.windowControllers.first as? DocumentWindowController else { return }
        let tour = TourController(role: role)
        wc.controller.onTourEnded = { _ in
            finish()
            // The tutorial map stays as the first document (Home's empty state links it).
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let url = docs.appending(path: "My first map.nexus")
                nx.save(to: url, ofType: "com.opennexus.document", for: .saveAsOperation) { error in
                    if error == nil { UserDefaults.standard.set(url.path, forKey: "onboarding.tourMap") }
                }
            }
            wc.window?.makeFirstResponder(wc.host.canvasView)
        }
        DispatchQueue.main.async {
            tour.attach(wc.controller)
            wc.window?.makeFirstResponder(wc.host.canvasView)
        }
        // Clicking away pauses the tour into its corner pill.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: wc.window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { if wc.controller.tour?.finished == false { wc.controller.tour?.pause() } }
        }
    }

    static func finish() {
        UserDefaults.standard.set(true, forKey: doneKey)
        close()
    }
}

/// Home (artboard 16): ⇧⌘H, or at launch per Settings.
@MainActor
final class HomeWindow {
    static let shared = HomeWindow()
    let model = HomeModel()
    private var window: NSWindow?

    func show(choosingType: Bool = false) {
        reload()
        model.choosingType = choosingType
        if window == nil {
            let w = NSWindow(
                contentRect: CGRect(x: 0, y: 0, width: 1440, height: 900),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.title = "Home"
            w.titleVisibility = .hidden
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("OpenNexusHome")
            w.contentView = NSHostingView(rootView: HomeView(model: model))
            w.center()
            window = w
            wire()
        }
        window?.makeKeyAndOrderFront(nil)
    }

    func reload() {
        model.role = Role(rawValue: Preferences.shared.string("general.role")) ?? .engineer
        model.shelf = model.role.shelf
        model.aiStatus = AppleEngine().availability
        model.load(NSDocumentController.shared.recentDocumentURLs)
        model.inboxCount =
            (try? NexusPackage.read(from: Inbox.url))?.orderedCanvases.first.map { $0.nodes.count - 1 } ?? 0
        if let s = UserDefaults.standard.string(forKey: "onboarding.tourMap") {
            model.tourMap = URL(fileURLWithPath: s)
        }
    }

    func wire() {
        model.onNew = { [weak self] type in
            self?.window?.orderOut(nil)
            NewDocument.make(type: type)
        }
        model.onOpen = { [weak self] url in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            self?.window?.orderOut(nil)
        }
        model.onImport = { (NSApp.delegate as? AppDelegate)?.importDocument(nil) }
        model.onTemplate = { [weak self] t in
            self?.window?.orderOut(nil)
            NewDocument.make(model: t.document())
        }
        model.onInbox = { [weak self] in
            Inbox.ensure()
            NSDocumentController.shared.openDocument(withContentsOf: Inbox.url, display: true) { _, _, _ in }
            self?.window?.orderOut(nil)
        }
        model.onFilter = { [weak self] url, name in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { doc, _, _ in
                MainActor.assumeIsolated {
                    guard let wc = (doc as? NexusDocument)?.windowControllers.first as? DocumentWindowController else {
                        return
                    }
                    if let f = wc.controller.canvas.filters.first(where: { $0.name == name }) {
                        wc.controller.applySavedFilter(f)
                    }
                }
            }
            self?.window?.orderOut(nil)
        }
    }
}

/// New documents: Settings › Editing › New documents and Appearance › Default look.
@MainActor
enum NewDocument {
    static func make(type: DiagramType = .mindmap) {
        make(
            model: CanvasController.newDocumentModel(prefs: .shared, type: type),
            editRoot: Preferences.shared.bool("editing.startInEdit"))
    }

    static func make(model: DocumentModel, editRoot: Bool = false) {
        guard
            let nx = try? NSDocumentController.shared.makeUntitledDocument(ofType: "com.opennexus.document")
                as? NexusDocument
        else { return }
        nx.store.replace(with: model)
        if !editRoot { nx.markImported() }
        NSDocumentController.shared.addDocument(nx)
        nx.makeWindowControllers()
        nx.showWindows()
    }
}

/// The Inbox map (Quick Capture's default target, M9), kept in Application Support.
enum Inbox {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(
            path: "OpenNexus/Inbox.nexus")
    }

    static func ensure() {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? NexusPackage.write(DocumentModel(canvases: [Canvas(id: "c1", title: "Inbox", rootText: "Inbox")]), to: url)
    }
}
