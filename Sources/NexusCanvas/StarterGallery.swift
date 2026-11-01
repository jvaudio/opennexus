import CoreGraphics
import Foundation
import NexusCore
import NexusScene
import Observation

/// The starter picker's state (M40): which starters show, which one is selected, and what
/// Create does. The sheet behind ⌘T and the tab bar's +, and Home's Templates section,
/// share it. M50 adds the collections, Favourites and My Starters.
@MainActor
@Observable
public final class StarterGallery {
    public enum Section: Hashable, Sendable {
        case all, recent, favourites, forYou, mine, blank
        case collection(StarterCollection)

        public var title: String {
            switch self {
            case .all: Loc.t("All")
            case .recent: Loc.t("Recent")
            case .favourites: Loc.t("Favourites")
            case .forYou: Loc.t("For You")
            case .mine: Loc.t("My Starters")
            case .blank: Loc.t("Blank Diagrams")
            case .collection(let c): Loc.t(c.title)
            }
        }
    }

    /// What Create makes: a canvas in this document (⌘T, +), or a new document (Home, File ›
    /// New Document from Starter…).
    public enum Purpose: Sendable { case canvas, document }

    public var section: Section = .all { didSet { keepSelectionVisible() } }
    public var query = "" { didSet { keepSelectionVisible() } }
    public var selection: String?
    /// Cards per row; ↑ and ↓ move by a row.
    public var columns = 4
    public let purpose: Purpose
    public var role: Role
    @ObservationIgnored let prefs: Preferences
    /// The user's own starters.
    @ObservationIgnored public let mine: MyStarters
    /// Bumped when My Starters or Favourites change, so the lists redraw.
    public private(set) var revision = 0
    /// A line under the grid: what just happened, with Undo after a delete.
    public var notice: String?
    /// The starter Delete removed, until Undo or the next change.
    public private(set) var deleted: Starter?
    @ObservationIgnored public var onChoose: (Starter) -> Void = { _ in }
    @ObservationIgnored public var onCancel: () -> Void = {}
    /// Reads a starter from a URL through the network service; nil while it's off (M50).
    @ObservationIgnored public var readURL: ((URL) async throws -> Data)?
    @ObservationIgnored private var lastChoice = Date.distantPast

    public init(purpose: Purpose, prefs: Preferences = .shared, role: Role? = nil, mine: MyStarters = .shared) {
        self.purpose = purpose
        self.prefs = prefs
        self.mine = mine
        self.role = role ?? Role(rawValue: prefs.string("general.role")) ?? .engineer
        // Focus starts on the starter used last, so ⌘T ↩ repeats it.
        selection = StarterLibrary.lastUsed(prefs: prefs, mine: mine).id
    }

    /// A built-in or one of the user's own.
    func starter(_ id: String) -> Starter? { StarterLibrary.starter(id, mine: mine) }

    public var recent: [Starter] {
        _ = revision
        return StarterHistory(prefs.defaults).recent.compactMap(starter)
    }

    public var favourites: [Starter] {
        _ = revision
        return StarterFavourites(prefs.defaults).ids.compactMap(starter)
    }

    /// The sidebar: All, Recent and Favourites (once there are some), For You, My Starters,
    /// Blank Diagrams, then the collections.
    public var sections: [Section] {
        [.all] + (recent.isEmpty ? [] : [.recent]) + (favourites.isEmpty ? [] : [.favourites]) + [
            .forYou, .mine, .blank,
        ]
            + StarterCollection.allCases.map { .collection($0) }
    }

    /// The section's starters before the search field narrows them.
    public func starters(in section: Section) -> [Starter] {
        _ = revision
        switch section {
        case .all: return StarterLibrary.all + mine.all
        case .recent: return recent
        case .favourites: return favourites
        // The role from onboarding: its Home shelf, then the Blank starters of its kinds of work.
        case .forYou:
            return StarterLibrary.shelf(role.shelf)
                + StarterLibrary.blanks.filter { role.categories.contains($0.category) }
        case .mine: return mine.all
        case .blank: return StarterLibrary.blanks
        case .collection(let c): return (StarterLibrary.templates + mine.all).filter { $0.collection == c }
        }
    }

    /// The cards shown, in order.
    public var visible: [Starter] { Self.search(query, in: starters(in: section)) }

    public var selected: Starter? { selection.flatMap { id in visible.first { $0.id == id } } }

    /// Starters matching every word of the query, in names first, then aliases, kinds,
    /// categories and collections, then summaries. An empty query keeps them all, in order.
    public static func search(_ query: String, in starters: [Starter]) -> [Starter] {
        let words = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        guard !words.isEmpty else { return starters }
        let scored: [(score: Int, index: Int, starter: Starter)] = starters.enumerated().compactMap { i, s in
            let fields: [[String]] = [
                [Loc.t(s.name), s.name],
                s.aliases + [Loc.t(s.kicker), s.kicker, Loc.t(s.category.title), s.category.title, s.category.rawValue]
                    + [Loc.t(DiagramDescriptor[s.type].name), DiagramDescriptor[s.type].name]
                    + (s.collection.map { [Loc.t($0.title), $0.title] } ?? []),
                [Loc.t(s.summary), s.summary],
            ].map { $0.map(fold) }
            var worst = 0
            for w in words {
                guard let rank = fields.firstIndex(where: { $0.contains { $0.contains(w) } }) else { return nil }
                // A name that starts with the word ranks above one that merely contains it.
                let starts = rank == 0 && fields[0].contains { $0.hasPrefix(w) }
                worst = max(worst, starts ? 0 : rank + 1)
            }
            return (worst, i, s)
        }
        return scored.sorted { ($0.score, $0.index) < ($1.score, $1.index) }.map(\.starter)
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Arrow keys: ← → by a card, ↑ ↓ by a row, stopping at the ends.
    public func move(dx: Int = 0, dy: Int = 0) {
        let v = visible
        guard !v.isEmpty else { return }
        let i = selection.flatMap { id in v.firstIndex { $0.id == id } } ?? 0
        let j = min(max(i + dx + dy * max(columns, 1), 0), v.count - 1)
        selection = v[j].id
    }

    /// ↩, Create or a double-click. Runs once when several of those arrive together (↩ in
    /// the search field also presses the default button).
    public func choose(_ starter: Starter? = nil) {
        guard let s = starter ?? selected, Date().timeIntervalSince(lastChoice) > 0.5 else { return }
        lastChoice = Date()
        StarterHistory(prefs.defaults).note(s.id)
        onChoose(s)
    }

    public func cancel() { onCancel() }

    // MARK: Favourites and My Starters (M50)

    public func isFavourite(_ s: Starter) -> Bool {
        _ = revision
        return StarterFavourites(prefs.defaults).ids.contains(s.id)
    }

    /// The card's star and ⌘D.
    public func toggleFavourite(_ s: Starter? = nil) {
        guard let s = s ?? selected else { return }
        StarterFavourites(prefs.defaults).toggle(s.id)
        changed()
    }

    /// Rename, Edit Details… and Move to.
    public func update(_ s: Starter, _ body: (inout Starter) -> Void) {
        attempt { try mine.update(s.id, body) }
    }

    /// Delete: gone at once, with Undo in the notice.
    public func delete(_ s: Starter) {
        attempt {
            deleted = try mine.remove(s.id)
            notice = Loc.f("Deleted “%@”", s.name)
        }
    }

    public func undoDelete() {
        guard let s = deleted else { return }
        attempt {
            try mine.restore(s)
            selection = s.id
        }
    }

    /// The starters a file holds, and which of them you have already, before installing.
    public struct Install: Identifiable {
        public let id = UUID()
        public var starters: [Starter]
        public var clashes: [Starter]

        public init(starters: [Starter], clashes: [Starter]) {
            self.starters = starters
            self.clashes = clashes
        }
    }

    /// Reads a file to install (Install Starter…, a drop, a URL): a preview, or a notice
    /// saying why it was refused.
    public func preview(_ data: Data, name: String) -> Install? {
        do {
            let s = try StarterFile.read(data, name: name)
            return Install(starters: s, clashes: mine.clashes(s))
        } catch {
            notice = (error as? StarterFile.Refusal)?.message ?? error.localizedDescription
            return nil
        }
    }

    public func install(_ i: Install, clash: MyStarters.Clash) {
        attempt {
            let done = try mine.install(i.starters, clash: clash)
            section = .mine
            selection = done.first?.id
            notice =
                done.count == 1
                ? Loc.f("Installed “%@”", done[0].name)
                : Loc.n("Installed %lld starter", "Installed %lld starters", done.count)
        }
    }

    private func attempt(_ body: () throws -> Void) {
        notice = nil
        deleted = nil
        do { try body() } catch { notice = error.localizedDescription }
        changed()
    }

    private func changed() {
        revision += 1
        keepSelectionVisible()
    }

    /// Start with Guide (M41), remembered per starter: on at first for a Blank starter whose
    /// type has a guide, off for a template (it's filled in already).
    public static func startsWithGuide(_ s: Starter, prefs: Preferences) -> Bool {
        guard GuideLibrary.guide(for: s.type) != nil else { return false }
        return prefs.defaults.object(forKey: "starters.guide.\(s.id)") as? Bool ?? s.isBlank
    }

    /// The selected starter's Start with Guide, for the footer's checkbox.
    public var startsWithGuide: Bool {
        get {
            _ = guideChoices
            return selected.map { Self.startsWithGuide($0, prefs: prefs) } ?? false
        }
        set {
            guard let s = selected else { return }
            prefs.defaults.set(newValue, forKey: "starters.guide.\(s.id)")
            guideChoices += 1
        }
    }
    /// Bumped when a choice changes, so the checkbox redraws.
    private var guideChoices = 0

    /// Filtering keeps the selection when it still shows, and otherwise selects the first card.
    private func keepSelectionVisible() {
        let v = visible
        if let id = selection, v.contains(where: { $0.id == id }) { return }
        selection = v.first?.id
    }
}

/// The starters marked with a star, newest first: the picker's Favourites (M50).
struct StarterFavourites {
    static let key = "starters.favourites"
    let defaults: UserDefaults

    init(_ defaults: UserDefaults) { self.defaults = defaults }

    var ids: [String] { defaults.stringArray(forKey: Self.key) ?? [] }

    func toggle(_ id: String) {
        let now = ids
        defaults.set(now.contains(id) ? now.filter { $0 != id } : [id] + now, forKey: Self.key)
    }
}

/// The starters used last, newest first: the picker's Recent, and where it opens.
struct StarterHistory {
    static let key = "starters.recent"
    static let limit = 8
    let defaults: UserDefaults

    init(_ defaults: UserDefaults) { self.defaults = defaults }

    var recent: [String] { defaults.stringArray(forKey: Self.key) ?? [] }

    func note(_ id: String) {
        defaults.set(Array(([id] + recent.filter { $0 != id }).prefix(Self.limit)), forKey: Self.key)
    }
}

extension StarterLibrary {
    /// The starter ⌥-click on + and a picker turned off use: the last one, or a Blank mind
    /// map (what ⌘N makes).
    @MainActor
    public static func lastUsed(prefs: Preferences, mine: MyStarters = .shared) -> Starter {
        StarterHistory(prefs.defaults).recent.lazy.compactMap { starter($0, mine: mine) }.first ?? blanks[0]
    }
}

extension Role {
    /// The picker's kinds of work for this role (its For You section).
    var categories: Set<StarterCategory> {
        switch self {
        case .engineer: [.process, .software]
        case .architect: [.architecture, .software]
        case .security: [.security]
        case .planner: [.thinking, .planning]
        }
    }
}

extension CanvasController {
    /// A new canvas (tab) in this document from a starter (M40): one undo step, then a
    /// caret on its root. A Blank starter takes the new-document settings and default look,
    /// as ⌘T always did; a template is built as written.
    @discardableResult
    public func addCanvas(from starter: Starter) -> CanvasID {
        var id = store.model.makeCanvasID()
        let prefs = prefs
        store.commitDocument(Loc.t("New Canvas"), focus: id) { d in
            var c: Canvas
            if starter.isBlank {
                c = Canvas(
                    id: id, title: "Map \(d.canvases.count + 1)", type: starter.type,
                    rootText: DiagramDescriptor[starter.type].rootText)
                CanvasController.applyDefaults(&c, prefs: prefs)
            } else if let saved = starter.saved {
                // A saved starter's canvas, with its assets, under a fresh id.
                id = d.add(saved.orderedCanvases, assets: saved.assets)[0]
                return
            } else {
                c = starter.canvas(id: id)
            }
            d.canvases[id] = c
            d.canvasOrder.append(id)
        }
        StarterHistory(prefs.defaults).note(starter.id)
        switchCanvas(to: id)
        if starter.isBlank { beginEditing(replacingWith: "") } else { beginEditing(selectAll: true) }
        return id
    }
}
