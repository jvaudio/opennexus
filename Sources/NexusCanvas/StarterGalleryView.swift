import NexusCore
import NexusScene
import NexusTheme
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The starter picker (M40): a sidebar of sections, a search field that filters as you
/// type while the arrow keys move through the cards, and Create. A sheet on ⌘T and the tab
/// bar's +; Home's Templates section embeds it.
public struct StarterGalleryView: View {
    @Bindable var model: StarterGallery
    /// Inside Home: no title or Cancel, and a wider grid.
    var embedded: Bool
    @FocusState private var searchFocused: Bool
    // My Starters (M50): the sheets and panels its commands open.
    @State private var importing = false
    @State private var exporting: StarterExport?
    @State private var installing: StarterGallery.Install?
    @State private var editing: Starter?
    @State private var askingURL = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The iPhone's layout (M47c): chips for the sections, two columns, the search field
    /// under the title.
    var compact: Bool { sizeClass == .compact }
    #else
    let compact = false
    #endif

    public init(model: StarterGallery, embedded: Bool = false) {
        self.model = model
        self.embedded = embedded
    }

    static let accent = Color(hex: "#5850EC")
    var columns: Int { compact ? 2 : embedded ? 5 : 4 }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if !embedded && !compact {
                    sidebar
                    Divider()
                }
                VStack(spacing: 0) {
                    searchBar
                    if embedded || compact { chips }
                    mineBar
                    grid
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: embedded || compact ? nil : 900, minHeight: embedded || compact ? nil : 600)
        .chromeControls()
        .background(Color.windowBackground)
        .onAppear {
            model.columns = columns
            searchFocused = true
        }
        .onEscape { if !embedded { model.cancel() } }
        .background {
            // ⌘D: the selected card's star.
            if !embedded { Button("") { model.toggleFavourite() }.keyboardShortcut("d").hidden() }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, let data = try? Data(contentsOf: url) else { return }
                Task { @MainActor in installing = model.preview(data, name: url.lastPathComponent) }
            }
            return true
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: StarterExport.types) { result in
            guard let url = try? result.get() else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            installing = model.preview(data, name: url.lastPathComponent)
        }
        .fileExporter(
            isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }), document: exporting,
            contentType: exporting?.type ?? .json, defaultFilename: exporting?.name
        ) { _ in exporting = nil }
        .sheet(item: $installing) { i in
            StarterInstallView(install: i) { clash in
                installing = nil
                if let clash { model.install(i, clash: clash) }
            }
        }
        .sheet(item: $editing) { s in
            StarterDetailsForm(
                title: Loc.t("Edit Details"), action: Loc.t("Save"), values: .init(s)
            ) { v in
                editing = nil
                if let v { model.update(s) { v.apply(to: &$0) } }
            }
        }
        .sheet(isPresented: $askingURL) {
            StarterURLForm { url in
                askingURL = false
                guard let url, let read = model.readURL else { return }
                Task {
                    do {
                        installing = model.preview(try await read(url), name: url.lastPathComponent)
                    } catch {
                        model.notice = Loc.f("Couldn’t read %@: %@", url.absoluteString, error.localizedDescription)
                    }
                }
            }
        }
    }

    func export(_ starters: [Starter]) {
        exporting = StarterExport(starters)
    }

    // MARK: Sidebar

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(model.sections, id: \.self) { s in
                if s == .collection(StarterCollection.allCases[0]) {
                    Text("COLLECTIONS").font(.chrome(11.5, weight: .semibold)).foregroundStyle(.chromeSecondary)
                        .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
                }
                sideItem(s)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: .chromeWidth(190))
        .background(Color.underPageBackground.opacity(0.5))
    }

    func sideItem(_ s: StarterGallery.Section) -> some View {
        let on = model.section == s
        return Button {
            model.section = s
        } label: {
            HStack {
                Text(s.title).font(.chrome(13.5, weight: on ? .semibold : .regular))
                Spacer()
                Text("\(StarterGallery.search(model.query, in: model.starters(in: s)).count)").font(.chrome(12))
                    .foregroundStyle(.chromeSecondary)
            }
            .foregroundStyle(on ? Self.accent : .primary)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Self.accent.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Inside Home, whose own sidebar is beside it, the sections are a row of chips.
    var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.sections, id: \.self) { s in
                    let on = model.section == s
                    Button(s.title) { model.section = s }
                        .buttonStyle(.plain)
                        .font(.chrome(13, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.white : .primary)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(Capsule().fill(on ? Color.black : Color.secondary.opacity(0.1)))
                        .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, compact ? 16 : 20)
        }
        .padding(.bottom, 14)
    }

    // MARK: Search

    var searchBar: some View {
        let title = Text(embedded ? "Templates" : model.purpose == .canvas ? "New Canvas" : "New Document")
            .font(.chrome(embedded ? 27 : 17, weight: embedded ? .bold : .semibold))
        return Group {
            if compact {
                VStack(alignment: .leading, spacing: 10) {
                    if !embedded { title }
                    searchField.frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .padding(.top, embedded ? 4 : 14)
                .padding(.bottom, 10)
            } else {
                HStack(spacing: 12) {
                    title
                    Spacer()
                    searchField.frame(width: 300)
                }
                .padding(.horizontal, 20)
                .padding(.top, embedded ? 26 : 14)
                .padding(.bottom, 14)
            }
        }
    }

    var searchField: some View {
        TextField("Search starters", text: $model.query)
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .font(.chrome(13))
            .focused($searchFocused)
            .accessibilityLabel("Search starters")
            // Typing filters while the arrow keys move through the cards (Xcode's template chooser).
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                switch press.key {
                case .upArrow: model.move(dy: -1)
                case .downArrow: model.move(dy: 1)
                case .leftArrow: model.move(dx: -1)
                default: model.move(dx: 1)
                }
                return .handled
            }
            .onSubmit { model.choose() }
    }

    // MARK: Grid

    var grid: some View {
        let items = model.visible
        return ScrollViewReader { proxy in
            ScrollView {
                if items.isEmpty && model.section == .mine && model.query.isEmpty {
                    Text("Save a canvas as a starter (File › Save Canvas as Starter…), or install one from a file.")
                        .font(.chrome(14)).foregroundStyle(.chromeSecondary).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity).padding(.top, 60).padding(.horizontal, 40)
                } else if items.isEmpty {
                    Text(Loc.f("No starter matches “%@”", model.query)).font(.chrome(14)).foregroundStyle(
                        .chromeSecondary
                    )
                    .frame(maxWidth: .infinity).padding(.top, 60)
                }
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: columns),
                    spacing: 14
                ) {
                    ForEach(items) { s in
                        StarterCard(
                            starter: s, selected: s.id == model.selection, prefs: model.prefs,
                            favourite: model.isFavourite(s)
                        ) { model.toggleFavourite(s) }
                        .id(s.id)
                        .onTapGesture(count: 2) { model.choose(s) }
                        .simultaneousGesture(TapGesture().onEnded { model.selection = s.id })
                        .accessibilityAction { model.choose(s) }
                        .contextMenu { cardMenu(s) }
                    }
                }
                .padding(.horizontal, compact ? 16 : 20)
                .padding(.bottom, 20)
            }
            .onChange(of: model.selection) { _, id in
                guard let id else { return }
                withAnimation(UIMotion.animation(.easeOut(duration: Motion.reducedCrossFade))) { proxy.scrollTo(id) }
            }
            .onAppear { if let id = model.selection { proxy.scrollTo(id, anchor: .center) } }
        }
    }

    // MARK: My Starters (M50)

    /// Install from a file or a URL, and export them all as a pack.
    @ViewBuilder var mineBar: some View {
        if model.section == .mine {
            HStack(spacing: 10) {
                Button("Install Starter…") { importing = true }
                if model.readURL != nil { Button("Install from URL…") { askingURL = true } }
                Spacer()
                if !model.mine.all.isEmpty { Button("Export All…") { export(model.mine.all) } }
            }
            .font(.chrome(12.5))
            .padding(.horizontal, compact ? 16 : 20)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder func cardMenu(_ s: Starter) -> some View {
        Button(model.isFavourite(s) ? "Remove from Favourites" : "Add to Favourites") { model.toggleFavourite(s) }
        if s.mine {
            Divider()
            Button("Rename…") { editing = s }
            Button("Edit Details…") { editing = s }
            Menu("Move to") {
                ForEach(StarterCollection.allCases, id: \.self) { c in
                    Button(Loc.t(c.title)) { model.update(s) { $0.collection = c } }
                }
            }
            Button("Export Starter…") { export([s]) }
            #if os(macOS)
            if let url = model.mine.url(of: s.id) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            #endif
            Divider()
            Button("Delete") { model.delete(s) }
        }
    }

    // MARK: Footer

    @ViewBuilder var footer: some View {
        if compact {
            // The iPhone's: the chosen starter above the buttons.
            VStack(alignment: .leading, spacing: 8) {
                selectedName
                footerButtons
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        } else {
            HStack(spacing: 12) {
                selectedName
                footerButtons
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder var selectedName: some View {
        if let notice = model.notice {
            HStack(spacing: 8) {
                Text(notice).font(.chrome(12.5)).foregroundStyle(.chromeSecondary).lineLimit(2)
                if model.deleted != nil { Button("Undo") { model.undoDelete() }.linkButton().font(.chrome(12.5)) }
            }
        } else if let s = model.selected {
            VStack(alignment: .leading, spacing: 2) {
                Text(Loc.t(s.name)).font(.chrome(13.5, weight: .semibold))
                Text(
                    "\(s.isBlank ? Loc.t("Blank") : HomeView.typeName(s.type)) · \(s.mine ? Loc.t("My Starters") : Loc.t(s.collection?.title ?? s.category.title))"
                )
                .font(.chrome(12)).foregroundStyle(.chromeSecondary)
            }
        }
    }

    @ViewBuilder var footerButtons: some View {
        HStack(spacing: 12) {
            Spacer()
            if let s = model.selected, GuideLibrary.guide(for: s.type) != nil {
                Toggle("Start with Guide", isOn: $model.startsWithGuide)
                    .checkboxToggle()
                    .font(.chrome(13))
                    .help("Opens Guide mode (⌃⌘G) beside the new map")
            }
            if !embedded {
                Button("Cancel") { model.cancel() }.keyboardShortcut(.cancelAction).controlSize(.large)
            }
            Button("Create") { model.choose() }
                .keyboardShortcut(embedded ? nil : .defaultAction)
                .controlSize(.large)
                .disabled(model.selected == nil)
        }
    }
}

/// A starter's card: a picture, kicker, name and summary. One VoiceOver button. A template
/// shows its own map (its type's glyph until that's drawn); a Blank one, its type's glyph,
/// as Home's New cards do: one lone topic would look the same for every type.
struct StarterCard: View {
    let starter: Starter
    let selected: Bool
    let prefs: Preferences
    var favourite = false
    var toggleFavourite: () -> Void = {}
    @State private var hover = false
    @State private var image: CGImage?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    var tint: Color { Color(hex: DiagramDescriptor[starter.type].tint) }
    var guided: Bool { GuideLibrary.guide(for: starter.type) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.06))
                if let image {
                    Image(decorative: image, scale: displayScale).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.15)))
                        .padding(8)
                        .scaleEffect(hover && !UIMotion.reduce ? 1.06 : 1)
                } else {
                    TypeGlyph(type: starter.type, color: tint.opacity(starter.isBlank ? 1 : 0.7))
                        .frame(width: 96, height: 60)
                        .scaleEffect(hover && !UIMotion.reduce ? 1.08 : 1)
                }
            }
            .frame(height: StarterThumbnails.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topLeading) {
                // The star: shown when it's a favourite, or on hover to make it one.
                if favourite || hover {
                    Button(action: toggleFavourite) {
                        Image(systemName: favourite ? "star.fill" : "star").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(favourite ? Color(hex: "#E8A317") : .secondary)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.textBackground.opacity(0.9)))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help(favourite ? "Remove from Favourites (⌘D)" : "Add to Favourites (⌘D)")
                    .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .topTrailing) {
                if guided {
                    Text("GUIDED").font(.chrome(9.5, weight: .bold, design: .monospaced)).foregroundStyle(tint)
                        .padding(.horizontal, 6).frame(height: 18)
                        .background(Capsule().fill(Color.textBackground))
                        .overlay(Capsule().stroke(tint.opacity(0.4)))
                        .padding(8)
                }
            }
            .animation(
                UIMotion.animation(
                    .spring(response: Motion.snap.response, dampingFraction: Motion.snap.dampingFraction)),
                value: hover)
            Text(Loc.t(starter.kicker)).font(.chrome(10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint).padding(.top, 4)
            Text(Loc.t(starter.name)).font(.chrome(13.5, weight: .semibold)).lineLimit(1)
            Text(Loc.t(starter.summary)).font(.chrome(12)).foregroundStyle(.chromeSecondary).lineLimit(2)
                .frame(minHeight: 30, alignment: .topLeading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.textBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(
                selected ? StarterGalleryView.accent : Color.secondary.opacity(0.2), lineWidth: selected ? 2.5 : 1)
        )
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .task(id: StarterThumbnails.key(starter, dark: scheme == .dark, scale: displayScale)) {
            guard !starter.isBlank else { return }
            let dark = scheme == .dark
            if let c = StarterThumbnails.cached(starter, dark: dark, scale: displayScale) {
                image = c
                return
            }
            // One card per run-loop turn, so opening the picker never waits on drawing.
            await Task.yield()
            guard !Task.isCancelled else { return }
            image = StarterThumbnails.image(starter, prefs: prefs, dark: dark, scale: displayScale)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Loc.t(starter.name))
        .accessibilityValue(
            [
                Loc.t(starter.summary), Loc.t(starter.collection?.title ?? starter.category.title),
                guided ? Loc.t("Guided") : nil, favourite ? Loc.t("Favourite") : nil,
            ].compactMap { $0 }
                .joined(separator: ", ")
        )
        .accessibilityAction(named: favourite ? "Remove from Favourites" : "Add to Favourites") { toggleFavourite() }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
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
        #if os(macOS)
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            img = ImageExporter.image(doc, canvas: id, o)
        }
        #else
        UITraitCollection(userInterfaceStyle: dark ? .dark : .light).performAsCurrent {
            img = ImageExporter.image(doc, canvas: id, o)
        }
        #endif
        cache[k] = img
        return img
    }
}
