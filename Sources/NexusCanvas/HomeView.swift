import AppKit
import NexusAI
import NexusCore
import NexusFormat
import NexusInterchange
import Observation
import SwiftUI

/// A recent document as Home shows it.
public struct RecentItem: Identifiable, Sendable, Equatable {
    public var url: URL
    public var title: String
    public var type: DiagramType
    public var detail: String
    public var date: Date
    /// Lower-cased text of every topic, for search.
    public var text: [String]
    public var filters: [String]
    public var id: URL { url }
}

/// Home's data (artboard 16). The app fills it from the recent documents.
@MainActor
@Observable
public final class HomeModel {
    public var recents: [RecentItem] = []
    public var role: Role = .engineer
    public var shelf: MapTemplate.Category = .engineering
    public var query = ""
    public var section = "home"
    public var inboxCount = 0
    public var tourMap: URL?
    public var aiStatus: AIAvailability = .ready
    /// Focus the type picker (⇧⌘N).
    public var choosingType = false

    public var onNew: (DiagramType) -> Void = { _ in }
    public var onOpen: (URL) -> Void = { _ in }
    public var onImport: () -> Void = {}
    public var onTemplate: (MapTemplate) -> Void = { _ in }
    public var onInbox: () -> Void = {}
    public var onFilter: (URL, String) -> Void = { _, _ in }

    public init() {}

    /// Reads each recent package's title, type, size and text (for search and the cards).
    public func load(_ urls: [URL]) {
        recents = urls.compactMap { url in
            guard let doc = try? NexusPackage.read(from: url) else { return nil }
            let c = doc.orderedCanvases.first
            let type = c?.type ?? .mindmap
            let topics = doc.topicCount
            let detail: String =
                switch type {
                case .threatModel:
                    "Threat Model · \(doc.canvases.values.reduce(0) { $0 + Stride.threats($1).filter { $0.status.lowercased() == "open" }.count }) open threats"
                case .dfd: "Data Flow · \(doc.canvases.count) canvas\(doc.canvases.count == 1 ? "" : "es")"
                default: "\(HomeView.typeName(type)) · \(topics) \(topics == 1 ? "topic" : "topics")"
                }
            let date =
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            return RecentItem(
                url: url, title: url.deletingPathExtension().lastPathComponent, type: type, detail: detail, date: date,
                text: doc.canvases.values.flatMap { $0.nodes.values.map { $0.text.lowercased() } },
                filters: doc.canvases.values.flatMap { $0.filters.map(\.name) })
        }
    }

    public var locations: [URL] {
        var seen: [URL] = []
        for r in recents {
            let d = r.url.deletingLastPathComponent()
            if !seen.contains(d) { seen.append(d) }
        }
        return Array(seen.prefix(4))
    }

    public var savedFilters: [(URL, String)] {
        recents.flatMap { r in r.filters.map { (r.url, $0) } }.prefix(6).map { $0 }
    }

    /// Maps and topics matching the search field.
    public var results: [(RecentItem, [String])] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return recents.compactMap { r in
            let hits = r.text.filter { $0.contains(q) }
            return r.title.lowercased().contains(q) || !hits.isEmpty ? (r, Array(hits.prefix(3))) : nil
        }
    }
}

public struct HomeView: View {
    @Bindable var model: HomeModel
    @State private var showMore = false

    public init(model: HomeModel) { self.model = model }

    static let accent = Color(hex: "#5850EC")
    public static let newTypes: [(DiagramType, String)] = [
        (.mindmap, "Mind Map"), (.flowchart, "Flowchart"), (.dfd, "Data Flow"), (.architecture, "Architecture"),
        (.threatModel, "Threat Model"), (.sequence, "Sequence"), (.whiteboard, "Whiteboard"),
    ]

    public static func typeName(_ t: DiagramType) -> String {
        switch t {
        case .mindmap: "Mind Map"
        case .flowchart: "Flowchart"
        case .dfd: "Data Flow"
        case .architecture: "Architecture"
        case .threatModel: "Threat Model"
        case .sequence: "Sequence"
        case .whiteboard: "Whiteboard"
        case .timeline: "Timeline"
        case .org: "Org Chart"
        case .logic: "Logic Chart"
        case .fishbone: "Fishbone"
        case .matrix: "Matrix"
        case .treeTable: "Tree Table"
        case .tree: "Tree"
        case .brace: "Brace"
        case .swimlane: "Swimlane"
        default: t.rawValue.capitalized
        }
    }

    static func tint(_ t: DiagramType) -> Color {
        switch t {
        case .dfd, .flowchart, .swimlane: Color(hex: "#9B51E0")
        case .timeline, .treeTable: Color(hex: "#E0A300")
        case .threatModel: Color(hex: "#D93A3F")
        case .architecture: Color(hex: "#1E8BE0")
        default: Color(hex: "#0F9F9A")
        }
    }

    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    if !model.query.isEmpty {
                        searchResults
                    } else if model.section == "recents" {
                        recents(Array(model.recents))
                    } else if model.section == "templates" {
                        ForEach(MapTemplate.Category.allCases, id: \.self) { cat in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(cat.rawValue).font(.chrome(16, weight: .semibold))
                                templateRow(TemplateLibrary.shelf(cat))
                            }
                        }
                    } else {
                        newRow
                        if !model.recents.isEmpty { recents(Array(model.recents.prefix(4))) }
                        shelf
                    }
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 26)
            }
            .accessibilityLabel(
                Loc.t(model.section == "recents" ? "Recents" : model.section == "templates" ? "Templates" : "Home")
            )
            .overlay(alignment: .bottomTrailing) {
                if model.tourMap != nil && model.section == "home" { emptyState.padding(24) }
            }
        }
        .frame(minWidth: 1100, minHeight: 760)
        .chromeControls()
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            // ⌘N a blank mind map; ⇧⌘N jumps to the type cards; 1–7 pick a type there.
            Button("") { model.onNew(.mindmap) }.keyboardShortcut("n", modifiers: .command).opacity(0)
            Button("") {
                model.section = "home"; model.choosingType = true
            }.keyboardShortcut("n", modifiers: [.command, .shift]).opacity(0)
            ForEach(Array(Self.newTypes.enumerated()), id: \.offset) { i, t in
                Button("") { model.onNew(t.0) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [])
                    .opacity(0)
                    .disabled(!model.choosingType)
            }
        }
    }

    // MARK: Sidebar

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            sideItem("home", "Home")
            sideItem("recents", "Recents")
            sideItem("templates", "Templates")
            Button {
                model.onInbox()
            } label: {
                HStack {
                    Text("Inbox map").font(.chrome(13.5))
                    Spacer()
                    if model.inboxCount > 0 {
                        Text("\(model.inboxCount)").font(.chrome(12.5)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10).frame(height: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !model.locations.isEmpty {
                sideHeader("LOCATIONS")
                ForEach(model.locations, id: \.self) { u in
                    Text(Self.prettyPath(u)).font(.chrome(13.5)).lineLimit(1).padding(.horizontal, 10).frame(
                        height: 30, alignment: .leading
                    )
                    .help(u.path)
                }
            }
            if !model.savedFilters.isEmpty {
                sideHeader("SAVED FILTERS")
                ForEach(Array(model.savedFilters.enumerated()), id: \.offset) { _, f in
                    Button(f.1) { model.onFilter(f.0, f.1) }.buttonStyle(.plain).font(.chrome(13.5))
                        .padding(.horizontal, 10).frame(height: 30, alignment: .leading)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(model.aiStatus.canRun ? Color.teal : Color.orange).frame(width: 7, height: 7)
                Text(model.aiStatus.canRun ? "On-device AI ready" : model.aiStatus.chip).font(.chrome(13))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .padding(12)
        .frame(width: .chromeWidth(230))
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }

    static func prettyPath(_ u: URL) -> String {
        let p = u.path
        if p.contains("Mobile Documents/com~apple~CloudDocs") {
            return "iCloud Drive › "
                + (p.components(separatedBy: "com~apple~CloudDocs/").last ?? "").replacingOccurrences(
                    of: "/", with: " › ")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    func sideItem(_ id: String, _ title: String) -> some View {
        Button {
            model.section = id
            model.query = ""
        } label: {
            Text(title).font(.chrome(13.5, weight: model.section == id ? .semibold : .regular))
                .foregroundStyle(model.section == id ? Self.accent : .primary)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(model.section == id ? Self.accent.opacity(0.12) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func sideHeader(_ t: String) -> some View {
        Text(t).font(.chrome(11.5, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 10)
            .padding(.top, 18).padding(.bottom, 4)
    }

    // MARK: Main column

    var header: some View {
        HStack {
            Text(model.section == "recents" ? "Recents" : model.section == "templates" ? "Templates" : greeting)
                .font(.chrome(27, weight: .bold))
            Spacer()
            TextField("Search maps and nodes", text: $model.query).textFieldStyle(.roundedBorder).controlSize(.large)
                .font(.chrome(13))
                .frame(width: 300)
                .accessibilityLabel("Search maps and nodes")
            Button("Import…") { model.onImport() }.controlSize(.large)
        }
    }

    var newRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("New").font(.chrome(16, weight: .semibold))
                Spacer()
                keycap("⌘N")
                Text("blank mind map ·").foregroundStyle(.secondary)
                keycap("⇧⌘N")
                Text("choose type").foregroundStyle(.secondary)
            }
            .font(.chrome(12.5))
            if model.choosingType {
                Text("Press 1–7 to choose a type, or click one.").font(.chrome(13.5)).foregroundStyle(Self.accent)
            }
            HStack(spacing: 14) {
                ForEach(Array(Self.newTypes.enumerated()), id: \.offset) { i, item in
                    newCard(item.0, item.1, highlighted: i == 0)
                        .overlay(alignment: .topTrailing) {
                            if model.choosingType {
                                Text("\(i + 1)").font(.chrome(11, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 6).frame(height: 20)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator)).padding(8)
                            }
                        }
                }
                // The eighth card lists the other types (a borderless Menu would drop the card label).
                Button {
                    showMore = true
                } label: {
                    cardBody(.treeTable, "More…", highlighted: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More diagram types")
                .popover(isPresented: $showMore, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(
                            [
                                DiagramType.timeline, .org, .logic, .fishbone, .matrix, .treeTable, .tree, .brace,
                                .swimlane,
                            ],
                            id: \.self
                        ) { t in
                            Button {
                                showMore = false
                                model.onNew(t)
                            } label: {
                                HStack(spacing: 10) {
                                    TypeGlyph(type: t, color: .primary).frame(width: 28, height: 18)
                                    Text(Self.typeName(t)).font(.chrome(13))
                                    Spacer()
                                }
                                .padding(.horizontal, 10).frame(height: 28).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(6).frame(width: 220)
                }
            }
        }
    }

    func newCard(_ t: DiagramType, _ title: String, highlighted: Bool) -> some View {
        Button {
            model.onNew(t)
        } label: {
            cardBody(t, title, highlighted: highlighted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New \(title)")
    }

    func cardBody(_ t: DiagramType, _ title: String, highlighted: Bool) -> some View {
        VStack(spacing: 10) {
            TypeGlyph(type: t, color: highlighted ? Self.accent : .primary).frame(width: 64, height: 44)
            Text(title).font(.chrome(13.5, weight: .medium)).lineLimit(1).minimumScaleFactor(0.75)
                .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity, minHeight: 108)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(
                highlighted ? Self.accent : Color.secondary.opacity(0.2), lineWidth: highlighted ? 2.5 : 1)
        )
        .contentShape(Rectangle())
    }

    func recents(_ items: [RecentItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.section == "home" { Text("Recents").font(.chrome(16, weight: .semibold)) }
            if items.isEmpty { Text("Documents you open appear here.").foregroundStyle(.secondary) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: 4), spacing: 20) {
                ForEach(items) { r in
                    Button {
                        model.onOpen(r.url)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14).fill(Self.tint(r.type).opacity(0.06))
                                TypeGlyph(type: r.type, color: Self.tint(r.type)).frame(width: 140, height: 84)
                            }
                            .frame(height: 150)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.18)))
                            HStack {
                                Text(r.title).font(.chrome(13.5, weight: .semibold)).lineLimit(1)
                                Spacer()
                                Text(Self.relative(r.date)).font(.chrome(12)).foregroundStyle(.secondary)
                            }
                            Text(r.detail).font(.chrome(12.5)).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Recents")
        }
    }

    static func relative(_ d: Date) -> String {
        let s = Date().timeIntervalSince(d)
        if s < 3600 { return "\(max(1, Int(s / 60))) min ago" }
        if Calendar.current.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        if s < 6 * 86_400 { return d.formatted(.dateTime.weekday(.abbreviated)) }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    var shelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(model.role.shelfTitle).font(.chrome(16, weight: .semibold)).padding(.trailing, 8)
                ForEach(MapTemplate.Category.allCases, id: \.self) { cat in
                    Button(cat.rawValue) { model.shelf = cat }
                        .buttonStyle(.plain)
                        .font(.chrome(13, weight: model.shelf == cat ? .semibold : .regular))
                        .foregroundStyle(model.shelf == cat ? Color.white : .primary)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Capsule().fill(model.shelf == cat ? Color.black : Color.secondary.opacity(0.1)))
                }
            }
            templateRow(TemplateLibrary.shelf(model.shelf))
        }
    }

    func templateRow(_ ts: [MapTemplate]) -> some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(ts) { t in
                Button {
                    model.onTemplate(t)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(t.kicker).font(.chrome(10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(
                                Self.tint(t.type))
                        Text(t.title).font(.chrome(14, weight: .semibold))
                        Text(t.detail).font(.chrome(12.5)).foregroundStyle(.secondary).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, minHeight: 90, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    var searchResults: some View {
        let hits = model.results
        return VStack(alignment: .leading, spacing: 10) {
            Text(
                hits.isEmpty
                    ? "Nothing matches “\(model.query)” in recent maps"
                    : "\(hits.count) map\(hits.count == 1 ? "" : "s")"
            )
            .font(.chrome(16, weight: .semibold))
            ForEach(hits, id: \.0.url) { r, nodes in
                Button {
                    model.onOpen(r.url)
                } label: {
                    HStack(spacing: 14) {
                        TypeGlyph(type: r.type, color: Self.tint(r.type)).frame(width: 44, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).font(.chrome(15, weight: .semibold))
                            Text(nodes.isEmpty ? r.detail : nodes.joined(separator: " · ")).font(.chrome(13))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("EMPTY STATE · FIRST LAUNCH AFTER TOUR").font(
                .chrome(12, weight: .semibold, design: .monospaced)
            ).foregroundStyle(.secondary)
                .padding(14)
            Divider()
            VStack(spacing: 14) {
                Button {
                    if let u = model.tourMap { model.onOpen(u) }
                } label: {
                    Text("My first map").font(.chrome(15, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
                        .padding(22)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                (Text("Your tutorial map is here. Press ") + Text("⌘N").font(.chrome(12, design: .monospaced))
                    + Text(" to start fresh or drop an .xmind file anywhere."))
                    .multilineTextAlignment(.center).font(.chrome(13.5)).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .textBackgroundColor)).shadow(
                color: .black.opacity(0.12), radius: 18, y: 6))
    }

    func keycap(_ s: String) -> some View {
        // Explicit colours: the audit measured the inherited ones at 2.2:1 in dark mode.
        Text(s).font(.chrome(11, weight: .medium, design: .monospaced)).foregroundStyle(Color.primary)
            .padding(.horizontal, 5).frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
    }
}

/// Line-art glyphs for each diagram type (Home's New cards and recents).
struct TypeGlyph: View {
    let type: DiagramType
    var color: Color

    var body: some View {
        Canvas { ctx, s in
            let w = s.width
            let h = s.height
            var p = Path()
            func box(_ x: CGFloat, _ y: CGFloat, _ bw: CGFloat, _ bh: CGFloat) {
                p.addRect(CGRect(x: x * w, y: y * h, width: bw * w, height: bh * h))
            }
            func line(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) {
                p.move(to: CGPoint(x: a.0 * w, y: a.1 * h))
                p.addLine(to: CGPoint(x: b.0 * w, y: b.1 * h))
            }
            switch type {
            case .flowchart, .swimlane:
                p.addRoundedRect(
                    in: CGRect(x: w * 0.36, y: 0, width: w * 0.28, height: h * 0.2),
                    cornerSize: CGSize(width: h * 0.1, height: h * 0.1))
                line((0.5, 0.2), (0.5, 0.32))
                p.move(to: CGPoint(x: w * 0.5, y: h * 0.32))
                p.addLine(to: CGPoint(x: w * 0.62, y: h * 0.48))
                p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.64))
                p.addLine(to: CGPoint(x: w * 0.38, y: h * 0.48))
                p.closeSubpath()
                line((0.38, 0.48), (0.12, 0.48)); line((0.12, 0.48), (0.12, 0.72)); box(0.02, 0.72, 0.2, 0.26)
                line((0.62, 0.48), (0.88, 0.48)); line((0.88, 0.48), (0.88, 0.72)); box(0.78, 0.72, 0.2, 0.26)
            case .dfd:
                box(0.02, 0.32, 0.2, 0.36)
                line((0.22, 0.5), (0.36, 0.5))
                p.addEllipse(in: CGRect(x: w * 0.36, y: h * 0.18, width: w * 0.28, height: h * 0.64))
                line((0.64, 0.5), (0.78, 0.5))
                line((0.78, 0.32), (0.98, 0.32)); line((0.78, 0.32), (0.78, 0.68)); line((0.78, 0.68), (0.98, 0.68))
            case .architecture:
                box(0.0, 0.18, 0.16, 0.2); line((0.16, 0.28), (0.3, 0.28))
                box(0.3, 0.0, 0.38, 0.96)
                for y in [0.1, 0.38, 0.66] { box(0.38, y, 0.22, 0.2) }
                line((0.68, 0.48), (0.82, 0.48)); box(0.82, 0.38, 0.16, 0.2)
            case .threatModel:
                p.move(to: CGPoint(x: w * 0.5, y: 0))
                p.addLine(to: CGPoint(x: w * 0.68, y: h * 0.48))
                p.addLine(to: CGPoint(x: w * 0.32, y: h * 0.48))
                p.closeSubpath()
                line((0.5, 0.16), (0.5, 0.32))
                box(0.04, 0.68, 0.26, 0.22); line((0.3, 0.79), (0.7, 0.79)); box(0.7, 0.68, 0.26, 0.22)
            case .sequence:
                for x in [0.05, 0.38, 0.71] { box(x, 0.0, 0.24, 0.18); line((x + 0.12, 0.18), (x + 0.12, 0.98)) }
                line((0.17, 0.45), (0.83, 0.45)); line((0.17, 0.28), (0.5, 0.28))
            case .whiteboard:
                box(0.04, 0.04, 0.32, 0.36); box(0.36, 0.2, 0.28, 0.34); box(0.12, 0.6, 0.3, 0.36)
                p.move(to: CGPoint(x: w * 0.7, y: h * 0.7))
                p.addCurve(
                    to: CGPoint(x: w * 0.96, y: h * 0.7), control1: CGPoint(x: w * 0.78, y: h * 0.5),
                    control2: CGPoint(x: w * 0.88, y: h * 0.9))
            case .timeline, .treeTable:
                line((0.0, 0.25), (1.0, 0.25))
                for x in [0.12, 0.42, 0.72] { box(x, 0.12, 0.18, 0.26) }
                line((0.21, 0.38), (0.21, 0.92)); line((0.21, 0.92), (0.32, 0.92))
                line((0.51, 0.38), (0.51, 0.92)); line((0.51, 0.65), (0.62, 0.65)); line((0.51, 0.92), (0.62, 0.92))
            default:
                // Mind map: a hub with spokes.
                p.addEllipse(in: CGRect(x: w * 0.42, y: h * 0.38, width: w * 0.16, height: h * 0.24))
                let spokes: [((CGFloat, CGFloat), (CGFloat, CGFloat))] = [
                    ((0.0, 0.1), (0.42, 0.45)), ((0.0, 0.9), (0.42, 0.55)), ((1.0, 0.1), (0.58, 0.45)),
                    ((1.0, 0.9), (0.58, 0.55)),
                    ((0.58, 0.5), (1.0, 0.5)),
                ]
                for (a, b) in spokes { line(a, b) }
            }
            ctx.stroke(p, with: .color(color), lineWidth: max(1.6, w / 40))
        }
        .accessibilityHidden(true)
    }
}
