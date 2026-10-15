import AppKit
import NexusCore
import NexusKeys
import NexusLayout
import NexusTheme

public enum CanvasViewMode: String, Sendable { case canvas, outline, split }

// MARK: Palette & jump (artboard 25)

public struct PaletteRow: Identifiable, Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case command(CommandID)
        case selectByType(NodeType)
        case rebind(CommandID)
    }
    public var id: String
    public var section: String
    public var title: String
    public var subtitle: String
    public var glyph: String
    public var keys: String?
    public var hyper: String?
    public var action: Action
    /// Indices into `title` that matched the query (drawn in the accent colour).
    public var matched: [Int] = []
}

public struct PaletteState: Equatable, Sendable {
    public var query = ""
    public var highlighted = 0
    public var showDetails = false
}

public struct JumpRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var path: String
    public var badge: String
    public var color: RGBA
    public var canvas: CanvasID
    public var node: NodeID?
    public var matched: [Int] = []
}

public struct JumpState: Equatable, Sendable {
    public var query = ""
    public var highlighted = 0
}

// MARK: Search & present

public struct SearchState: Equatable, Sendable {
    public var query = ""
    public var replacement = ""
    public var options = SearchOptions()
    public var matches: [SearchMatch] = []
    public var current = 0
}

public struct PresentState: Equatable, Sendable {
    public var index = 0
    /// The stage fills the window (F); otherwise the slide strip shows below.
    public var stageOnly = false
    public var showKeys = false
    public var started = Date()
}

/// Fuzzy subsequence match: returns a score (higher is better) and matched indices.
enum Fuzzy {
    static func match(_ query: String, in text: String) -> (Int, [Int])? {
        let q = Array(query.lowercased())
        let t = Array(text.lowercased())
        guard !q.isEmpty else { return (0, []) }
        // Prefer a contiguous hit (prefix, then word start, then anywhere).
        if let r = text.lowercased().range(of: String(q)) {
            let start = text.distance(from: text.startIndex, to: r.lowerBound)
            let wordStart = start == 0 || !t[start - 1].isLetter
            return ((start == 0 ? 1000 : wordStart ? 700 : 400) - start, Array(start..<start + q.count))
        }
        var idx: [Int] = []
        var j = 0
        for (i, c) in t.enumerated() where j < q.count && c == q[j] {
            idx.append(i)
            j += 1
        }
        guard j == q.count else { return nil }
        let spread = (idx.last ?? 0) - (idx.first ?? 0)
        return (200 - spread - (idx.first ?? 0), idx)
    }
}

extension CanvasController {
    // MARK: View state for the scene

    func currentViewState() -> SceneViewState {
        var v = SceneViewState()
        v.isolate = isolate
        applyPreferenceView(&v)
        if let g = ghosts {
            v.ghosts = g.ideas.map { SceneViewState.Ghost(parent: g.anchor, parentGhost: $0.parentGhost, idea: $0) }
            v.ghostHighlight = g.ideas.isEmpty ? nil : g.highlighted
        } else if let plan = previewPlan {
            var addIndex: [Int] = []
            for op in plan.ops {
                if case .add(let p, let pa, let text, let markers, let labels, let todo) = op {
                    v.ghosts.append(
                        SceneViewState.Ghost(
                            parent: p, parentGhost: pa.flatMap { $0 < addIndex.count ? addIndex[$0] : nil },
                            idea: GhostIdea(text: text, markers: markers, labels: labels, todo: todo)))
                    addIndex.append(v.ghosts.count - 1)
                }
            }
        }
        v.focus = focusRoot
        let c = canvas
        let all = c.tops.flatMap { c.subtree($0, includeFolded: false) }
        if let p = present {
            let slides = Deck.slides(c)
            if p.index < slides.count {
                let s = slides[p.index]
                let focus = Set(s.focus)
                // The title slide shows everything; steps dim what they don't involve.
                v.dimmed = s.highlight.isEmpty ? [] : Set(all.filter { !Set(s.highlight).contains($0) })
                v.dimOpacity = s.flow != nil ? 0.38 : 0.3
                if s.flow == nil, !s.highlight.isEmpty {
                    v.dimmed = Set(all.filter { !focus.contains($0) })
                }
                v.glow = s.flow != nil ? Set(s.highlight.suffix(1)) : []
                v.flowGlow = s.flow
            }
            v.hidden = Set(all.filter { c.nodes[$0]?.presentHidden == true })
            return v
        }
        if !filterClauses.isEmpty {
            let f = NodeFilter(clauses: filterClauses, hide: filterHides)
            let hits = Set(f.matching(in: c))
            let miss = Set(all.filter { !hits.contains($0) })
            if filterHides { v.hidden = miss } else { v.dimmed = miss }
            v.dimOpacity = 0.25
        }
        if !tagHighlight.isEmpty {
            let hits = Set(
                all.filter { id in
                    guard let n = c.nodes[id] else { return false }
                    return tagHighlight.contains { k in
                        k.hasPrefix("marker:")
                            ? n.markers.contains(String(k.dropFirst(7))) : n.labels.contains(String(k.dropFirst(6)))
                    }
                })
            v.dimmed.formUnion(all.filter { !hits.contains($0) })
            v.dimOpacity = 0.3
        }
        if navTab == 1, !search.query.isEmpty {
            for m in search.matches where m.canvas == canvasID {
                v.glow.insert(m.node)
                if m.field == .text { v.matches[m.node, default: []].append(m.range) }
            }
        }
        return v
    }

    func refreshView(frame ids: [NodeID]? = nil, aspect: Double? = nil) {
        rebuildScene()
        onSceneChange?(true)
        if let ids { onFrame?(ids, aspect) }
    }

    // MARK: Command palette (⌘K)

    public func openPalette() {
        if mode == .edit { commitEdit() }
        jump = nil
        palette = PaletteState()
    }

    public func closePalette() { palette = nil }

    static let recentKey = "palette.recent"
    var recentCommands: [String] { prefs.defaults.stringArray(forKey: Self.recentKey) ?? [] }

    func noteRecent(_ id: CommandID) {
        var r = recentCommands.filter { $0 != id.rawValue }
        r.insert(id.rawValue, at: 0)
        prefs.defaults.set(Array(r.prefix(12)), forKey: Self.recentKey)
    }

    func canRun(_ id: CommandID) -> Bool {
        if externalCommands.contains(id) { return true }
        if id == .palette || id == .connectConfirm || id == .connectCancel { return false }
        let d = registry[id]
        if d?.scope == .editor || d?.scope == .find || d?.scope == .connect { return false }
        return canPerform(id)
    }

    /// Rows for the palette: context-aware (commands that can't run are hidden), recent
    /// first, then fuzzy match.
    public var paletteRows: [PaletteRow] {
        let q = palette?.query.trimmingCharacters(in: .whitespaces) ?? ""
        let recent = recentCommands
        var rows: [(Int, PaletteRow)] = []
        for d in registry.commands where canRun(d.id) {
            let keys = bindings(for: d.id).first?.glyphs
            let hyper = d.hyper.map { "✦ " + $0.glyphs.replacingOccurrences(of: "✦", with: "") }
            let section = d.category == .ai ? "AI · ON-DEVICE" : "COMMANDS"
            let rank = recent.firstIndex(of: d.id.rawValue).map { 2000 - $0 * 10 } ?? 0
            let base = PaletteRow(
                id: d.id.rawValue, section: section, title: Loc.t(d.title),
                subtitle: Loc.t(d.note.isEmpty ? d.category.rawValue : d.note),
                glyph: Self.glyph(for: d), keys: keys, hyper: hyper, action: .command(d.id))
            if q.isEmpty {
                rows.append((rank, base))
            } else if let (score, idx) = Fuzzy.match(q, in: base.title) {
                var r = base
                r.matched = idx
                rows.append((score + rank / 4, r))
            } else if q.count > 2, Fuzzy.match(q, in: d.note) != nil {
                rows.append((50 + rank / 4, base))
            }
        }
        // Select by type · X for the node types on this canvas.
        let c = canvas
        var typeCount: [NodeType: Int] = [:]
        let parents = c.parentMap()
        for id in c.nodes.keys {
            if let t = DiagramCatalog.effectiveType(id, in: c, parents: parents) { typeCount[t, default: 0] += 1 }
        }
        for (t, n) in typeCount.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let name = DiagramCatalog.info(t, in: c.type)?.name ?? t.rawValue
            let title = "Select by type · \(name)"
            let row = PaletteRow(
                id: "type:\(t.rawValue)", section: "COMMANDS", title: title,
                subtitle: Loc.n("%lld node on this canvas", "%lld nodes on this canvas", n), glyph: "◎", keys: nil,
                hyper: nil,
                action: .selectByType(t))
            if q.isEmpty {
                continue
            } else if let (score, idx) = Fuzzy.match(q, in: title) {
                var r = row
                r.matched = idx
                rows.append((score - 100, r))
            }
        }
        var out = rows.sorted { a, b in a.0 != b.0 ? a.0 > b.0 : a.1.title < b.1.title }.map(\.1)
        // Settings: rebind the top command.
        if !q.isEmpty, let top = out.first, case .command(let id) = top.action {
            out.append(
                PaletteRow(
                    id: "rebind:\(id.rawValue)", section: "SETTINGS", title: "Shortcuts › \(top.title)", subtitle: "",
                    glyph: "⚙", keys: nil, hyper: nil, action: .rebind(id)))
        }
        // Sections in order; the top row overall is what ↩ runs.
        let order = ["COMMANDS", "AI · ON-DEVICE", "SETTINGS"]
        return Array(order.flatMap { s in out.filter { $0.section == s } }.prefix(40))
    }

    static func glyph(for d: CommandDescriptor) -> String {
        switch d.category {
        case .create: "+"
        case .edit: "✎"
        case .navigate: "⌕"
        case .restructure: "⇅"
        case .elements: "—"
        case .style: "◐"
        case .view: "▣"
        case .ai: "✦"
        case .file: "⧉"
        case .app: "⌘"
        }
    }

    func handlePaletteKey(_ chord: KeyChord, characters: String?) -> Bool {
        guard var p = palette else { return false }
        let rows = paletteRows
        switch chord.key {
        case .escape:
            palette = nil
            return true
        case .up: p.highlighted = max(0, p.highlighted - 1)
        case .down: p.highlighted = min(max(rows.count - 1, 0), p.highlighted + 1)
        case .tab: p.showDetails.toggle()
        case .return:
            guard p.highlighted < rows.count else { return true }
            let keep = chord.modifiers.contains(.command)
            runPaletteRow(rows[p.highlighted], keepOpen: keep)
            return true
        case .delete:
            if !p.query.isEmpty { p.query.removeLast() }
            p.highlighted = 0
        default:
            guard chord.modifiers.subtracting(.shift).isEmpty, let c = characters, !c.isEmpty,
                c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return true }
            p.query += c
            p.highlighted = 0
        }
        palette = p
        return true
    }

    public func runPaletteRow(_ row: PaletteRow, keepOpen: Bool = false) {
        if !keepOpen { palette = nil }
        switch row.action {
        case .command(let id):
            noteRecent(id)
            if externalCommands.contains(id) {
                onExternalCommand?(id)
            } else {
                _ = perform(id)
            }
        case .selectByType(let t):
            let c = canvas
            let parents = c.parentMap()
            let ids = c.tops.flatMap { c.subtree($0) }.filter {
                DiagramCatalog.effectiveType($0, in: c, parents: parents) == t
            }
            if let first = ids.first {
                setSelection(Selection(primary: first, nodes: ids))
                onFrame?(ids, nil)
            }
        case .rebind:
            showToast("Rebinding opens in Settings › Shortcuts (M8)")
        }
    }

    // MARK: Quick jump (⌘J)

    public func openJump() {
        if mode == .edit { commitEdit() }
        palette = nil
        jump = JumpState()
    }

    public func closeJump() { jump = nil }

    /// Topics, edges and canvases across the document, best match first.
    public var jumpRows: [JumpRow] {
        let q = jump?.query.trimmingCharacters(in: .whitespaces) ?? ""
        var rows: [(Int, JumpRow)] = []
        for cid in store.model.canvasOrder {
            guard let c = store.model.canvases[cid] else { continue }
            let parents = c.parentMap()
            let canvasTitle = c.title.isEmpty ? (c.nodes[c.root]?.text ?? "Canvas") : c.title
            if let (score, idx) = Fuzzy.match(q, in: canvasTitle) {
                rows.append(
                    (
                        score + 5,
                        JumpRow(
                            id: "c:\(cid.rawValue)", title: canvasTitle, path: "Canvas", badge: "CANVAS",
                            color: theme.critical, canvas: cid, node: nil, matched: idx)
                    ))
            }
            let mains = c.nodes[c.root]?.children ?? []
            for id in c.tops.flatMap({ c.subtree($0) }) {
                guard let n = c.nodes[id], let (score, idx) = Fuzzy.match(q, in: n.text) else { continue }
                let path =
                    ([canvasTitle] + c.path(to: id, parents: parents).dropFirst().compactMap { c.nodes[$0]?.text })
                    .joined(separator: " › ")
                let t = DiagramCatalog.effectiveType(id, in: c, parents: parents)
                let badge =
                    t.flatMap { DiagramCatalog.info($0, in: c.type)?.caption.components(separatedBy: " ").last }
                    ?? (id == c.root ? "ROOT" : "TOPIC")
                let main = c.mainBranch(of: id, parents: parents)
                let color =
                    main.flatMap { mains.firstIndex(of: $0) }.map { theme.palette[$0 % theme.palette.count] }
                    ?? theme.ink
                rows.append(
                    (
                        score + (cid == canvasID ? 3 : 0),
                        JumpRow(
                            id: "n:\(cid.rawValue)/\(id.rawValue)", title: n.text, path: path, badge: badge,
                            color: color,
                            canvas: cid, node: id, matched: idx)
                    ))
                if let l = n.edgeLabel, !l.isEmpty, let (es, ei) = Fuzzy.match(q, in: l) {
                    rows.append(
                        (
                            es - 2,
                            JumpRow(
                                id: "e:\(cid.rawValue)/\(id.rawValue)", title: l, path: "\(path) › flow", badge: "EDGE",
                                color: theme.ink2, canvas: cid, node: id, matched: ei)
                        ))
                }
            }
            for r in c.relationships where !r.label.isEmpty {
                guard let (score, idx) = Fuzzy.match(q, in: r.label) else { continue }
                rows.append(
                    (
                        score - 2,
                        JumpRow(
                            id: "r:\(cid.rawValue)/\(r.id)", title: r.label, path: "\(canvasTitle) › relationship",
                            badge: "EDGE", color: theme.ink2, canvas: cid, node: r.to, matched: idx)
                    ))
            }
        }
        guard !q.isEmpty else {
            // Empty query: canvases, then this canvas's main topics.
            return rows.filter { $0.1.node == nil || ($0.1.canvas == canvasID && $0.1.badge != "EDGE") }.prefix(30).map(
                \.1)
        }
        return Array(rows.sorted { $0.0 > $1.0 }.prefix(50).map(\.1))
    }

    func handleJumpKey(_ chord: KeyChord, characters: String?) -> Bool {
        guard var j = jump else { return false }
        let rows = jumpRows
        switch chord.key {
        case .escape:
            jump = nil
            return true
        case .up: j.highlighted = max(0, j.highlighted - 1)
        case .down: j.highlighted = min(max(rows.count - 1, 0), j.highlighted + 1)
        case .return:
            if j.highlighted < rows.count { goTo(rows[j.highlighted], add: chord.modifiers.contains(.shift)) }
            return true
        case .delete:
            if !j.query.isEmpty { j.query.removeLast() }
            j.highlighted = 0
        default:
            guard chord.modifiers.subtracting(.shift).isEmpty, let c = characters, !c.isEmpty,
                c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return true }
            j.query += c
            j.highlighted = 0
        }
        jump = j
        return true
    }

    /// ↩ flies there and selects; ⇧↩ adds to the selection.
    public func goTo(_ row: JumpRow, add: Bool = false) {
        jump = nil
        if row.canvas != canvasID {
            switchCanvas(to: row.canvas)
        }
        guard let n = row.node, canvas.nodes[n] != nil else {
            onFrame?(scene.nodes.keys.map { $0 }, nil)
            return
        }
        if add && row.canvas == canvasID {
            var nodes = selection.nodes
            if !nodes.contains(n) { nodes.append(n) }
            setSelection(Selection(primary: n, nodes: nodes))
        } else {
            select(n)
        }
        onReveal?(n)
    }

    // MARK: Focus (⌘.)

    public func toggleFocus() {
        let id = selection.primary
        if id == canvas.root || id == focusRoot {
            exitFocus()
            return
        }
        focusRoot = id
        refreshView(frame: canvas.subtree(id, includeFolded: false))
    }

    /// Esc climbs one level out of focus.
    public func climbFocus() {
        guard let f = focusRoot else { return }
        if let p = canvas.parent(of: f), p != canvas.root {
            focusRoot = p
            select(p)
            refreshView(frame: canvas.subtree(p, includeFolded: false))
        } else {
            exitFocus()
        }
    }

    public func exitFocus() {
        guard focusRoot != nil else { return }
        focusRoot = nil
        refreshView(frame: Array(canvas.nodes.keys))
    }

    /// Breadcrumb: Launch plan › Pricing.
    public var focusPath: [NodeID] {
        guard let f = focusRoot else { return [] }
        return canvas.path(to: f) + [f]
    }

    // MARK: Filter bar (⇧⌘F)

    public func toggleFilterBar() {
        filterBarVisible.toggle()
        if !filterBarVisible { clearFilter() }
    }

    public func addFilterClause(_ text: String) {
        guard let c = NodeFilter.parse(text) else { return }
        filterClauses.append(c)
        refreshView()
    }

    public func removeFilterClause(at i: Int) {
        guard i < filterClauses.count else { return }
        filterClauses.remove(at: i)
        refreshView()
    }

    public func setFilterHides(_ hide: Bool) {
        filterHides = hide
        refreshView()
    }

    public func clearFilter() {
        filterClauses = []
        refreshView()
    }

    public func applySavedFilter(_ f: NodeFilter) {
        filterBarVisible = true
        filterClauses = f.clauses
        filterHides = f.hide
        refreshView()
    }

    public var filterMatchCount: (Int, Int) {
        let c = canvas
        let all = c.tops.flatMap { c.subtree($0) }.count
        guard !filterClauses.isEmpty else { return (all, all) }
        return (NodeFilter(clauses: filterClauses).matching(in: c).count, all)
    }

    /// "Open threats · High" from the clause values.
    public var suggestedFilterName: String {
        let vals = filterClauses.map { c in c.op == .notEquals ? "not \(c.value)" : c.value }
        guard !vals.isEmpty else { return "Filter" }
        if filterClauses.contains(where: { $0.field == "type" && $0.value.lowercased() == "threat" }),
            filterClauses.contains(where: { $0.field == "status" && $0.op == .notEquals })
        {
            let risk = filterClauses.first { $0.field == "risk" }?.value
            return "Open threats" + (risk.map { " · \($0)" } ?? "")
        }
        return vals.joined(separator: " · ")
    }

    public func saveFilter(named name: String? = nil) {
        guard !filterClauses.isEmpty else { return }
        let f = NodeFilter(name: name ?? suggestedFilterName, clauses: filterClauses, hide: filterHides)
        perform("Save Filter") { e in
            e.updateMeta {
                $0.filters.removeAll { $0.name == f.name }; $0.filters.append(f)
            }
        }
        showToast("Saved “\(f.name)”")
    }

    // MARK: Tags (navigation panel)

    /// Click highlights; ⇧-click combines.
    public func toggleTag(_ key: String, combine: Bool) {
        if combine {
            if tagHighlight.contains(key) { tagHighlight.remove(key) } else { tagHighlight.insert(key) }
        } else {
            tagHighlight = tagHighlight == [key] ? [] : [key]
        }
        refreshView()
    }

    public var tagCounts: [(key: String, title: String, count: Int, color: RGBA)] {
        var markers: [String: Int] = [:]
        var labels: [String: Int] = [:]
        for n in canvas.nodes.values {
            for m in n.markers { markers[m, default: 0] += 1 }
            for l in n.labels { labels[l, default: 0] += 1 }
        }
        let m = markers.sorted { $0.key < $1.key }.map { k, v -> (String, String, Int, RGBA) in
            let mk = MarkerLibrary.marker(k)
            let group = MarkerLibrary.groups.first { g in g.markers.contains { $0.id == k } }?.name ?? k
            return ("marker:\(k)", "\(mk?.glyph ?? "") \(group)", v, mk.map { RGBA(hex: $0.color) } ?? theme.ink2)
        }
        let l = labels.sorted { $0.key < $1.key }.map { ("label:\($0.key)", $0.key, $0.value, theme.ink2) }
        return (m + l).map { (key: $0.0, title: $0.1, count: $0.2, color: $0.3) }
    }

    public func toggleTodo(_ id: NodeID) {
        perform("To-do") { $0.update(id) { $0.todo?.done.toggle() } }
    }

    // MARK: Find & replace (⌘F, navigation panel)

    public func openSearch() {
        navTab = 1
        searchFocusSerial += 1
        refreshView()
    }

    public func updateSearch(query: String? = nil, replacement: String? = nil, options: SearchOptions? = nil) {
        if let query { search.query = query }
        if let replacement { search.replacement = replacement }
        if let options { search.options = options }
        search.matches = TextSearch.find(search.query, search.options, in: store.model, current: canvasID)
        search.current = min(search.current, max(search.matches.count - 1, 0))
        refreshView()
    }

    /// ↩ next, ⇧↩ previous: selects the match's topic (switching canvas if needed).
    public func stepSearch(_ delta: Int) {
        guard !search.matches.isEmpty else { return }
        let n = search.matches.count
        search.current = ((search.current + delta) % n + n) % n
        let m = search.matches[search.current]
        if m.canvas != canvasID { switchCanvas(to: m.canvas) }
        select(m.node)
        refreshView()
        onReveal?(m.node)
    }

    /// ⌥↩: replace the current match.
    public func replaceCurrent() {
        guard search.current < search.matches.count else { return }
        let m = search.matches[search.current]
        replace([m])
    }

    /// ⌥⌘↩: replace every match (one undo step per canvas).
    public func replaceAllMatches() {
        let n = search.matches.count
        replace(search.matches)
        showToast(Loc.n("Replaced %lld match", "Replaced %lld matches", n))
    }

    func replace(_ matches: [SearchMatch]) {
        let q = search.query
        let r = search.replacement
        let o = search.options
        for cid in Set(matches.map(\.canvas)) {
            let mine = matches.filter { $0.canvas == cid }
            if cid == canvasID {
                perform("Replace") { e in _ = TextSearch.replace(mine, query: q, with: r, o, in: &e) }
            } else if let c = store.canvas(cid) {
                var e = CanvasEditor(c)
                _ = TextSearch.replace(mine, query: q, with: r, o, in: &e)
                let patch = e.patch(actionName: "Replace")
                if !patch.isEmpty { store.commit(patch) }
            }
        }
        updateSearch()
    }

    // MARK: ZEN (⌥⌘F)

    public func toggleZen() {
        zen.toggle()
        if zen { zenStarted = Date() } else if let s = zenStarted { addZenTime(Date().timeIntervalSince(s)) }
        onZen?(zen)
        rebuildScene()
        onSceneChange?(false)
    }

    // MARK: Present (⇧⌘P)

    public var slides: [Slide] { Deck.slides(canvas) }

    public func startPresent(at index: Int = 0) {
        if mode == .edit { commitEdit() }
        focusRoot = nil
        palette = nil
        jump = nil
        present = PresentState(index: index)
        onPresent?(true)
        showSlide()
    }

    public func endPresent() {
        guard present != nil else { return }
        present = nil
        onPresent?(false)
        refreshView(frame: Array(canvas.nodes.keys))
    }

    func showSlide() {
        guard let p = present else { return }
        let s = slides
        guard p.index < s.count else { return }
        let slide = s[p.index]
        refreshView(
            frame: slide.focus.isEmpty ? Array(canvas.nodes.keys) : slide.focus, aspect: canvas.presentation.aspectRatio
        )
    }

    /// → / ←, skipping skipped slides.
    public func stepSlide(_ delta: Int) {
        guard var p = present else { return }
        let s = slides
        var i = p.index
        repeat { i += delta } while i >= 0 && i < s.count && s[i].skipped
        guard i >= 0 && i < s.count else { return }
        p.index = i
        present = p
        showSlide()
    }

    public func goToSlide(_ i: Int) {
        present?.index = max(0, min(i, slides.count - 1))
        showSlide()
    }

    public func setPresentation(_ name: String, _ body: @escaping (inout PresentationSettings) -> Void) {
        perform(name) { e in e.updateMeta { body(&$0.presentation) } }
        showSlide()
    }

    func handlePresentKey(_ chord: KeyChord, characters raw: String?) -> Bool {
        guard var p = present else { return false }
        // ⇧/ is "?" on US layouts even when the event reports "/".
        let characters = chord.key == .character("/") && chord.modifiers.contains(.shift) ? "?" : raw
        let s = slides
        let slide = p.index < s.count ? s[p.index] : nil
        if p.showKeys, chord.key == .escape || characters == "?" {
            p.showKeys = false
            present = p
            return true
        }
        switch (chord.key, characters?.lowercased()) {
        case (.escape, _): endPresent()
        case (.right, _), (.space, _), (.return, _), (.down, _): stepSlide(1)
        case (.left, _), (.up, _): stepSlide(-1)
        case (_, "s"?):
            if let slide {
                perform(slide.skipped ? "Include Slide" : "Skip Slide") { $0.toggleSkip(slide.id) }
                showSlide()
            }
        case (_, "m"?):
            if let slide, p.index + 1 < s.count {
                perform("Merge Slides") { $0.toggleMerge(slide.id) }
                showSlide()
            }
        case (_, "h"?):
            // Hide the slide's own topic (or the selection) from slides.
            let target =
                slide?.highlight.contains(selection.primary) == true
                ? selection.primary : (slide?.highlight.last ?? selection.primary)
            if target != canvas.root {
                perform("Hide from Slides") { $0.update(target) { $0.presentHidden.toggle() } }
                present?.index = min(p.index, max(slides.count - 1, 0))
                showSlide()
            }
        case (_, "f"?):
            p.stageOnly.toggle()
            present = p
            showSlide()
        case (_, "?"?):
            p.showKeys.toggle()
            present = p
        case (_, "p"?):
            onTogglePresenter?()
        default:
            return true
        }
        return true
    }

    // MARK: Outline (⌘2, ⌘3)

    /// Rows in outline order: the central topic's tree (folds respected), then floating topics.
    public var outlineOrder: [NodeID] {
        let c = canvas
        var out: [NodeID] = []
        func walk(_ id: NodeID) {
            out.append(id)
            guard let n = c.nodes[id], !n.folded else { return }
            n.children.forEach(walk)
        }
        c.tops.filter { !c.summaries.map(\.topic).contains($0) }.forEach(walk)
        return out
    }

    func stepOutline(_ d: Int) {
        let rows = outlineOrder
        guard let i = rows.firstIndex(of: selection.primary) else { return }
        let j = min(max(i + d, 0), rows.count - 1)
        select(rows[j])
        onReveal?(rows[j])
    }

    func outlineCollapse() {
        let id = selection.primary
        if let n = canvas.nodes[id], !n.children.isEmpty, !n.folded {
            restructure("Fold") { try $0.toggleFold(id) }
        } else if let p = canvas.parent(of: id) {
            select(p)
        }
    }

    func outlineExpand() {
        let id = selection.primary
        guard let n = canvas.nodes[id], let first = n.children.first else { return }
        if n.folded {
            restructure("Unfold") { try $0.toggleFold(id) }
        } else {
            select(first)
        }
    }
}
