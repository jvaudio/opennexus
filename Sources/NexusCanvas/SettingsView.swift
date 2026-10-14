import AppKit
import NexusAI
import NexusCore
import NexusFormat
import NexusKeys
import NexusTheme
import SwiftUI

/// Settings (⌘,; artboards 08, 29 and 35–42), generated from `SettingsSchema`. Search
/// (⌘F or the sidebar field) finds every row and jumps to it.
public struct SettingsView: View {
    var prefs: Preferences
    var availability: AIAvailability
    var onAction: (String) -> Void
    @State private var pane: String
    @State private var query = ""
    @State private var highlight: String?
    @FocusState private var searchFocused: Bool

    public init(
        prefs: Preferences = .shared, availability: AIAvailability, pane: String = "general",
        onAction: @escaping (String) -> Void = { _ in }
    ) {
        self.prefs = prefs
        self.availability = availability
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
                        ShortcutsPane(prefs: prefs).padding(.horizontal, 36).padding(.vertical, 30)
                    } else if let p = SettingsSchema.pane(pane) {
                        PaneView(
                            pane: p, prefs: prefs, availability: availability, highlight: highlight, onAction: onAction
                        )
                        .padding(.horizontal, 30).padding(.vertical, 28)
                    }
                }
                .onChange(of: highlight) { _, h in
                    if let h { withAnimation { proxy.scrollTo(h, anchor: .center) } }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 1100, minHeight: 760)
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
            ForEach(SettingsSchema.panes) { p in
                Button {
                    query = ""
                    highlight = nil
                    pane = p.id
                } label: {
                    HStack(spacing: 12) {
                        Text(p.glyph)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: p.tint)))
                        Text(p.title).font(.system(size: 14.5))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .foregroundStyle(pane == p.id && query.isEmpty ? Color.white : .primary)
                    .background(
                        RoundedRectangle(cornerRadius: 8).fill(
                            pane == p.id && query.isEmpty ? Color(hex: p.tint) : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(pane == p.id ? .isSelected : [])
            }
            Spacer()
            Text("⌘, opens Settings · ⌘F searches every pane").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 250)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.5))
    }

    var results: some View {
        let hits = SettingsSchema.search(query)
        return VStack(alignment: .leading, spacing: 6) {
            Text(hits.isEmpty ? "No settings match “\(query)”" : "\(hits.count) result\(hits.count == 1 ? "" : "s")")
                .font(.system(size: 22, weight: .bold))
                .padding(.bottom, 8)
            ForEach(Array(hits.enumerated()), id: \.offset) { _, h in
                Button {
                    pane = h.0.id
                    query = ""
                    highlight = h.2.key
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.2.title.isEmpty ? h.1.title : h.2.title).font(.system(size: 14.5))
                            Text([h.0.title, h.1.title].filter { !$0.isEmpty }.joined(separator: " › "))
                                .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
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
                Text(pane.title).font(.system(size: 24, weight: .bold))
                Text(pane.subtitle).font(.system(size: 13.5)).foregroundStyle(.secondary)
            }
            let columns = Set(pane.sections.map(\.column))
            if columns.count > 1 {
                HStack(alignment: .top, spacing: 24) {
                    column(0)
                    column(1)
                }
            } else {
                column(0).frame(maxWidth: 820)
            }
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
                Text(section.title.uppercased() == section.title ? section.title : section.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
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
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.6)))
            }
            if let f = section.footnote {
                Text(f).font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 4)
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
            return n == 0 ? nil : n == 1 ? "1 folder" : "\(n) folders"
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
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.system(size: 13.5))
                    if let d = Self.liveDetail(row, prefs) ?? row.detail {
                        Text(d)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
                    .disabled(row.locked != nil)
                    .opacity(row.locked != nil ? 0.5 : 1)
                    .help(row.locked ?? "")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder var control: some View {
        switch row.kind {
        case .toggle:
            Toggle("", isOn: Binding(get: { prefs.bool(row.key) }, set: { prefs.set(row.key, $0) }))
                .toggleStyle(.switch)
                .tint(.green)
                .labelsHidden()
                .accessibilityLabel(row.title)
        case .segmented(let options):
            SettingSegments(
                options: options, selection: Binding(get: { prefs.string(row.key) }, set: { prefs.set(row.key, $0) }))
        case .menu(let options):
            Picker("", selection: Binding(get: { prefs.string(row.key) }, set: { prefs.set(row.key, $0) })) {
                ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(row.title)
        case .number(let unit, let lo, let hi, let step) where (hi - lo) / step <= 100:
            // Ranges are sliders with their value (artboards 36, 39 and 42).
            HStack(spacing: 10) {
                Slider(
                    value: Binding(
                        get: { prefs.number(row.key) }, set: { prefs.set(row.key, ($0 / step).rounded() * step) }),
                    in: lo...hi
                )
                .frame(width: 120)
                .accessibilityLabel(row.title)
                Text("\(prefs.number(row.key), format: .number.precision(.fractionLength(step < 1 ? 1 : 0))) \(unit)")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary).frame(
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
                .accessibilityLabel(row.title)
                Text(unit).foregroundStyle(.secondary)
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
            .font(.system(size: 13, design: .monospaced))
            .lineLimit(1...4)
            .frame(width: 240)
            .accessibilityLabel(row.title)
        case .button(let title):
            Button(title) { onAction(row.key) }
        case .keycaps(let keys):
            HStack(spacing: 6) {
                ForEach(keys, id: \.self) { k in
                    Text(k).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(k.hasPrefix("✦") ? Color.white : .primary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5).fill(
                                k.hasPrefix("✦") ? Color.black : Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                }
            }
        case .info(let v):
            if v == "on-device" {
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text(v).foregroundStyle(.green)
                }
            } else if v == "Never" {
                Text(v).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.green))
            } else {
                Text(v).foregroundStyle(.secondary)
            }
        case .card:
            EmptyView()
        }
    }
}

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
                    Text(o.label)
                        .font(.system(size: 13, weight: selection == o.value ? .semibold : .regular))
                        .padding(.horizontal, 11).frame(height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(
                                selection == o.value ? Color(nsColor: .textBackgroundColor) : .clear
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
