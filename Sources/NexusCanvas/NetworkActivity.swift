import Foundation
import NexusFormat

/// What can leave this Mac, in words, for Settings › Privacy & Data (D275, D313). OpenNexus
/// itself has no network entitlement. Two separate services may connect, each only once
/// you turn it on: Sparkle's Downloader for updates, and OpenNexusNet for share links, which
/// reaches only the destinations you set up and logs every request.
@MainActor
public enum NetworkActivity {
    /// Where updates come from (the feed and the downloads).
    public static let source = "github.com/jvaudio/opennexus"

    public static func updateChecksOn(_ prefs: Preferences) -> Bool { prefs.bool("general.updatesCheck") }

    /// The master switch (Privacy & Data › Network) and share links under it.
    public static func networkOn(_ prefs: Preferences) -> Bool { prefs.bool("network.enabled") }
    public static func sharingOn(_ prefs: Preferences) -> Bool { networkOn(prefs) && prefs.bool("network.sharing") }

    /// When Sparkle last looked for an update, if ever.
    public static func lastCheck(_ prefs: Preferences) -> Date? {
        let t = prefs.number("general.updatesLastCheck")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// The card's headline: the logged requests of the last 7 days when there are any; else,
    /// while update checks are on, that they're the only traffic; with them off, "0 requests"
    /// until someone chooses Check for Updates…, then that checks happen on request.
    public static func headline(_ prefs: Preferences, log: [NetLogEntry] = []) -> (value: String, unit: String) {
        if !log.isEmpty { return ("\(log.count)", log.count == 1 ? Loc.t("request") : Loc.t("requests")) }
        if updateChecksOn(prefs) { return (Loc.t("Updates"), Loc.t("only")) }
        return lastCheck(prefs) == nil ? ("0", Loc.t("requests")) : (Loc.t("Updates"), Loc.t("on request"))
    }

    public static func summary(_ prefs: Preferences, log: [NetLogEntry] = []) -> String {
        var s = Loc.t(
            "Documents, AI prompts and AI results never leave this Mac unsealed. OpenNexus itself has no network permission, so macOS blocks any connection it might try."
        )
        if sharingOn(prefs) {
            let hosts = Set(log.map(\.host)).sorted()
            s +=
                " "
                + (log.isEmpty
                    ? Loc.t(
                        "Share links are on: the separate network service uploads maps, sealed on this Mac, only to the destinations in Settings › Sharing. It has made no requests in the last 7 days."
                    )
                    : Loc.f(
                        "Share links are on: the separate network service uploads maps, sealed on this Mac, only to the destinations in Settings › Sharing. In the last 7 days it made %@ to %@.",
                        Loc.n("%lld request", "%lld requests", log.count), hosts.joined(separator: ", ")))
        } else {
            s +=
                " "
                + Loc.t("The network is off (Privacy & Data › Network), so the network service connects to nothing.")
        }
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

    /// The log as a Markdown table, newest first (Open log…).
    public static func table(_ log: [NetLogEntry]) -> String {
        guard !log.isEmpty else { return Loc.t("No requests in the last 30 days.") }
        var out =
            "| \(Loc.t("Time")) | \(Loc.t("Host")) | \(Loc.t("Request")) | \(Loc.t("Status")) | \(Loc.t("Sent")) | \(Loc.t("Received")) |\n|---|---|---|---|---|---|\n"
        for e in log.reversed() {
            let status = e.status == 0 ? Loc.t("refused") : "\(e.status)"
            out +=
                "| \(e.date.formatted(date: .abbreviated, time: .standard)) | \(e.host) | \(e.method) · \(e.purpose) | \(status) | \(ByteCountFormatter.string(fromByteCount: Int64(e.sent), countStyle: .file)) | \(ByteCountFormatter.string(fromByteCount: Int64(e.received), countStyle: .file)) |\n"
        }
        return out
    }
}
