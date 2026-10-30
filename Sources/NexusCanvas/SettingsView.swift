import NexusAI
import NexusCore
import NexusFormat
import NexusKeys
import NexusScene
import NexusTheme
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Settings (⌘,; artboards 08, 29 and 35–42), generated from `SettingsSchema`. Search
/// (⌘F or the sidebar field) finds every row and jumps to it.
public struct SettingsView: View {
    var prefs: Preferences
    var availability: AIAvailability
    var onAction: (String) -> Void
    /// A command to start recording a key for when Settings opens on Shortcuts.
    var record: CommandID?
    @State private var pane: String
    @State private var query = ""
    @State private var highlight: String?
    @FocusState private var searchFocused: Bool
    #if os(iOS)
    @State private var position = ScrollPosition(edge: .top)
    /// The sidebar grows with the text, up to 380 points, so a pane's name fits (D408).
    @ScaledMetric(relativeTo: .body) private var sidebarWidth: CGFloat = 250
    #endif

    public init(
        prefs: Preferences = .shared, availability: AIAvailability, pane: String = "general",
        record: CommandID? = nil, onAction: @escaping (String) -> Void = { _ in }
    ) {
        self.prefs = prefs
        self.availability = availability
        self.record = record
        self.onAction = onAction
        _pane = State(initialValue: pane)
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    if !query.isEmpty {
                        results
                    } else if pane == "shortcuts" {
                        ShortcutsPane(prefs: prefs, record: record).padding(.horizontal, 36).padding(.vertical, 30)
                    } else if let p = SettingsSchema.pane(pane) {
                        PaneView(
                            pane: p, prefs: prefs, availability: availability, highlight: highlight, onAction: onAction
                        )
                        .padding(.horizontal, 30).padding(.vertical, 28)
                    }
                }
                .onChange(of: highlight) { _, h in
                    if let h { withAnimation(UIMotion.animation(.default)) { proxy.scrollTo(h, anchor: .center) } }
                }
                .accessibilityLabel(
                    query.isEmpty
                        ? Loc.t(SettingsSchema.pane(pane)?.title ?? Loc.t("Shortcuts")) : Loc.t("Search results")
                )
                .accessibilityIdentifier("settings.content")
                #if os(iOS)
                // Each pane opens at its top, not at the last pane's scroll position; a
                // search result's pane scrolls to its row instead (`highlight`).
                .scrollPosition($position)
                .onChange(of: pane) { _, _ in if highlight == nil { position.scrollTo(edge: .top) } }
                #endif
            }
            .background(Color.windowBackground)
        }
        .windowMinSize(width: 1100, height: 760)
        .chromeControls()
        .background {
            Button("") { searchFocused = true }.keyboardShortcut("f", modifiers: .command).opacity(0)
        }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($searchFocused)
                .padding(.bottom, 10)
                .accessibilityLabel("Search settings")
            #if os(macOS)
            paneList
            Spacer()
            Text("⌘, opens Settings · ⌘F searches every pane").font(.chrome(12)).foregroundStyle(.chromeSecondary)
            #else
            // The panes scroll, so large text grows the rows instead of squeezing them (D408).
            ScrollView { paneList }
            Text("⌘F searches every pane").font(.chrome(12)).foregroundStyle(.chromeSecondary)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        }
        .padding(16)
        #if os(macOS)
        .frame(width: .chromeWidth(250))
        #else
        .frame(width: min(sidebarWidth, 380))
        #endif
        .background(Color.underPageBackground.opacity(0.5))
    }

    var paneList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(SettingsSchema.shown) { p in
                Button {
                    query = ""
                    highlight = nil
                    pane = p.id
                } label: {
                    let selected = pane == p.id && query.isEmpty
                    HStack(spacing: 12) {
                        Text(p.glyph)
                            .font(.chrome(11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Self.tile(p.tint)))
                            #if os(iOS)
                        .accessibilityHidden(true)
                            #endif
                        Text(Loc.t(p.title)).font(.chrome(14.5))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    #if os(macOS)
                    .foregroundStyle(selected ? Color.white : .primary)
                    .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color(hex: p.tint) : .clear))
                    #else
                    // The iPad's selected row is tinted, its name in the text colour (D407).
                    .foregroundStyle(.primary)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(selected ? Color(hex: p.tint).opacity(0.22) : .clear))
                    #endif
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // Read as the pane's name (not "G, General"), found by tests by its id.
                .accessibilityLabel(Loc.t(p.title))
                .accessibilityIdentifier("settings.pane.\(p.id)")
                .accessibilityAddTraits(pane == p.id ? .isSelected : [])
            }
        }
    }

    /// The tile behind a pane's glyph: its tint, which on the iPad is darkened until the
    /// white glyph reaches 7:1. The audit measures the small glyph's pixels, so tiles at
    /// 4.5–6:1 by the formula still came out short (D408).
    static func tile(_ hex: String) -> Color {
        #if os(macOS)
        Color(hex: hex)
        #else
        let c = Contrast.adjusted(RGBA(hex: hex), on: .white, target: 7)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
        #endif
    }

    var results: some View {
        let hits = SettingsSchema.search(query)
        return VStack(alignment: .leading, spacing: 6) {
            Text(
                hits.isEmpty
                    ? Loc.f("No settings match “%@”", query) : Loc.n("%lld result", "%lld results", hits.count)
            )
            .font(.chrome(22, weight: .bold))
            .padding(.bottom, 8)
            ForEach(Array(hits.enumerated()), id: \.offset) { _, h in
                Button {
                    pane = h.0.id
                    query = ""
                    highlight = h.2.key
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.2.title.isEmpty ? h.1.title : h.2.title).font(.chrome(14.5))
                            Text([h.0.title, h.1.title].filter { !$0.isEmpty }.joined(separator: " › "))
                                .font(.chrome(12.5)).foregroundStyle(.chromeSecondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.right").foregroundStyle(.chromeSecondary)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.controlBackground))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(30)
        .frame(maxWidth: 760, alignment: .leading)
    }
}

// MARK: A pane

struct PaneView: View {
    let pane: SettingPane
    var prefs: Preferences
    var availability: AIAvailability
    var highlight: String?
    var onAction: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Loc.t(pane.title)).font(.chrome(24, weight: .bold))
                Text(Loc.t(pane.subtitle)).font(.chrome(13.5)).foregroundStyle(.chromeSecondary)
            }
            let columns = Set(pane.sections.map(\.column))
            #if os(macOS)
            if columns.count > 1 {
                HStack(alignment: .top, spacing: 24) {
                    column(0)
                    column(1)
                }
            } else {
                column(0).frame(maxWidth: 820)
            }
            #else
            // The iPad's sheet is narrower than the Mac's window: one column (D407).
            VStack(alignment: .leading, spacing: 18) {
                ForEach(columns.sorted(), id: \.self) { column($0) }
            }
            .frame(maxWidth: 820)
            #endif
        }
    }

    func column(_ c: Int) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(pane.sections.filter { $0.column == c }) { s in
                SectionView(
                    section: s, prefs: prefs, availability: availability, highlight: highlight, onAction: onAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct SectionView: View {
    let section: SettingSection
    var prefs: Preferences
    var availability: AIAvailability
    var highlight: String?
    var onAction: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !section.title.isEmpty {
                Text(Loc.t(section.title))
                    .font(.chrome(14, weight: .semibold))
                    .foregroundStyle(.chromeSecondary)
                    .padding(.leading, 4)
            }
            let cards = section.rows.allSatisfy { if case .card = $0.kind { return true } else { return false } }
            if cards {
                ForEach(section.rows) { r in
                    CardView(row: r, prefs: prefs, availability: availability, onAction: onAction).id(r.key)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(section.rows.enumerated()), id: \.element.key) { i, r in
                        RowView(row: r, prefs: prefs, availability: availability, onAction: onAction)
                            .background(highlight == r.key ? Color.accentColor.opacity(0.12) : .clear)
                            .id(r.key)
                        if i < section.rows.count - 1 { Divider().padding(.leading, 18) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.controlBackground))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.6)))
            }
            if let f = section.footnote {
                Text(Loc.t(f)).font(.chrome(13)).foregroundStyle(.chromeSecondary).padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: Rows

struct RowView: View {
    /// Details that describe the current value (Allowed folders: "2 folders").
    static func liveDetail(_ row: SettingRow, _ prefs: Preferences) -> String? {
        switch row.key {
        case "integrations.folders":
            let n = AgentFolders.list(prefs).count
            return n == 0 ? nil : Loc.n("%lld folder", "%lld folders", n)
        default: return nil
        }
    }

    let row: SettingRow
    var prefs: Preferences
    var availability: AIAvailability
    var onAction: (String) -> Void

    var body: some View {
        let _ = prefs.revision
        if case .card = row.kind {
            CardView(row: row, prefs: prefs, availability: availability, onAction: onAction).padding(14)
        } else {
            arranged
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .accessibilityElement(children: combines ? .combine : .contain)
        }
    }

    /// Side by side when it fits; otherwise (long translations, large text) the control
    /// moves under the title instead of truncating.
    @ViewBuilder var arranged: some View {
        #if os(macOS)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                titleBlock
                Spacer(minLength: 12)
                lockedControl
            }
            VStack(alignment: .leading, spacing: 8) {
                titleBlock
                lockedControl
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        #else
        // One layout either way, so the title and control stay the same views as the
        // text size changes (D408).
        TitleAndControl {
            titleBlock
            lockedControl
        }
        #endif
    }

    /// Rows read as one control, except multi-line text, which stays a field of its own.
    var combines: Bool {
        if case .text = row.kind { return false }
        return true
    }

    var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Loc.t(row.title)).font(.chrome(13.5))
            if let d = Self.liveDetail(row, prefs) ?? row.detail {
                Text(Loc.t(d))
                    .font(.chrome(11.5))
                    .foregroundStyle(.chromeSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var lockedControl: some View {
        control
            .fixedSize()
            .disabled(row.locked != nil)
            .opacity(row.locked != nil ? 0.5 : 1)
            .help(row.locked.map(Loc.t) ?? "")
    }

    @ViewBuilder var control: some View {
        switch row.kind {
        case .toggle:
            Toggle("", isOn: Binding(get: { prefs.bool(row.key) }, set: { prefs.set(row.key, $0) }))
                .toggleStyle(.switch)
                .tint(.green)
                .labelsHidden()
                .accessibilityLabel(Loc.t(row.title))
        case .segmented(let options):
            SettingSegments(
                options: options, selection: Binding(get: { prefs.string(row.key) }, set: { prefs.set(row.key, $0) }))
        case .menu(let options):
            Picker("", selection: Binding(get: { prefs.string(row.key) }, set: { prefs.set(row.key, $0) })) {
                ForEach(options, id: \.value) { Text(Loc.t($0.label)).tag($0.value) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(Loc.t(row.title))
        case .number(let unit, let lo, let hi, let step) where (hi - lo) / step <= 100:
            // Ranges are sliders with their value (artboards 36, 39 and 42).
            HStack(spacing: 10) {
                Slider(
                    value: Binding(
                        get: { prefs.number(row.key) }, set: { prefs.set(row.key, ($0 / step).rounded() * step) }),
                    in: lo...hi
                )
                .frame(width: 120)
                .accessibilityLabel(Loc.t(row.title))
                Text("\(prefs.number(row.key), format: .number.precision(.fractionLength(step < 1 ? 1 : 0))) \(unit)")
                    .font(.chrome(12, design: .monospaced)).foregroundStyle(.chromeSecondary).frame(
                        minWidth: 44, alignment: .trailing)
            }
        case .number(let unit, let lo, let hi, let step):
            HStack(spacing: 6) {
                TextField(
                    "",
                    value: Binding(get: { prefs.number(row.key) }, set: { prefs.set(row.key, min(max($0, lo), hi)) }),
                    format: .number.precision(.fractionLength(step < 1 ? 1 : 0))
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(Loc.t(row.title))
                Text(unit).foregroundStyle(.chromeSecondary)
                Stepper(
                    "",
                    value: Binding(get: { prefs.number(row.key) }, set: { prefs.set(row.key, min(max($0, lo), hi)) }),
                    in: lo...hi, step: step
                )
                .labelsHidden()
            }
        case .text:
            TextField(
                "", text: Binding(get: { prefs.string(row.key) }, set: { prefs.set(row.key, $0) }), axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .font(.chrome(13, design: .monospaced))
            .lineLimit(1...4)
            .frame(width: 240)
            .accessibilityLabel(Loc.t(row.title))
        case .button(let title):
            Button(title) { onAction(row.key) }
        case .keycaps(let keys):
            HStack(spacing: 6) {
                ForEach(keys, id: \.self) { k in
                    Text(k).font(.chrome(12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(k.hasPrefix("✦") ? Color.white : .primary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5).fill(
                                k.hasPrefix("✦") ? Color.black : Color.textBackground)
                        )
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                }
            }
        case .info(let v):
            if v == "on-device" {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text(Loc.t(v)).foregroundStyle(Color.statusGreen)
                }
            } else if v == "Never" {
                Text(Loc.t(v)).font(.chrome(13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.badgeGreen))
            } else {
                Text(Loc.t(v)).foregroundStyle(.chromeSecondary)
            }
        case .card:
            EmptyView()
        }
    }
}

#if os(iOS)
/// A row's title and control: side by side when both fit at their ideal widths, with
/// at least 36 points between them (the Mac's spacing and spacer); otherwise the control
/// under the title. As `ViewThatFits` decides, but as one layout, so the views keep
/// their identity when the text size changes, which the accessibility audit relies on.
struct TitleAndControl: Layout {
    let gap: CGFloat = 36
    let below: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let title = subviews[0].sizeThatFits(.unspecified)
        let control = subviews[1].sizeThatFits(.unspecified)
        let width = proposal.width ?? title.width + gap + control.width
        if title.width + gap + control.width <= width {
            return CGSize(width: width, height: max(title.height, control.height))
        }
        let wrapped = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: wrapped.height + below + control.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let title = subviews[0].sizeThatFits(.unspecified)
        let control = subviews[1].sizeThatFits(.unspecified)
        if title.width + gap + control.width <= bounds.width {
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: bounds.width - gap - control.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
        } else {
            let width = ProposedViewSize(width: bounds.width, height: nil)
            let wrapped = subviews[0].sizeThatFits(width)
            subviews[0].place(at: bounds.origin, proposal: width)
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + wrapped.height + below), proposal: .unspecified)
        }
    }
}
#endif

/// The segmented controls on the settings artboards.
struct SettingSegments: View {
    let options: [SettingRow.Option]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { o in
                Button {
                    selection = o.value
                } label: {
                    Text(Loc.t(o.label))
                        .font(.chrome(13, weight: selection == o.value ? .semibold : .regular))
                        .padding(.horizontal, 11)
                        #if os(macOS)
                    .frame(height: 26)
                        #else
                    .frame(minHeight: 26)
                        #endif
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(
                                selection == o.value ? Color.textBackground : .clear
                            )
                            .shadow(color: .black.opacity(selection == o.value ? 0.12 : 0), radius: 1, y: 0.5)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == o.value ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
    }
}

extension Color {
    init(hex: String) {
        let c = RGBA(hex: hex)
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }
}
