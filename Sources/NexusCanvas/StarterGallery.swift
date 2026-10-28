import AppKit
import NexusCore
import Observation

/// The starter picker's state (M40): which starters show, which one is selected, and what
/// Create does. The sheet behind ⌘T and the tab bar's +, and Home's Templates section,
/// share it.
@MainActor
@Observable
public final class StarterGallery {
    public enum Section: Hashable, Sendable {
        case all, recent, forYou
        case category(StarterCategory)

        public var title: String {
            switch self {
            case .all: Loc.t("All")
            case .recent: Loc.t("Recent")
            case .forYou: Loc.t("For You")
            case .category(let c): c.title
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
    @ObservationIgnored public var onChoose: (Starter) -> Void = { _ in }
    @ObservationIgnored public var onCancel: () -> Void = {}
    @ObservationIgnored private var lastChoice = Date.distantPast

    public init(purpose: Purpose, prefs: Preferences = .shared, role: Role? = nil) {
        self.purpose = purpose
        self.prefs = prefs
        self.role = role ?? Role(rawValue: prefs.string("general.role")) ?? .engineer
        // Focus starts on the starter used last, so ⌘T ↩ repeats it.
        selection = StarterLibrary.lastUsed(prefs: prefs).id
    }

    public var recent: [Starter] { StarterHistory(prefs.defaults).recent.compactMap(StarterLibrary.starter) }

    /// The sidebar: All, Recent (once something was used), For You, then the categories.
    public var sections: [Section] {
        [.all] + (recent.isEmpty ? [] : [.recent]) + [.forYou] + StarterCategory.allCases.map { .category($0) }
    }

    /// The section's starters before the search field narrows them.
    public func starters(in section: Section) -> [Starter] {
        switch section {
        case .all: StarterLibrary.all
        case .recent: recent
        // The role from onboarding: its Home shelf, then the Blank starters of its kinds of work.
        case .forYou:
            StarterLibrary.shelf(role.shelf)
                + StarterLibrary.blanks.filter { role.categories.contains($0.category) }
        case .category(let c): StarterLibrary.all.filter { $0.category == c }
        }
    }

    /// The cards shown, in order.
    public var visible: [Starter] { Self.search(query, in: starters(in: section)) }

    public var selected: Starter? { selection.flatMap { id in visible.first { $0.id == id } } }

    /// Starters matching every word of the query, in names first, then aliases, kinds and
    /// categories, then summaries. An empty query keeps them all, in order.
    public static func search(_ query: String, in starters: [Starter]) -> [Starter] {
        let words = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        guard !words.isEmpty else { return starters }
        let scored: [(score: Int, index: Int, starter: Starter)] = starters.enumerated().compactMap { i, s in
            let fields: [[String]] = [
                [Loc.t(s.name), s.name],
                s.aliases + [Loc.t(s.kicker), s.kicker, s.category.title, s.category.rawValue]
                    + [Loc.t(DiagramDescriptor[s.type].name), DiagramDescriptor[s.type].name],
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

    /// Filtering keeps the selection when it still shows, and otherwise selects the first card.
    private func keepSelectionVisible() {
        let v = visible
        if let id = selection, v.contains(where: { $0.id == id }) { return }
        selection = v.first?.id
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
    public static func lastUsed(prefs: Preferences) -> Starter {
        StarterHistory(prefs.defaults).recent.lazy.compactMap(starter).first ?? blanks[0]
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
        let id = store.model.makeCanvasID()
        let prefs = prefs
        store.commitDocument(Loc.t("New Canvas"), focus: id) { d in
            var c: Canvas
            if starter.isBlank {
                c = Canvas(
                    id: id, title: "Map \(d.canvases.count + 1)", type: starter.type,
                    rootText: DiagramDescriptor[starter.type].rootText)
                CanvasController.applyDefaults(&c, prefs: prefs)
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

/// Starter thumbnails (M40): each starter's map, drawn offscreen by the exporter and kept
/// for the session per starter, appearance and scale.
@MainActor
enum StarterThumbnails {
    /// The card's picture area, in points.
    static let size = CGSize(width: 220, height: 124)
    private static var cache: [String: CGImage] = [:]

    static func key(_ s: Starter, dark: Bool, scale: CGFloat) -> String {
        "\(s.id)|\(dark ? "dark" : "light")|\(scale)"
    }

    static func cached(_ s: Starter, dark: Bool, scale: CGFloat) -> CGImage? { cache[key(s, dark: dark, scale: scale)] }

    /// Renders (or recalls) the thumbnail.
    static func image(_ s: Starter, prefs: Preferences, dark: Bool, scale: CGFloat) -> CGImage? {
        let k = key(s, dark: dark, scale: scale)
        if let c = cache[k] { return c }
        let doc = s.document(prefs: prefs)
        guard let id = doc.canvasOrder.first else { return nil }
        var o = ImageExporter.Options()
        o.padding = 28
        let r = ImageExporter.contentRect(doc, canvas: id, o)
        // Fit the map in the card at the screen's scale (never enlarge a small one past 1:1).
        o.scale = Double(min(scale, size.width * scale / r.width, size.height * scale / r.height))
        var img: CGImage?
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            img = ImageExporter.image(doc, canvas: id, o)
        }
        cache[k] = img
        return img
    }
}
