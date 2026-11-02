import NexusAI
import NexusCore
import NexusFormat
import NexusInterchange
import NexusScene
import Observation
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
    public var shelf: Starter.Shelf = .engineering
    public var query = ""
    public var section = "home"
    public var inboxCount = 0
    public var tourMap: URL?
    public var aiStatus: AIAvailability = .ready
    /// ⇧⌘N, File › New Document from Starter…: the Templates section's starter picker.
    public var choosingStarter = false {
        didSet { if choosingStarter { section = "templates" } }
    }

    public var onNew: (DiagramType) -> Void = { _ in }
    public var onOpen: (URL) -> Void = { _ in }
    public var onImport: () -> Void = {}
    /// Files dropped on Home: maps open or import; pictures become maps.
    public var onDropFiles: ([URL]) -> Void = { _ in }
    public var onTemplate: (Starter) -> Void = { _ in }
    public var onInbox: () -> Void = {}
    public var onFilter: (URL, String) -> Void = { _, _ in }
    /// Sync libraries and each document's sync status (M45).
    @ObservationIgnored public var syncCenter: SyncCenter?
    /// iCloud documents being downloaded to open (M45).
    public var downloading: Set<URL> = []

    /// Home's Templates section: the starter picker, making documents (M40).
    @ObservationIgnored public lazy var gallery: StarterGallery = {
        let g = StarterGallery(purpose: .document, role: role)
        g.onChoose = { [weak self] s in self?.onTemplate(s) }
        return g
    }()

    public init() {}

    /// Reads each recent package's title, type, size and text (for search and the cards).
    public func load(_ urls: [URL]) {
        recents = urls.compactMap { url in
            if CloudDownload.isPending(url) {
                return RecentItem(
                    url: url, title: url.deletingPathExtension().lastPathComponent, type: .mindmap,
                    detail: Loc.t("In iCloud Drive · opening downloads it"), date: .distantPast, text: [], filters: [])
            }
            guard let doc = try? NexusPackage.read(from: url) else { return nil }
            let c = doc.orderedCanvases.first
            let type = c?.type ?? .mindmap
            let topics = doc.topicCount
            let detail: String =
                switch type {
                case .threatModel:
                    Loc.n(
                        "Threat Model · %lld open threat", "Threat Model · %lld open threats",
                        doc.canvases.values.reduce(0) {
                            $0 + Stride.threats($1).filter { $0.status.lowercased() == "open" }.count
                        })
                case .dfd: Loc.n("Data Flow · %lld canvas", "Data Flow · %lld canvases", doc.canvases.count)
                default: "\(HomeView.typeName(type)) · \(Loc.n("%lld topic", "%lld topics", topics))"
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
            if !seen.contains(d), !Self.isPrivate(d) { seen.append(d) }
        }
        return Array(seen.prefix(4))
    }

    /// The iPad app's own Application Support (where its Inbox lives): Files can't show it,
    /// so it isn't a location. The Mac lists every folder.
    static func isPrivate(_ folder: URL) -> Bool {
        #if os(macOS)
        false
        #else
        folder.standardizedFileURL.path.hasPrefix(URL.applicationSupportDirectory.standardizedFileURL.path)
        #endif
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
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The iPhone's layout (M47c): no sidebar; its sections are chips above the column.
    var compact: Bool { sizeClass == .compact }
    #else
    let compact = false
    #endif

    public init(model: HomeModel) { self.model = model }

    static let accent = Color(hex: "#5850EC")
    public static let newTypes: [(DiagramType, String)] = [
        (.mindmap, Loc.t("Mind Map")), (.flowchart, Loc.t("Flowchart")), (.dfd, Loc.t("Data Flow")),
        (.architecture, Loc.t("Architecture")),
        (.threatModel, Loc.t("Threat Model")), (.sequence, Loc.t("Sequence")), (.whiteboard, Loc.t("Whiteboard")),
    ]

    public static func typeName(_ t: DiagramType) -> String { Loc.t(DiagramDescriptor[t].name) }

    static func tint(_ t: DiagramType) -> Color { Color(hex: DiagramDescriptor[t].tint) }

    /// A colour for small text: on the iPad, moved toward the text colour so it keeps
    /// 4.5:1 in either appearance (D402).
    static func readable(_ c: Color) -> Color {
        #if os(macOS)
        c
        #else
        c.mix(with: .primary, by: 0.4)
        #endif
    }

    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? Loc.t("Good morning") : h < 18 ? Loc.t("Good afternoon") : Loc.t("Good evening")
    }

    public var body: some View {
        HStack(spacing: 0) {
            if !compact {
                sidebar
                Divider()
            }
            VStack(spacing: 0) {
                if compact { sectionChips }
                if model.section == "templates" {
                    StarterGalleryView(model: model.gallery, embedded: true)
                } else {
                    main
                }
            }
        }
        .windowMinSize(width: 1100, height: 760)
        .chromeControls()
        .background(Color.windowBackground)
        .dropDestination(for: URL.self) { urls, _ in
            model.onDropFiles(urls)
            return !urls.isEmpty
        }
        .background {
            // ⌘N a blank mind map; ⇧⌘N the starter picker.
            Button("") { model.onNew(.mindmap) }.keyboardShortcut("n", modifiers: .command).opacity(0)
            Button("") { model.choosingStarter = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                .opacity(0)
        }
    }

    var main: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                if !model.query.isEmpty {
                    searchResults
                } else if model.section == "recents" {
                    recents(Array(model.recents))
                } else {
                    newRow
                    if !model.recents.isEmpty { recents(Array(model.recents.prefix(4))) }
                    shelf
                    if compact { places }
                }
            }
            .padding(.horizontal, compact ? 16 : 34)
            .padding(.vertical, compact ? 16 : 26)
        }
        .accessibilityLabel(model.section == "recents" ? Loc.t("Recents") : Loc.t("Home"))
        .accessibilityIdentifier("home.content")
        .overlay(alignment: .bottomTrailing) {
            if model.tourMap != nil && model.section == "home" { emptyState.padding(compact ? 16 : 24) }
        }
    }

    // MARK: Sidebar

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The Aperture lockup (brand/BRAND.md §3), at least 96 pt wide.
            BrandLockup(height: 30).padding(.bottom, 10)
            sideItem("home", Loc.t("Home"))
            sideItem("recents", Loc.t("Recents"))
            sideItem("templates", Loc.t("Templates"))
            Button {
                model.onInbox()
            } label: {
                HStack {
                    Text("Inbox map").font(.chrome(13.5))
                    Spacer()
                    if model.inboxCount > 0 {
                        Text("\(model.inboxCount)").font(.chrome(12.5, weight: .semibold)).foregroundStyle(
                            .chromeSecondary)
                    }
                }
                .padding(.horizontal, 10).frame(minHeight: 30).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !model.locations.isEmpty || model.syncCenter?.libraries.isEmpty == false {
                sideHeader("LOCATIONS")
                ForEach(model.syncCenter?.libraries ?? []) { lib in
                    let s = model.syncCenter?.status[lib.id] ?? .off
                    HStack(spacing: 6) {
                        Text(lib.name).font(.chrome(13.5)).lineLimit(1)
                        Spacer()
                        Text(verbatim: s.glyph).font(.chrome(12)).foregroundStyle(
                            Self.problem(s) ? .orange : .secondary)
                    }
                    .padding(.horizontal, 10).frame(height: 30, alignment: .leading)
                    .help(Loc.f("Sync library · %@", s.label))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Loc.f("%@, sync library, %@", lib.name, s.label))
                }
                ForEach(model.locations, id: \.self) { u in
                    Text(Self.prettyPath(u)).font(.chrome(13.5)).lineLimit(1).padding(.horizontal, 10).frame(
                        height: 30, alignment: .leading
                    )
                    .help(u.path)
                }
            }
            if !model.savedFilters.isEmpty {
                sideHeader(Loc.t("SAVED FILTERS"))
                ForEach(Array(model.savedFilters.enumerated()), id: \.offset) { _, f in
                    Button(f.1) { model.onFilter(f.0, f.1) }.buttonStyle(.plain).font(.chrome(13.5))
                        .padding(.horizontal, 10).frame(height: 30, alignment: .leading)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                Circle().fill(model.aiStatus.canRun ? Color.teal : Color.orange).frame(width: 7, height: 7)
                Text(model.aiStatus.canRun ? Loc.t("On-device AI ready") : model.aiStatus.chip).font(.chrome(13))
                    .foregroundStyle(.chromeSecondary)
            }
            .padding(10)
        }
        .padding(12)
        .frame(width: .chromeWidth(230))
        .background(Color.underPageBackground.opacity(0.5))
    }

    /// The sidebar's sections on the iPhone: chips that scroll sideways when they don't fit.
    var sectionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(Loc.t("Home"), selected: model.section == "home") { choose("home") }
                chip(Loc.t("Recents"), selected: model.section == "recents") { choose("recents") }
                chip(Loc.t("Templates"), selected: model.section == "templates") { choose("templates") }
                chip(
                    model.inboxCount > 0 ? Loc.f("Inbox map · %lld", model.inboxCount) : Loc.t("Inbox map"),
                    selected: false
                ) { model.onInbox() }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Loc.t("Sections"))
    }

    func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.chrome(13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : .primary)
                .padding(.horizontal, 12).frame(minHeight: 30)
                .background(Capsule().fill(selected ? Color.black : Color.secondary.opacity(0.1)))
                .touchTarget()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    func choose(_ section: String) {
        model.section = section
        model.query = ""
        model.choosingStarter = false
    }

    /// The sidebar's sync libraries, locations, saved filters and AI status, under Home's
    /// column on the iPhone.
    @ViewBuilder var places: some View {
        let libraries = model.syncCenter?.libraries ?? []
        if !libraries.isEmpty || !model.locations.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Locations").font(.chrome(16, weight: .semibold))
                ForEach(libraries) { lib in
                    let s = model.syncCenter?.status[lib.id] ?? .off
                    Text(verbatim: "\(lib.name) \(s.glyph)").font(.chrome(13.5))
                        .accessibilityLabel(Loc.f("%@, sync library, %@", lib.name, s.label))
                }
                ForEach(model.locations, id: \.self) { u in Text(Self.prettyPath(u)).font(.chrome(13.5)) }
            }
        }
        if !model.savedFilters.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Saved filters").font(.chrome(16, weight: .semibold))
                ForEach(Array(model.savedFilters.enumerated()), id: \.offset) { _, f in
                    Button(f.1) { model.onFilter(f.0, f.1) }.linkButton().font(.chrome(13.5))
                }
            }
        }
        HStack(spacing: 8) {
            Circle().fill(model.aiStatus.canRun ? Color.teal : Color.orange).frame(width: 7, height: 7)
            Text(model.aiStatus.canRun ? Loc.t("On-device AI ready") : model.aiStatus.chip).font(.chrome(13))
                .foregroundStyle(.chromeSecondary)
        }
    }

    static func problem(_ s: SyncStatus) -> Bool {
        switch s {
        case .offline, .conflicts: true
        default: false
        }
    }

    static func prettyPath(_ u: URL) -> String {
        let p = u.path
        if p.contains("Mobile Documents/com~apple~CloudDocs") {
            return Loc.t("iCloud Drive › ")
                + (p.components(separatedBy: "com~apple~CloudDocs/").last ?? "").replacingOccurrences(
                    of: "/", with: " › ")
        }
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
        #else
        // The app's own Documents folder is "On My iPad › OpenNexus" in Files ("On My
        // iPhone" on the iPhone).
        let docs = URL.documentsDirectory.path
        let root = onPhone ? Loc.t("On My iPhone › OpenNexus") : Loc.t("On My iPad › OpenNexus")
        return p.hasPrefix(docs) ? root + p.dropFirst(docs.count).replacingOccurrences(of: "/", with: " › ") : p
        #endif
    }

    func sideItem(_ id: String, _ title: String) -> some View {
        Button {
            model.section = id
            model.query = ""
            model.choosingStarter = false
        } label: {
            Text(title).font(.chrome(13.5, weight: model.section == id ? .semibold : .regular))
                .foregroundStyle(model.section == id ? Self.readable(Self.accent) : .primary)
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
        Text(t).font(.chrome(11.5, weight: .semibold)).foregroundStyle(.chromeSecondary).padding(.horizontal, 10)
            .padding(.top, 18).padding(.bottom, 4)
    }

    // MARK: Main column

    var header: some View {
        HStack {
            Text(model.section == "recents" ? Loc.t("Recents") : greeting)
                .font(.chrome(27, weight: .bold))
            Spacer()
            // The iPad's search field is the navigation bar's (`.searchable`, D404).
            #if os(macOS)
            TextField("Search maps and nodes", text: $model.query).textFieldStyle(.roundedBorder).controlSize(.large)
                .font(.chrome(13))
                .frame(width: 300)
                .accessibilityLabel("Search maps and nodes")
            #endif
            Button("Import…") { model.onImport() }.controlSize(.large)
        }
    }

    var newRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("New").font(.chrome(16, weight: .semibold))
                Spacer()
                if !compact {
                    keycap("⌘N")
                    Text("blank mind map ·").foregroundStyle(.chromeSecondary)
                    keycap("⇧⌘N")
                    Text("choose a starter").foregroundStyle(.chromeSecondary)
                }
            }
            .font(.chrome(12.5))
            #if os(macOS)
            HStack(spacing: 14) { newCards }
            #else
            // The iPad's column is narrower: the cards wrap rather than shrink their names. On
            // the iPhone that makes two columns (M47c).
            ColumnsLayout(minimum: 160, spacing: 14) { newCards }
            #endif
        }
    }

    @ViewBuilder var newCards: some View {
        ForEach(Array(Self.newTypes.enumerated()), id: \.offset) { i, item in
            newCard(item.0, item.1, highlighted: i == 0)
        }
        // The eighth card opens the starter picker: every type and template (M40).
        Button {
            model.choosingStarter = true
        } label: {
            cardBody(.treeTable, "More…", highlighted: false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More diagram types and templates")
    }

    func newCard(_ t: DiagramType, _ title: String, highlighted: Bool) -> some View {
        Button {
            model.onNew(t)
        } label: {
            cardBody(t, title, highlighted: highlighted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Loc.f("New %@", title))
    }

    func cardBody(_ t: DiagramType, _ title: String, highlighted: Bool) -> some View {
        VStack(spacing: 10) {
            TypeGlyph(type: t, color: highlighted ? Self.accent : .primary).frame(width: 64, height: 44)
            Text(title).font(.chrome(13.5, weight: .medium))
                #if os(macOS)
            .lineLimit(1).minimumScaleFactor(0.75)
                #else
            .lineLimit(2).multilineTextAlignment(.center)
                #endif
                .padding(.horizontal, 6)
                // The button's label reads the card ("New Whiteboard"); as an element of its own
                // the name took the card's frame, and the audit measured it across the picture.
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 108)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.textBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(
                highlighted ? Self.accent : Color.secondary.opacity(0.2), lineWidth: highlighted ? 2.5 : 1)
        )
        .contentShape(Rectangle())
    }

    func recents(_ items: [RecentItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.section == "home" { Text("Recents").font(.chrome(16, weight: .semibold)) }
            if items.isEmpty { Text("Documents you open appear here.").foregroundStyle(.chromeSecondary) }
            if compact {
                recentList(items)
            } else {
                recentGrid(items)
            }
        }
    }

    /// The iPhone's recents: a row each, the type's glyph beside the name and details.
    func recentList(_ items: [RecentItem]) -> some View {
        VStack(spacing: 8) {
            ForEach(items) { r in
                Button {
                    model.onOpen(r.url)
                } label: {
                    HStack(spacing: 12) {
                        TypeGlyph(type: r.type, color: Self.tint(r.type)).frame(width: 44, height: 30)
                            .frame(width: 64, height: 52)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Self.tint(r.type).opacity(0.06)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).font(.chrome(15, weight: .semibold))
                            Text(verbatim: recentDetail(r)).font(.chrome(12.5)).foregroundStyle(.chromeSecondary)
                        }
                        Spacer(minLength: 0)
                        if model.downloading.contains(r.url) { ProgressView() }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.textBackground))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recents")
    }

    func recentDetail(_ r: RecentItem) -> String {
        var parts = [r.detail, Self.relative(r.date)]
        if model.downloading.contains(r.url) { parts = [Loc.t("Downloading from iCloud Drive…")] }
        if let s = model.syncCenter?.status(of: r.url) { parts.append("\(s.glyph) \(s.label)") }
        return parts.joined(separator: " · ")
    }

    func recentGrid(_ items: [RecentItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
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
                                Text(Self.relative(r.date)).font(.chrome(12)).foregroundStyle(.chromeSecondary)
                            }
                            HStack(spacing: 6) {
                                if model.downloading.contains(r.url) {
                                    ProgressView().controlSize(.mini)
                                    Text("Downloading from iCloud Drive…").font(.chrome(12.5)).foregroundStyle(
                                        .secondary)
                                } else {
                                    Text(r.detail).font(.chrome(12.5)).foregroundStyle(.chromeSecondary)
                                }
                                if let s = model.syncCenter?.status(of: r.url) {
                                    Text(verbatim: "\(s.glyph) \(s.label)").font(.chrome(12))
                                        .foregroundStyle(Self.problem(s) ? .orange : .secondary).lineLimit(1)
                                }
                            }
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
        if s < 3600 { return Loc.f("%lld min ago", max(1, Int(s / 60))) }
        if Calendar.current.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if Calendar.current.isDateInYesterday(d) { return Loc.t("Yesterday") }
        if s < 6 * 86_400 { return d.formatted(.dateTime.weekday(.abbreviated)) }
        return d.formatted(.dateTime.month(.abbreviated).day())
    }

    var shelf: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(macOS)
            HStack(spacing: 8) {
                Text(model.role.shelfTitle).font(.chrome(16, weight: .semibold)).padding(.trailing, 8)
                shelfChips
            }
            #else
            // The chips scroll sideways when they don't fit beside the title (D404).
            HStack(spacing: 8) {
                Text(model.role.shelfTitle).font(.chrome(16, weight: .semibold)).padding(.trailing, 8)
                    .fixedSize()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { shelfChips }
                }
            }
            #endif
            templateRow(StarterLibrary.shelf(model.shelf))
            Button("All templates and blank diagrams…") { model.choosingStarter = true }
                .linkButton().font(.chrome(13))
        }
    }

    @ViewBuilder var shelfChips: some View {
        ForEach(Starter.Shelf.allCases, id: \.self) { cat in
            Button {
                model.shelf = cat
            } label: {
                Text(cat.title)
                    .font(.chrome(13, weight: model.shelf == cat ? .semibold : .regular))
                    .foregroundStyle(model.shelf == cat ? Color.white : .primary)
                    .padding(.horizontal, 12).frame(height: 30)
                    .background(Capsule().fill(model.shelf == cat ? Color.black : Color.secondary.opacity(0.1)))
                    .touchTarget()
            }
            .buttonStyle(.plain)
        }
    }

    func templateRow(_ ts: [Starter]) -> some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 16) { templateCards(ts) }
            .fixedSize(horizontal: false, vertical: true)
        #else
        // As many as fit across, so each summary has room (D404).
        ColumnsLayout(minimum: 200, spacing: 16) { templateCards(ts) }
        #endif
    }

    func templateCards(_ ts: [Starter]) -> some View {
        ForEach(ts) { t in
            Button {
                model.onTemplate(t)
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Loc.t(t.kicker)).font(.chrome(10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Self.readable(Self.tint(t.type)))
                    Text(Loc.t(t.name)).font(.chrome(14, weight: .semibold))
                    Text(Loc.t(t.summary)).font(.chrome(12.5)).foregroundStyle(.chromeSecondary)
                        #if os(macOS)
                    .lineLimit(2)
                        #else
                    .fixedSize(horizontal: false, vertical: true)
                        #endif
                }
                .frame(maxWidth: .infinity, minHeight: 90, maxHeight: .infinity, alignment: .topLeading)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.textBackground))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    var searchResults: some View {
        let hits = model.results
        return VStack(alignment: .leading, spacing: 10) {
            Text(
                hits.isEmpty
                    ? Loc.f("Nothing matches “%@” in recent maps", model.query)
                    : Loc.n("%lld map", "%lld maps", hits.count)
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
                                .foregroundStyle(.chromeSecondary).lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.textBackground))
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
            ).foregroundStyle(.chromeSecondary)
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
                    + Text(" to start fresh, or drop an .xmind file or a picture anywhere."))
                    .multilineTextAlignment(.center).font(.chrome(13.5)).foregroundStyle(.chromeSecondary)
            }
            .padding(20)
        }
        .sheetWidth(420)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(Color.textBackground).shadow(
                color: .black.opacity(0.12), radius: 18, y: 6))
    }

    func keycap(_ s: String) -> some View {
        // Explicit colours: the audit measured the inherited ones at 2.2:1 in dark mode.
        Text(s).font(.chrome(11, weight: .medium, design: .monospaced)).foregroundStyle(Color.primary)
            .padding(.horizontal, 5).frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.controlBackground))
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
            case .logic:
                box(0.0, 0.4, 0.22, 0.2)
                for y in [0.08, 0.4, 0.72] {
                    line((0.22, 0.5), (0.36, 0.5)); line((0.36, 0.5), (0.36, y + 0.1));
                    line((0.36, y + 0.1), (0.5, y + 0.1))
                    box(0.5, y, 0.24, 0.2)
                }
            case .brace:
                box(0.0, 0.4, 0.22, 0.2)
                p.move(to: CGPoint(x: w * 0.42, y: h * 0.06))
                p.addQuadCurve(to: CGPoint(x: w * 0.34, y: h * 0.5), control: CGPoint(x: w * 0.32, y: h * 0.1))
                p.addQuadCurve(to: CGPoint(x: w * 0.42, y: h * 0.94), control: CGPoint(x: w * 0.32, y: h * 0.9))
                for y in [0.04, 0.4, 0.76] { box(0.5, y, 0.3, 0.2) }
            case .org:
                box(0.36, 0.0, 0.28, 0.24)
                line((0.5, 0.24), (0.5, 0.42)); line((0.14, 0.42), (0.86, 0.42))
                for x in [0.02, 0.38, 0.74] { line((x + 0.12, 0.42), (x + 0.12, 0.6)); box(x, 0.6, 0.24, 0.24) }
            case .tree:
                box(0.0, 0.0, 0.3, 0.2)
                line((0.1, 0.2), (0.1, 0.9))
                for y in [0.26, 0.52, 0.78] { line((0.1, y + 0.1), (0.24, y + 0.1)); box(0.24, y, 0.36, 0.2) }
            case .fishbone:
                line((0.0, 0.5), (0.78, 0.5)); box(0.78, 0.38, 0.22, 0.24)
                for x in [0.12, 0.42] {
                    line((x, 0.08), (x + 0.16, 0.5)); line((x, 0.92), (x + 0.16, 0.5))
                }
            case .matrix:
                box(0.06, 0.04, 0.88, 0.92)
                line((0.5, 0.04), (0.5, 0.96)); line((0.06, 0.5), (0.94, 0.5))
            case .swimlane:
                for y in [0.0, 0.5] { box(0.0, y, 1.0, 0.48) }
                box(0.14, 0.12, 0.22, 0.24); line((0.36, 0.24), (0.5, 0.24)); line((0.5, 0.24), (0.5, 0.62))
                box(0.5, 0.62, 0.22, 0.24)
            case .flowchart:
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
            case .treeTable:
                box(0.0, 0.0, 1.0, 0.96)
                line((0.0, 0.24), (1.0, 0.24)); line((0.0, 0.48), (1.0, 0.48)); line((0.0, 0.72), (1.0, 0.72))
                line((0.34, 0.0), (0.34, 0.96))
                line((0.08, 0.36), (0.2, 0.36)); line((0.14, 0.6), (0.26, 0.6)); line((0.14, 0.84), (0.26, 0.84))
            case .timeline:
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
