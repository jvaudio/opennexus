import Foundation
import NexusCore
import NexusFormat
import NexusInterchange

/// Copies of a document that other apps' sync left behind (M45): iCloud Drive's conflict
/// versions (`NSFileVersion`) and the "conflicted copy" files of Dropbox, Syncthing, Google
/// Drive and OneDrive. Opening the document offers to merge them in, two ways, instead of
/// picking one.
public struct ConflictCopy: Equatable, Hashable, Sendable, Identifiable {
    public var url: URL
    /// "iCloud Drive", "Dropbox", "Syncthing", "Google Drive", "OneDrive".
    public var source: String
    /// The Mac or person the copy came from, when its name says.
    public var from: String?
    public var modified: Date?
    /// An iCloud version (resolved through `NSFileVersion`) rather than a file of its own.
    public var isVersion: Bool

    public var id: URL { url }

    public init(url: URL, source: String, from: String? = nil, modified: Date? = nil, isVersion: Bool = false) {
        self.url = url
        self.source = source
        self.from = from
        self.modified = modified
        self.isVersion = isVersion
    }

    /// How the sheet names it: "Dropbox copy from Jerry", "iCloud Drive version from MacBook Air".
    public var label: String {
        from.map { Loc.f("%@ copy from %@", source, $0) } ?? Loc.f("%@ copy", source)
    }
}

/// Where iCloud keeps a document's conflict versions (a protocol, so tests can supply some).
public protocol ConflictVersions {
    func unresolved(_ url: URL) -> [ConflictCopy]
    /// Marks every conflict version of `url` resolved and removes them.
    func resolve(_ url: URL)
}

public struct ICloudVersions: ConflictVersions {
    public init() {}

    public func unresolved(_ url: URL) -> [ConflictCopy] {
        (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []).map {
            ConflictCopy(
                url: $0.url, source: Loc.t("iCloud Drive"), from: $0.localizedNameOfSavingComputer,
                modified: $0.modificationDate, isVersion: true)
        }
    }

    public func resolve(_ url: URL) {
        for v in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] { v.isResolved = true }
        try? NSFileVersion.removeOtherVersionsOfItem(at: url)
    }
}

public enum ConflictCopies {
    /// Which sync app made `candidate` as a copy of `original` (file names with their
    /// extension), and who from; nil when it isn't one. `folder` is the path they're in:
    /// Google Drive's and OneDrive's patterns are only trusted in their own folders.
    public static func match(_ candidate: String, of original: String, folder: String = "") -> (
        source: String, from: String?
    )? {
        let ext = (original as NSString).pathExtension
        guard (candidate as NSString).pathExtension == ext, candidate != original else { return nil }
        let stem = NSRegularExpression.escapedPattern(for: (original as NSString).deletingPathExtension)
        let name = (candidate as NSString).deletingPathExtension
        func first(_ pattern: String) -> [String?]? {
            guard let re = try? NSRegularExpression(pattern: pattern),
                let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name))
            else { return nil }
            return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: name).map { String(name[$0]) } }
        }
        // Dropbox (and Nextcloud): "Plan (Jerry's conflicted copy 2026-10-29).nexus".
        if let g = first("^\(stem) \\((?:(.+?)['’]s )?conflicted copy[^)]*\\)$") {
            return (folder.contains("Nextcloud") ? "Nextcloud" : "Dropbox", g[1])
        }
        // Syncthing: "Plan.sync-conflict-20261029-101112-ABCDEFG.nexus" (the last part is the device).
        if let g = first("^\(stem)\\.sync-conflict-\\d{8}-\\d{6}(?:-([A-Z0-9]{7}))?$") {
            return ("Syncthing", g[1])
        }
        // Google Drive: "Plan (1).nexus", only inside a Google Drive folder.
        if folder.contains("GoogleDrive") || folder.contains("Google Drive"), first("^\(stem) \\(\\d+\\)$") != nil {
            return ("Google Drive", nil)
        }
        // OneDrive: "Plan-MacBook-Air.nexus" (the device's name), only inside a OneDrive folder.
        if folder.contains("OneDrive"), let g = first("^\(stem)-([^ ]+)$") {
            return ("OneDrive", g[1])
        }
        return nil
    }

    /// The document's conflict copies: its iCloud versions and the matching files beside it.
    public static func find(for url: URL, versions: any ConflictVersions = ICloudVersions()) -> [ConflictCopy] {
        let folder = url.deletingLastPathComponent()
        let original = url.lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
        let files = names.sorted().compactMap { n -> ConflictCopy? in
            guard let m = match(n, of: original, folder: folder.path(percentEncoded: false)) else { return nil }
            let u = folder.appending(path: n, directoryHint: .isDirectory)
            let date = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            return ConflictCopy(url: u, source: m.source, from: m.from, modified: date)
        }
        return versions.unresolved(url) + files
    }

    /// Reads a copy as a document.
    public static func read(_ copy: ConflictCopy) throws -> DocumentModel {
        if copy.url.pathExtension.lowercased() == "nexusjson" {
            return try DocumentJSON.parse(Data(contentsOf: copy.url), name: copy.url.lastPathComponent)
        }
        return try NexusPackage.read(from: copy.url)
    }

    /// After merging: iCloud's versions are resolved, and copies go to the Trash.
    public static func finish(
        _ copies: [ConflictCopy], of url: URL, versions: any ConflictVersions = ICloudVersions(),
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        if copies.contains(where: \.isVersion) { versions.resolve(url) }
        for c in copies where !c.isVersion { try? trash(c.url) }
    }
}

/// An iCloud Drive document that isn't on this Mac yet (M45): opening it from Home starts
/// the download, and its card says so until it's here.
public enum CloudDownload {
    public static func isPending(_ url: URL) -> Bool {
        var u = url
        u.removeAllCachedResourceValues()
        guard let v = try? u.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
            v.isUbiquitousItem == true
        else { return false }
        return v.ubiquitousItemDownloadingStatus != .current
    }

    /// Starts the download and returns once the document is here.
    public static func download(_ url: URL, timeout: Duration = .seconds(300)) async throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        let clock = ContinuousClock()
        let end = clock.now + timeout
        while isPending(url) {
            var u = url
            u.removeAllCachedResourceValues()
            if let e = try? u.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey])
                .ubiquitousItemDownloadingError
            {
                throw e
            }
            guard clock.now < end else { throw CocoaError(.fileReadUnknown) }
            try await Task.sleep(for: .milliseconds(300))
        }
    }
}
