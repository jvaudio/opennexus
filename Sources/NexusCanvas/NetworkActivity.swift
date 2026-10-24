import Foundation

/// What can leave this Mac, in words, for Settings › Privacy & Data (D275). The only
/// network use is software updates: off by default, and done by Sparkle's own Downloader
/// service, not by OpenNexus, which has no network entitlement.
@MainActor
public enum NetworkActivity {
    /// Where updates come from (the feed and the downloads).
    public static let source = "github.com/jvaudio/opennexus"

    public static func updateChecksOn(_ prefs: Preferences) -> Bool { prefs.bool("general.updatesCheck") }

    /// When Sparkle last looked for an update, if ever.
    public static func lastCheck(_ prefs: Preferences) -> Date? {
        let t = prefs.number("general.updatesLastCheck")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// The card's headline: while checks are on, that they're the only traffic; with them off,
    /// "0 requests" until someone chooses Check for Updates…, then that checks happen on request.
    public static func headline(_ prefs: Preferences) -> (value: String, unit: String) {
        if updateChecksOn(prefs) { return (Loc.t("Updates"), Loc.t("only")) }
        return lastCheck(prefs) == nil ? ("0", Loc.t("requests")) : (Loc.t("Updates"), Loc.t("on request"))
    }

    public static func summary(_ prefs: Preferences) -> String {
        var s = Loc.t(
            "Documents, AI prompts and AI results never leave this Mac. OpenNexus itself has no network permission, so macOS blocks any connection it might try."
        )
        if updateChecksOn(prefs) {
            s +=
                " "
                + Loc.f(
                    "Update checks are on: about once a day, the separate update service fetches the list of versions from %@, and downloads a new version only when there is one. Nothing about you or your documents is sent.",
                    source)
        } else {
            s +=
                " "
                + Loc.t(
                    "Update checks are off (Settings › General › Updates); the update service connects only when you choose Check for Updates…."
                )
        }
        if let d = lastCheck(prefs) {
            s += " " + Loc.f("Last update check: %@.", d.formatted(date: .abbreviated, time: .shortened))
        }
        return s
    }
}
