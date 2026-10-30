import NexusCanvas
import NexusCore
import NexusFormat
import NexusScene
import NexusTouch
import UIKit

/// Settings' buttons on the iPad (Report an issue, delete snapshots, clear chats, the
/// network log). The Mac-only ones (the command-line tool, updates, folders for agents)
/// aren't offered on iOS.
@MainActor
enum SettingsActions {
    static func run(_ action: String) {
        switch action {
        case "about.source", "about.notes", "general.whatsNew":
            UIApplication.shared.open(URL(string: "https://github.com/jvaudio/opennexus#readme")!)
        case "about.issue":
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            UIPasteboard.general.string = """
                OpenNexus \(version) (iPad)
                iPadOS \(UIDevice.current.systemVersion)
                """
            UIApplication.shared.open(URL(string: "https://github.com/jvaudio/opennexus/issues/new")!)
        case "files.deleteSnapshots":
            confirm(
                Loc.t("Delete all recovery snapshots?"),
                Loc.t("Snapshots of every document are removed. Your documents and their versions are not affected."),
                Loc.t("Delete")
            ) {
                SnapshotStore.deleteAll()
                Preferences.shared.set("files.lastCleared", Date().timeIntervalSince1970)
            }
        case "privacy.clearChats":
            confirm(
                Loc.t("Clear all AI chats?"), Loc.t("Chats kept on this iPad are removed."), Loc.t("Clear")
            ) { ChatStore.clearAll() }
        case "privacy.log", "privacy.exportLog":
            let url = FileManager.default.temporaryDirectory.appending(path: "OpenNexus network log.csv")
            try? Data(ShareCenter.shared.log.csv().utf8).write(to: url, options: .atomic)
            PlatformOpen.export(url) { _ in }
        default: break
        }
    }

    static func confirm(_ title: String, _ message: String, _ button: String, _ action: @escaping () -> Void) {
        let a = UIAlertController(title: title, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: button, style: .destructive) { _ in MainActor.assumeIsolated { action() } })
        a.addAction(UIAlertAction(title: Loc.t("Cancel"), style: .cancel))
        PlatformOpen.topViewController()?.present(a, animated: true)
    }
}
