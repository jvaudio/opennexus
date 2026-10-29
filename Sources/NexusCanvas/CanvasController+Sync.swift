import Foundation
import NexusCore
import NexusFormat
import NexusScene
import NexusSync

/// Resolve Conflicts, Sync History… and Merge Conflicting Copies… (M45).

/// A merge whose clashes kept this document's side, offered one clash at a time: Mine,
/// Theirs or Keep Both. Applying the choices is one undo step.
public struct ResolveState: Identifiable {
    public enum Origin: Equatable {
        /// A sync merge of the document at this path.
        case sync(URL)
        /// Conflict copies, done once every queued merge is resolved.
        case copies([ConflictCopy])
    }

    public let id = UUID()
    /// "Changes from MacBook Air", "Dropbox copy from Jerry".
    public var title: String
    public var base: DocumentModel?
    public var mine: DocumentModel
    public var theirs: DocumentModel
    /// The document as the merge left it: what a choice is applied against.
    public var merged: DocumentModel
    public var clashes: [MergeClash]
    public var choices: [String: MergeClash.Choice] = [:]
    /// Keep Both's canvas title suffix ("from MacBook Air").
    public var copySuffix: String
    public var origin: Origin

    public func choice(_ c: MergeClash) -> MergeClash.Choice { choices[c.id] ?? .mine }
}

/// File › Sync History…: the document's revisions in its library.
public struct SyncHistoryState {
    public var items: [HeadRecord] = []
    public var loading = true
    public var error: String?
    public var restoring: String?
}

extension CanvasController {
    var documentURL: URL? { documentPath.map { URL(fileURLWithPath: $0) } }

    // MARK: Resolve Conflicts

    /// File › Resolve Conflicts…: this document's clashes from sync, or its conflict copies.
    public func openResolveConflicts() {
        if !conflictCopies.isEmpty {
            mergeConflictCopies()
            return
        }
        guard let url = documentURL else { return showToast(Loc.t("No conflicts to resolve")) }
        Task {
            guard let p = await syncCenter.pendingConflict(for: url) else {
                showToast(Loc.t("No conflicts to resolve"))
                return
            }
            showResolve(for: p, url: url)
        }
    }

    public func showResolve(for p: PendingConflict, url: URL) {
        let clashes = p.clashes
        guard !clashes.isEmpty else { return }
        resolveState = ResolveState(
            title: Loc.f("Changes from %@", p.theirsDevice), base: p.base, mine: p.mine, theirs: p.theirs,
            merged: p.merged, clashes: clashes, copySuffix: Loc.f("from %@", p.theirsDevice), origin: .sync(url))
    }

    public func choose(_ choice: MergeClash.Choice, for clash: MergeClash) {
        resolveState?.choices[clash.id] = choice
    }

    /// Every clash to one side (the sheet's "All Mine" / "All Theirs").
    public func chooseAll(_ choice: MergeClash.Choice) {
        guard let s = resolveState else { return }
        for c in s.clashes { resolveState?.choices[c.id] = choice }
    }

    /// Applies the choices as one undo step: what the document has now keeps edits made
    /// since the merge.
    public func applyResolution() {
        guard let s = resolveState else { return }
        let resolved = DocumentMerge(
            base: s.base, current: s.mine, disk: s.theirs, choices: s.choices, copySuffix: s.copySuffix
        ).model
        if s.choices.values.contains(where: { $0 != .mine }) {
            _ = store.mergeExternal(resolved, base: s.merged, focus: canvasID, actionName: Loc.t("Resolve Conflicts"))
            showToast(Loc.t("Resolved · ⌘Z undoes"))
        }
        finishResolve(s)
    }

    /// Closes the sheet; the clashes keep this document's side and stay listed.
    public func closeResolve() {
        resolveState = nil
        resolveQueue = []
    }

    func finishResolve(_ s: ResolveState) {
        resolveState = nil
        switch s.origin {
        case .sync(let url):
            Task { await syncCenter.clearConflict(for: url) }
        case .copies(let copies):
            if resolveQueue.isEmpty { copiesDone(copies) }
        }
        if !resolveQueue.isEmpty { resolveState = resolveQueue.removeFirst() }
    }

    // MARK: Conflict copies

    /// Copies other apps' sync left (the app looks when the document opens).
    public func offerConflictCopies(_ copies: [ConflictCopy]) {
        conflictCopies = copies
    }

    public func dismissConflictCopies() { conflictCopies = [] }

    /// Merges each copy into the document two ways (nothing is deleted; what differs is a
    /// clash), one undo step per copy; clashes go to Resolve Conflicts one copy at a time.
    public func mergeConflictCopies() {
        let copies = conflictCopies
        guard !copies.isEmpty else { return }
        conflictCopies = []
        var queue: [ResolveState] = []
        var merged: [ConflictCopy] = []
        for copy in copies {
            guard let theirs = try? readCopy(copy) else {
                showToast(Loc.f("Couldn’t read the %@", copy.label))
                continue
            }
            let mine = store.model
            let m = DocumentMerge(base: nil, current: mine, disk: theirs, copySuffix: copy.label)
            store.commitDocument(Loc.t("Merge Conflicting Copy"), focus: canvasID) { d in
                d.canvases = m.model.canvases
                d.canvasOrder = m.model.canvasOrder
                d.theme = m.model.theme
                for (k, v) in m.model.assets where d.assets[k] == nil { d.assets[k] = v }
            }
            merged.append(copy)
            if !m.clashes.isEmpty {
                queue.append(
                    ResolveState(
                        title: copy.label, base: nil, mine: mine, theirs: theirs, merged: store.model,
                        clashes: m.clashes, copySuffix: copy.label, origin: .copies(copies)))
            }
        }
        if queue.isEmpty {
            copiesDone(merged)
            showToast(Loc.n("Merged %lld copy · ⌘Z undoes", "Merged %lld copies · ⌘Z undoes", merged.count))
        } else {
            resolveState = queue.removeFirst()
            resolveQueue = queue
        }
    }

    func copiesDone(_ copies: [ConflictCopy]) {
        onConflictCopiesMerged?(copies)
    }

    // MARK: Sync History

    public func openSyncHistory() {
        guard let url = documentURL, syncCenter.isSynced(url) else {
            return showToast(Loc.t("This document isn’t in a sync library"))
        }
        syncHistory = SyncHistoryState()
        Task {
            do {
                let items = try await syncCenter.history(for: url)
                syncHistory?.items = items
            } catch {
                syncHistory?.error = String(describing: error)
            }
            syncHistory?.loading = false
        }
    }

    public func closeSyncHistory() { syncHistory = nil }

    /// Puts a revision's content in the document as one undo step.
    public func restoreRevision(_ head: HeadRecord) {
        guard let url = documentURL else { return }
        syncHistory?.restoring = head.revision
        Task {
            do {
                let m = try await syncCenter.model(for: url, revision: head)
                applyRevision(m, from: head)
                syncHistory = nil
            } catch {
                syncHistory?.restoring = nil
                syncHistory?.error = String(describing: error)
            }
        }
    }

    public func applyRevision(_ m: DocumentModel, from head: HeadRecord) {
        store.commitDocument(Loc.t("Restore Revision"), focus: m.canvasOrder.first ?? canvasID) { d in
            d.canvases = m.canvases
            d.canvasOrder = m.canvasOrder
            d.theme = m.theme
            for (k, v) in m.assets where d.assets[k] == nil { d.assets[k] = v }
        }
        showToast(
            Loc.f(
                "Restored the version from %@ · ⌘Z undoes", head.date.formatted(date: .abbreviated, time: .shortened)))
    }
}
