import AppKit
import NexusCore
import NexusTheme
import SwiftUI

/// Text with matched characters in the accent colour (palette and jump rows).
struct Highlighted: View {
    let text: String
    let matched: [Int]
    var size: CGFloat = 14
    var weight: Font.Weight = .regular

    var body: some View {
        let set = Set(matched)
        var a = AttributedString()
        for (i, ch) in text.enumerated() {
            var piece = AttributedString(String(ch))
            if set.contains(i) {
                piece.foregroundColor = .accentColor
                piece.font = .chrome(size, weight: .semibold)
            }
            a += piece
        }
        return Text(a).font(.chrome(size, weight: weight)).lineLimit(1)
    }
}

// MARK: Command palette (⌘K)

struct PaletteView: View {
    var controller: CanvasController

    var body: some View {
        if let p = controller.palette {
            let rows = controller.paletteRows
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    Text(p.query.isEmpty ? "Type a command…" : p.query)
                        .font(.chrome(20))
                        .foregroundStyle(p.query.isEmpty ? .tertiary : .primary)
                    Spacer()
                    Text("Selection: \(controller.canvas.nodes[controller.selection.primary]?.text ?? "")")
                        .font(.chrome(12))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                }
                .padding(16)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                                if i == 0 || rows[i - 1].section != row.section {
                                    Text(row.section).font(.chrome(11, weight: .semibold)).foregroundStyle(
                                        .secondary
                                    )
                                    .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 4)
                                }
                                paletteRow(row, on: i == p.highlighted, details: p.showDetails && i == p.highlighted)
                                    .id(i)
                                    .accessibleTap { controller.runPaletteRow(row) }
                            }
                            if rows.isEmpty {
                                Text("No command matches “\(p.query)”").foregroundStyle(.secondary).padding(16)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .accessibilityLabel(Loc.t("Commands"))
                    .frame(maxHeight: 460)
                    .onChange(of: p.highlighted) { _, i in proxy.scrollTo(i) }
                }
                Divider()
                HStack(spacing: 14) {
                    Text("↑↓ move")
                    Text("↩ run")
                    Text("⌘↩ run and keep open")
                    Text("⇥ show actions")
                    Spacer()
                    Text("Recent first, then fuzzy match")
                }
                .font(.chrome(12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .frame(width: 640)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator))
            .shadow(color: .black.opacity(0.22), radius: 30, y: 12)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Command palette")
        }
    }

    func paletteRow(_ row: PaletteRow, on: Bool, details: Bool) -> some View {
        HStack(spacing: 12) {
            Text(row.glyph)
                .font(.chrome(13, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.12)))
            VStack(alignment: .leading, spacing: 1) {
                Highlighted(text: row.title, matched: row.matched, size: 14.5)
                if !row.subtitle.isEmpty {
                    Text(row.subtitle).font(.chrome(12)).foregroundStyle(.secondary).lineLimit(details ? 3 : 1)
                }
            }
            Spacer()
            if case .rebind = row.action {
                Text("Rebind").font(.chrome(12)).foregroundStyle(.secondary)
            } else {
                Keycap(text: row.keys ?? "—")
                Text(row.hyper ?? "—")
                    .font(.chrome(11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.85)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(on ? Color.accentColor.opacity(0.14) : .clear))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}

// MARK: Quick jump (⌘J)

struct JumpView: View {
    var controller: CanvasController

    var body: some View {
        if let j = controller.jump {
            let rows = controller.jumpRows
            let canvases = Set(rows.map(\.canvas)).count
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("JUMP")
                        .font(.chrome(11, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black))
                    Text(j.query.isEmpty ? "Jump to a topic, edge or canvas" : j.query)
                        .font(.chrome(20))
                        .foregroundStyle(j.query.isEmpty ? .tertiary : .primary)
                    Spacer()
                    let nodes = rows.filter { $0.node != nil }.count
                    Text("\(nodes) node\(nodes == 1 ? "" : "s") · \(canvases) canvas\(canvases == 1 ? "" : "es")")
                        .font(.chrome(12)).foregroundStyle(.secondary)
                }
                .padding(16)
                Divider()
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            HStack(spacing: 12) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(nsColor: NSColor(cgColor: row.color.cgColor) ?? .gray))
                                    .frame(width: 9, height: 9)
                                VStack(alignment: .leading, spacing: 1) {
                                    Highlighted(text: row.title, matched: row.matched, size: 14.5)
                                    Text(row.path).font(.chrome(12)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text(row.badge).font(.chrome(10.5, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 9).fill(
                                    i == j.highlighted ? Color.accentColor.opacity(0.14) : .clear)
                            )
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                            .accessibleTap { controller.goTo(row) }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .accessibilityLabel(Loc.t("Topics"))
                .frame(maxHeight: 420)
                Divider()
                Text("↩ flies the camera there and selects the node · ⇧↩ adds to selection")
                    .font(.chrome(12)).foregroundStyle(.secondary).padding(12)
            }
            .frame(width: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator))
            .shadow(color: .black.opacity(0.22), radius: 30, y: 12)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Quick jump")
        }
    }
}

// MARK: Filter bar (⇧⌘F) and focus breadcrumb

struct FilterBarView: View {
    var controller: CanvasController
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if controller.filterBarVisible {
            let (hits, all) = controller.filterMatchCount
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ForEach(Array(controller.filterClauses.enumerated()), id: \.offset) { i, c in
                        HStack(spacing: 4) {
                            Text(c.text).font(.chrome(13))
                            Button {
                                controller.removeFilterClause(at: i)
                            } label: {
                                Image(systemName: "xmark").font(.chrome(9, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(c.text)")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(chipColor(c).opacity(0.14)))
                        .foregroundStyle(chipColor(c))
                    }
                    TextField("+ marker, label, text…", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.chrome(13))
                        .frame(width: 180)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .overlay(
                            Capsule().stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(.secondary)
                        )
                        .focused($focused)
                        .onSubmit {
                            controller.addFilterClause(draft)
                            draft = ""
                        }
                        .onExitCommand { controller.toggleFilterBar() }
                    Spacer()
                    Picker(
                        "", selection: Binding(get: { controller.filterHides }, set: { controller.setFilterHides($0) })
                    ) {
                        Text("Dim").tag(false)
                        Text("Hide").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 110)
                }
                HStack {
                    Text("\(hits) of \(all) match").font(.chrome(13))
                    Spacer()
                    if !controller.filterClauses.isEmpty {
                        Button("Save as “\(controller.suggestedFilterName)”") { controller.saveFilter() }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(14)
            .frame(width: 680)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
            .onAppear { focused = true }
        }
    }

    func chipColor(_ c: NodeFilter.Clause) -> Color {
        switch c.field {
        case "type", "risk": Color(nsColor: NSColor(cgColor: controller.theme.critical.cgColor) ?? .red)
        default: .primary
        }
    }
}

struct FocusBreadcrumbView: View {
    var controller: CanvasController

    var body: some View {
        let path = controller.focusPath
        if !path.isEmpty {
            HStack(spacing: 8) {
                ForEach(Array(path.enumerated()), id: \.offset) { i, id in
                    if i > 0 { Text("›").foregroundStyle(.secondary) }
                    Text(controller.canvas.nodes[id]?.text ?? "")
                        .font(.chrome(13, weight: i == path.count - 1 ? .semibold : .regular))
                        .accessibleTap {
                            if i == 0 {
                                controller.exitFocus()
                            } else {
                                controller.select(id)
                                controller.toggleFocus()
                            }
                        }
                }
                Spacer().frame(width: 24)
                Keycap(text: "esc")
                Text("climbs out").font(.chrome(12)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
        }
    }
}

// MARK: Counts and zoom (artboard 47, bottom right)

struct CountsControl: View {
    var controller: CanvasController

    var body: some View {
        if !controller.zen && controller.present == nil {
            let all = controller.canvasCounts
            HStack(spacing: 10) {
                Button("−") { _ = controller.perform(.zoomOut) }.buttonStyle(.plain).accessibilityLabel("Zoom out")
                Text("\(Int((controller.zoom * 100).rounded()))%").font(.chrome(12.5, design: .monospaced))
                Button("+") { _ = controller.perform(.zoomIn) }.buttonStyle(.plain).accessibilityLabel("Zoom in")
                Divider().frame(height: 14)
                Button("\(all.topics) \(all.topics == 1 ? "topic" : "topics")") { controller.countsVisible.toggle() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .popover(
                        isPresented: Binding(get: { controller.countsVisible }, set: { controller.countsVisible = $0 })
                    ) {
                        CountsCard(controller: controller)
                    }
            }
            .font(.chrome(13))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.separator))
        }
    }
}

struct CountsCard: View {
    var controller: CanvasController

    var body: some View {
        let c = controller.canvas
        let all = CanvasCounts(c)
        let sel = CanvasCounts(c, nodes: controller.selection.nodes.flatMap { c.subtree($0) })
        VStack(alignment: .leading, spacing: 8) {
            Text("THIS CANVAS · SELECTION").font(.chrome(11, weight: .semibold)).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 6) {
                row("Topics", "\(all.topics) · \(sel.topics)")
                row("Words", "\(all.words.formatted()) · \(sel.words.formatted())")
                row("Characters", "\(all.characters.formatted()) · \(sel.characters.formatted())")
                row("Notes", "\(all.notes)")
                row("AI-created", "\(all.aiCreated)")
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).font(.chrome(13))
            Text(v).font(.chrome(13, design: .monospaced))
        }
    }
}

struct ZenCountView: View {
    var controller: CanvasController

    var body: some View {
        let _ = controller.prefsRevision
        if controller.zen {
            let n = controller.canvasCounts
            let count = controller.prefs.bool("appearance.zenCount")
            let timer = controller.prefs.bool("appearance.zenTimer")
            if count || timer {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    let mins = Int(controller.zenToday / 60)
                    Text(
                        [
                            timer ? "Today \(mins / 60):\(String(format: "%02d", mins % 60))" : nil,
                            count
                                ? "\(n.topics) \(n.topics == 1 ? "topic" : "topics") · \(n.words) \(n.words == 1 ? "word" : "words")"
                                : nil,
                        ]
                        .compactMap { $0 }.joined(separator: " · ")
                    )
                    .font(.chrome(12, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .accessibilityLabel(
                        "\(n.topics) \(n.topics == 1 ? "topic" : "topics"), \(n.words) \(n.words == 1 ? "word" : "words")"
                    )
                }
            }
        }
    }
}

// MARK: Navigation panel (⌃⌘1–5, artboard 47)

struct NavigationPanelView: View {
    var controller: CanvasController

    static let tabs: [(Int, String, String)] = [
        (1, "magnifyingglass", "Search"), (2, "list.bullet", "Outline"), (3, "text.alignleft", "Notes"),
        (4, "diamond.fill", "Tags"), (5, "square", "To-dos"),
    ]

    var body: some View {
        if let tab = controller.navTab, !controller.zen, controller.present == nil {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(Self.tabs, id: \.0) { n, icon, title in
                        Button {
                            controller.navTab = n
                            if n == 1 { controller.openSearch() } else { controller.refreshView() }
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: icon).font(.chrome(13))
                                Text(title).font(.chrome(11.5))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundStyle(tab == n ? Color.white : .secondary)
                            .background(RoundedRectangle(cornerRadius: 8).fill(tab == n ? Color.accentColor : .clear))
                        }
                        .buttonStyle(.plain)
                        .help("⌃⌘\(n)")
                        .accessibilityLabel("\(title), Control Command \(n)")
                    }
                }
                .padding(8)
                Divider()
                switch tab {
                case 1: SearchTab(controller: controller)
                case 2: OutlineTab(controller: controller)
                case 3: NotesTab(controller: controller)
                case 4: TagsTab(controller: controller)
                default: TodosTab(controller: controller)
                }
            }
            .frame(width: 320)
            .frame(maxHeight: .infinity)
            .background(.regularMaterial)
            .overlay(alignment: .trailing) { Divider() }
        }
    }
}

struct SearchTab: View {
    var controller: CanvasController
    @FocusState private var focused: Bool

    var body: some View {
        let s = controller.search
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find", text: Binding(get: { s.query }, set: { controller.updateSearch(query: $0) }))
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { controller.stepSearch(1) }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        controller.stepSearch(-1)
                        return .handled
                    }
                    .onExitCommand {
                        controller.navTab = nil; controller.refreshView()
                    }
                if !s.query.isEmpty {
                    Text(s.matches.isEmpty ? "0 of 0" : "\(s.current + 1) of \(s.matches.count)")
                        .font(.chrome(12, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            HStack {
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                TextField(
                    "Replace with",
                    text: Binding(get: { s.replacement }, set: { controller.updateSearch(replacement: $0) })
                )
                .textFieldStyle(.plain)
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            HStack(spacing: 6) {
                toggle("Aa Match case", s.options.matchCase) { $0.matchCase.toggle() }
                toggle("Whole words", s.options.wholeWords) { $0.wholeWords.toggle() }
                toggle(".* Regex", s.options.regex) { $0.regex.toggle() }
            }
            HStack(spacing: 6) {
                toggle("This canvas", !s.options.allCanvases) { $0.allCanvases = false }
                toggle("All canvases", s.options.allCanvases) { $0.allCanvases = true }
                toggle("+ Notes", s.options.notes) { $0.notes.toggle() }
                toggle("+ Labels", s.options.labels) { $0.labels.toggle() }
            }
            HStack {
                Button("Replace ⌥↩") { controller.replaceCurrent() }
                    .keyboardShortcut(.return, modifiers: .option)
                    .frame(maxWidth: .infinity)
                Button("Replace all ⌥⌘↩") { controller.replaceAllMatches() }
                    .keyboardShortcut(.return, modifiers: [.option, .command])
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            .disabled(s.matches.isEmpty)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(s.matches.enumerated()), id: \.element.id) { i, m in
                        resultRow(m, current: i == s.current)
                            .accessibleTap { controller.stepSearch(i - s.current) }
                    }
                }
            }
            .accessibilityLabel(Loc.t("Matches"))
            Text("↩ next · ⇧↩ previous · matches glow on canvas · esc closes")
                .font(.chrome(11)).foregroundStyle(.secondary)
        }
        .padding(12)
        .onAppear { focused = true }
        .onChange(of: controller.searchFocusSerial) { _, _ in focused = true }
    }

    func toggle(_ title: String, _ on: Bool, _ change: @escaping (inout SearchOptions) -> Void) -> some View {
        Button {
            var o = controller.search.options
            change(&o)
            controller.updateSearch(options: o)
        } label: {
            Text(title).font(.chrome(11.5)).lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(on ? Color(nsColor: .textBackgroundColor) : .primary)
                .background(Capsule().fill(on ? Color.primary : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    func resultRow(_ m: SearchMatch, current: Bool) -> some View {
        let c = controller.store.canvas(m.canvas)
        let n = c?.nodes[m.node]
        let source: String =
            switch m.field {
            case .text: n?.text ?? ""
            case .note: "Note: “" + (n?.note?.text ?? "") + "”"
            case .label: n?.labels[safe: m.index] ?? ""
            }
        let offset = m.field == .note ? 7 : 0
        let start = m.range.location + offset
        let matched = Array(start..<start + m.range.length)
        let path =
            ([c?.title ?? ""]
            + (c.map { cv in cv.path(to: m.node).dropFirst().compactMap { cv.nodes[$0]?.text } } ?? []))
            .joined(separator: " › ") + (m.field == .note ? " › note" : "")
        return HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.7)).frame(width: 8, height: 8).padding(
                .top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Highlighted(text: String(source.prefix(60)), matched: matched.filter { $0 < 60 }, size: 13.5)
                Text(path).font(.chrome(11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(current ? Color.accentColor.opacity(0.1) : .clear)
        .contentShape(Rectangle())
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

struct OutlineTab: View {
    var controller: CanvasController

    var body: some View {
        let c = controller.canvas
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows(c), id: \.0) { id, depth in
                    Text(c.nodes[id]?.text ?? "")
                        .font(.chrome(depth == 0 ? 14 : 13, weight: depth <= 1 ? .semibold : .regular))
                        .padding(.leading, CGFloat(depth) * 14)
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(controller.selection.nodes.contains(id) ? Color.accentColor.opacity(0.14) : .clear)
                        .contentShape(Rectangle())
                        .accessibleTap {
                            controller.select(id)
                            controller.onReveal?(id)
                        }
                }
            }
            .padding(12)
        }
        .accessibilityLabel(Loc.t("Outline"))
    }

    func rows(_ c: NexusCore.Canvas) -> [(NodeID, Int)] {
        var out: [(NodeID, Int)] = []
        func walk(_ id: NodeID, _ d: Int) {
            out.append((id, d))
            guard let n = c.nodes[id], !n.folded else { return }
            for k in n.children { walk(k, d + 1) }
        }
        for t in c.tops { walk(t, 0) }
        return out
    }
}

struct NotesTab: View {
    var controller: CanvasController

    var body: some View {
        let c = controller.canvas
        let notes = c.tops.flatMap { c.subtree($0) }.filter { c.nodes[$0]?.note != nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if notes.isEmpty { Text("No notes yet. ⇧⌘N adds one.").foregroundStyle(.secondary).padding(12) }
                ForEach(notes, id: \.self) { id in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            ([c.path(to: id).dropFirst().last].compactMap { $0 }.compactMap { c.nodes[$0]?.text } + [
                                c.nodes[id]?.text ?? ""
                            ])
                            .joined(separator: " › ")
                        )
                        .font(.chrome(13.5, weight: .semibold))
                        Text(c.nodes[id]?.note?.text ?? "").font(.chrome(12.5)).foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .accessibleTap {
                        controller.select(id)
                        controller.onReveal?(id)
                    }
                    Divider()
                }
            }
        }
        .accessibilityLabel(Loc.t("Notes"))
    }
}

struct TagsTab: View {
    var controller: CanvasController

    var body: some View {
        let tags = controller.tagCounts
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.key) { t in
                    let on = controller.tagHighlight.contains(t.key)
                    Text("\(t.title) · \(t.count)")
                        .font(.chrome(12.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(
                            on
                                ? Color(nsColor: .textBackgroundColor)
                                : Color(nsColor: NSColor(cgColor: t.color.cgColor) ?? .labelColor)
                        )
                        .background(
                            Capsule().fill(
                                on
                                    ? Color.primary
                                    : Color(nsColor: NSColor(cgColor: t.color.alpha(0.12).cgColor) ?? .gray))
                        )
                        .accessibleTap {
                            controller.toggleTag(t.key, combine: NSEvent.modifierFlags.contains(.shift))
                        }
                }
            }
            if tags.isEmpty { Text("No markers or labels yet.").foregroundStyle(.secondary) }
            Text("Click to highlight related topics; the rest fade to 30%. ⇧-click combines.")
                .font(.chrome(11.5)).foregroundStyle(.secondary)
            if !controller.canvas.filters.isEmpty {
                Divider()
                Text("SAVED FILTERS").font(.chrome(11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(controller.canvas.filters, id: \.name) { f in
                    Button(f.name) { controller.applySavedFilter(f) }.buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(12)
    }
}

struct TodosTab: View {
    var controller: CanvasController
    @State private var which = "Open"

    var body: some View {
        let c = controller.canvas
        let all = c.tops.flatMap { c.subtree($0) }.filter { c.nodes[$0]?.todo != nil }
        let open = all.filter { c.nodes[$0]?.todo?.done == false }
        let done = all.filter { c.nodes[$0]?.todo?.done == true }
        let shown = which == "Open" ? open : which == "Done" ? done : all
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach([("Open", open.count), ("Done", done.count), ("All", all.count)], id: \.0) { k, n in
                    Text("\(k) · \(n)")
                        .font(.chrome(12.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .foregroundStyle(which == k ? Color(nsColor: .textBackgroundColor) : .primary)
                        .background(Capsule().fill(which == k ? Color.primary : Color.secondary.opacity(0.12)))
                        .accessibleTap { which = k }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(shown, id: \.self) { id in
                        HStack {
                            Button {
                                controller.toggleTodo(id)
                            } label: {
                                Image(systemName: c.nodes[id]?.todo?.done == true ? "checkmark.square.fill" : "square")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Toggle \(c.nodes[id]?.text ?? "")")
                            Text(c.nodes[id]?.text ?? "").font(.chrome(13.5))
                                .strikethrough(c.nodes[id]?.todo?.done == true)
                            Spacer()
                            Text(c.parent(of: id).flatMap { c.nodes[$0]?.text } ?? "")
                                .font(.chrome(12)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .accessibleTap {
                            controller.select(id)
                            controller.onReveal?(id)
                        }
                        Divider()
                    }
                }
            }
            .accessibilityLabel(Loc.t("To-dos"))
        }
        .padding(12)
    }
}

/// Wrapping row layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0
        var y: CGFloat = 0
        var row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += row + spacing
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var row: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
