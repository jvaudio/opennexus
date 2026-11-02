import AppKit
import NexusCanvas
import NexusCore
import NexusScene
import SwiftUI

/// Your own starters in the Mac app (M50): Save Canvas as Starter… in a document window;
/// Install Starter…, and starter files opened from Finder, anywhere.
extension DocumentWindowController {
    /// File › Save Canvas as Starter…: name it, and it's in My Starters (the canvas as it is,
    /// with the document's theme and the pictures it uses).
    func saveCanvasAsStarter() {
        guard let window, window.attachedSheet == nil else { return }
        // Starters are plain files, so a password-protected canvas stays where it is.
        if document_.cryptoKey != nil {
            let a = NSAlert()
            a.messageText = Loc.t("This document has a password")
            a.informativeText = Loc.t(
                "Starters aren’t encrypted, so a canvas from a password-protected document can’t be saved as one.")
            a.beginSheetModal(for: window)
            return
        }
        let canvas = controller.canvas
        let model = controller.store.model
        let sheet = NSWindow(contentViewController: NSViewController())
        let form = StarterDetailsForm(
            title: Loc.t("Save Canvas as Starter"), action: Loc.t("Save"),
            values: .init(name: canvas.title.isEmpty ? Loc.t("My starter") : canvas.title)
        ) { [weak self, weak window, weak sheet] values in
            if let sheet { window?.endSheet(sheet) }
            guard let self, let values else { return }
            var s = Starter.saved(
                from: canvas, in: model, name: values.trimmedName, collection: nil, summary: "", aliases: [])
            values.apply(to: &s)
            do {
                let saved = try MyStarters.shared.save(s)
                controller.showToast(Loc.f("Saved “%@” to My Starters", saved.name))
            } catch {
                controller.showToast(Loc.f("Couldn’t save the starter: %@", error.localizedDescription))
            }
            window?.makeFirstResponder(host.canvasView)
        }
        sheet.contentViewController = NSHostingController(rootView: form)
        sheet.title = Loc.t("Save Canvas as Starter")
        window.beginSheet(sheet)
    }
}

/// Installing starters (M50): File › Install Starter…, and a `.nexusstarter` or
/// `.nexusstarters` opened from Finder. What the file holds is shown first; installing adds
/// it to My Starters and runs nothing. It lands in Home's picker, on My Starters.
@MainActor
enum StarterInstaller {
    private static var window: NSWindow?

    /// File › Install Starter…
    static func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MyStarters.contentTypes
        panel.message = Loc.t("Choose a .nexusstarter file or a .nexusstarters pack.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    /// Reads the file and shows what it holds, or why it can't be installed.
    static func open(_ url: URL) {
        do {
            // Mapped, so an oversized file is refused without being read.
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let starters = try StarterFile.read(data, name: url.lastPathComponent)
            show(StarterGallery.Install(starters: starters, clashes: MyStarters.shared.clashes(starters)))
        } catch {
            let a = NSAlert()
            a.messageText = Loc.t("Couldn’t install the starter")
            a.informativeText = (error as? StarterFile.Refusal)?.message ?? error.localizedDescription
            a.runModal()
        }
    }

    private static func show(_ install: StarterGallery.Install) {
        window?.close()
        let w = NSWindow(contentViewController: NSViewController())
        w.contentViewController = NSHostingController(
            rootView: StarterInstallView(install: install) { [weak w] clash in
                w?.close()
                window = nil
                guard let clash else { return }
                HomeWindow.shared.show(choosingStarter: true)
                HomeWindow.shared.model.gallery.install(install, clash: clash)
            })
        w.title = Loc.t("Install Starter")
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}

/// Opens documents, and hands starter files to the installer (M50): a `.nexusstarter`
/// opened from Finder or dropped on the Dock icon is previewed, never opened as a document.
/// Made before anything asks for `NSDocumentController.shared`, so it's the shared one.
final class AppDocumentController: NSDocumentController {
    override func openDocument(
        withContentsOf url: URL, display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
    ) {
        guard MyStarters.isStarterFile(url) else {
            return super.openDocument(
                withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
        }
        StarterInstaller.open(url)
        completionHandler(nil, false, nil)
    }
}
