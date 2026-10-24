import AppKit
import NexusCanvas
import Sparkle

/// Software updates (M38, D275): Sparkle, off until the user agrees. Nothing is fetched
/// until update checks are on (Settings › General › Updates, or Sparkle's own question on
/// a later launch) or the user picks Check for Updates…. OpenNexus itself has no network
/// entitlement: Sparkle's Downloader service fetches the feed and the update, and its
/// Installer service replaces the app. An update must be signed with the key in
/// `SUPublicEDKey` and by the same Developer ID.
///
/// The Settings rows and Sparkle's own settings stay in step both ways:
/// `general.updatesCheck` ↔ `automaticallyChecksForUpdates`,
/// `general.updatesInstall` ↔ `automaticallyDownloadsUpdates`, and
/// `general.updatesChannel` picks the feed items Sparkle may offer.
@MainActor
final class Updates: NSObject, SPUUpdaterDelegate {
    static let shared = Updates()

    private let prefs = Preferences.shared
    private(set) lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private var updater: SPUUpdater { controller.updater }
    private var watchers: [NSKeyValueObservation] = []
    private var applying = false

    /// Starts Sparkle (which checks nothing unless checks are on) and links it to Settings.
    func start() {
        controller.startUpdater()
        // Sparkle's answer, if the user already gave one, wins over the rows' defaults.
        mirrorSparkle()
        watchers = [
            updater.observe(\.automaticallyChecksForUpdates) { _, _ in
                MainActor.assumeIsolated { Updates.shared.mirrorSparkle() }
            },
            updater.observe(\.automaticallyDownloadsUpdates) { _, _ in
                MainActor.assumeIsolated { Updates.shared.mirrorSparkle() }
            },
        ]
        NotificationCenter.default.addObserver(forName: Preferences.didChange, object: prefs, queue: .main) { n in
            let key = n.userInfo?["key"] as? String
            MainActor.assumeIsolated { Updates.shared.applySettings(key) }
        }
    }

    /// The menu item and Settings › General › Updates › Check Now.
    @objc func checkForUpdates(_ sender: Any?) { controller.checkForUpdates(sender) }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    /// Settings → Sparkle. Turning on automatic installs turns on checks, which they need.
    private func applySettings(_ key: String?) {
        guard !applying, key == nil || key!.hasPrefix("general.updates") else { return }
        applying = true
        defer { applying = false }
        var check = prefs.bool("general.updatesCheck")
        let install = prefs.bool("general.updatesInstall")
        if install && !check {
            check = true
            prefs.set("general.updatesCheck", true)
        }
        if updater.automaticallyChecksForUpdates != check { updater.automaticallyChecksForUpdates = check }
        if updater.automaticallyDownloadsUpdates != install { updater.automaticallyDownloadsUpdates = install }
        if key == "general.updatesChannel", check { updater.resetUpdateCycleAfterShortDelay() }
    }

    /// Sparkle → Settings, e.g. after the user answers Sparkle's "Check automatically?".
    private func mirrorSparkle() {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        if prefs.bool("general.updatesCheck") != updater.automaticallyChecksForUpdates {
            prefs.set("general.updatesCheck", updater.automaticallyChecksForUpdates)
        }
        let install = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        if prefs.bool("general.updatesInstall") != install { prefs.set("general.updatesInstall", install) }
    }

    // MARK: SPUUpdaterDelegate

    /// The Beta channel also offers feed items marked `<sparkle:channel>beta</sparkle:channel>`.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated { Preferences.shared.string("general.updatesChannel") == "beta" ? ["beta"] : [] }
    }

    /// Records when Sparkle last checked, for Settings › Privacy & Data.
    nonisolated func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?
    ) {
        MainActor.assumeIsolated {
            Preferences.shared.set("general.updatesLastCheck", Date().timeIntervalSince1970)
        }
    }
}

extension Updates: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(checkForUpdates(_:)) ? canCheckForUpdates : true
    }
}
