import NexusAI
import NexusCore
import NexusFormat
import NexusScene
import NexusTheme
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The composite rows and preview cards of the settings artboards.
struct CardView: View {
    let row: SettingRow
    var prefs: Preferences
    var availability: AIAvailability
    var onAction: (String) -> Void

    var body: some View {
        let _ = prefs.revision
        switch row.kind {
        case .card("about"): AboutCard(onAction: onAction)
        case .card("mouseAids"): MouseAidsPreview()
        case .card("themeGrid"): ThemeGrid(prefs: prefs)
        case .card("lookPreview"): LookPreview(prefs: prefs)
        case .card("snapshotUsage"): SnapshotUsageRow()
        case .card("recoveryList"): RecoveryList(onAction: onAction)
        case .card("aiModels"): AISettingsPane(availability: availability)
        case .card("frames"): FramePicker(prefs: prefs)
        case .card("matColor"): MatColorRow(prefs: prefs)
        case .card("agentCard"): AgentCard(prefs: prefs)
        case .card("networkLog"): NetworkLogCard(prefs: prefs, log: ShareCenter.shared.log, onAction: onAction)
        case .card("shareDestinations"): ShareDestinationsCard(center: ShareCenter.shared)
        case .card("shareLinks"): ShareLinksCard(center: ShareCenter.shared)
        case .card("syncLibraries"): SyncLibrariesCard(center: SyncCenter.shared)
        case .card("syncLog"): SyncLogCard(center: SyncCenter.shared)
        case .card("maskPreview"): MaskPreviewCard(prefs: prefs)
        case .card("voiceOverPreview"): VoiceOverPreview(prefs: prefs)
        default: EmptyView()
        }
    }

    /// The cards the artboards draw as a settings card of their own. A section that opens
    /// with one is that card, its caption an uppercase kicker inside (`SectionView`); the
    /// other cards are lists under their section's header.
    static let framed: Set<String> = [
        "about", "mouseAids", "themeGrid", "lookPreview", "recoveryList", "frames", "matColor", "agentCard",
        "networkLog", "maskPreview", "voiceOverPreview",
    ]
    /// Framed cards drawn dark in both appearances: the network log reads as the system's
    /// record rather than a setting (artboard 41).
    static let dark: Set<String> = ["networkLog"]

    /// The card a section opens with, when it's one of `framed`.
    static func framedCard(_ section: SettingSection) -> String? {
        guard case .card(let c) = section.rows.first?.kind, framed.contains(c) else { return nil }
        return c
    }
}

/// A settings card. It follows the window's appearance like the rows around it (in Dark
/// mode a light card was a white slab in a dark pane); `dark` keeps one dark in both.
/// `SectionView` draws it around a section that opens with one of `CardView.framed`.
struct SettingsCard<Content: View>: View {
    var dark = false
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14).fill(
                    dark ? Color(hex: "#17171C") : Color.controlBackground)
            )
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(dark ? 0 : 0.6)))
            .environment(\.colorScheme, dark ? .dark : scheme)
    }
}

private struct AboutCard: View {
    var onAction: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                AppIconTile(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        Loc.f(
                            "OpenNexus %@",
                            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                                ?? "1.0")
                    )
                    .font(.chrome(18, weight: .semibold))
                    Text(
                        Loc.f(
                            "Build %@ · Open source · MIT",
                            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1")
                    )
                    .foregroundStyle(.chromeSecondary)
                }
            }
            #if os(macOS)
            HStack { links }
            #else
            // On a row, wrapping where they don't fit (a phone); the same views as the
            // text grows, which the audit follows.
            FlowLayout(spacing: 8) { links }
            #endif
            Text("Usage statistics are off. See Privacy & Data.").font(.chrome(13)).foregroundStyle(
                .chromeSecondary)
        }
    }

    @ViewBuilder var links: some View {
        Button("Source code") { onAction("about.source") }
        Button("Acknowledgements") { onAction("about.acknowledgements") }
        Button("Release notes") { onAction("about.notes") }
        Button("Report an issue…") { onAction("about.issue") }
    }
}

/// Artboard 36's preview: a selected topic on a dotted canvas, with its two + buttons and
/// the floating toolbar above and to its right.
private struct MouseAidsPreview: View {
    static let iris = Tokens.Signal.irisLight.swiftUI

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                CanvasWell()
                HStack(spacing: 0) {
                    // Up to 220 points in, as the artboard; nearer the node when the card is narrow.
                    Color.clear.frame(maxWidth: 220).layoutPriority(1)
                    toolbar.fixedSize()
                    Spacer(minLength: 10)
                }
                .frame(height: 34)
                .padding(.top, 20)
                Text("Pricing").font(.chrome(14, weight: .medium))
                    .frame(width: 120, height: 36)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.textBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10).strokeBorder(
                            Tokens.Signal.auroraLight.swiftUI, lineWidth: 2)
                    )
                    // The selection ring, 2 points out from the topic's border.
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Self.iris, lineWidth: 2).padding(-4))
                    .offset(x: 40, y: 58)
                plus(filled: true).offset(x: 168, y: 64)
                plus(filled: false).offset(x: 88, y: 102)
            }
            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .illustration(Loc.t("A topic with its two + buttons, and the floating toolbar above it"))
            Text(
                "Right + adds a child (⇥), lower + a sibling (↩). The floating toolbar offers AI ideas, connect, link, image, note, to-do and style. It never appears while typing."
            )
            .font(.chrome(13)).foregroundStyle(.chromeSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    var toolbar: some View {
        HStack(spacing: 2) {
            Text("✦ Ideas").foregroundStyle(Color.statusTeal).padding(.horizontal, 6)
            ForEach(["⇢", "↗", "▣", "≡", "☐", "Aa"], id: \.self) { Text($0).padding(.horizontal, 6) }
        }
        .font(.chrome(12))
        .padding(.horizontal, 6).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.textBackground.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator.opacity(0.6)))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 8)
    }

    /// The right + (a child) is filled; the lower + (a sibling) is outlined.
    func plus(filled: Bool) -> some View {
        Text("+").font(.chrome(16, weight: .semibold)).foregroundStyle(filled ? Color.white : Self.iris)
            .frame(width: 24, height: 24)
            .background(Circle().fill(filled ? Self.iris : Color.textBackground))
            .overlay(Circle().strokeBorder(Self.iris, lineWidth: filled ? 0 : 1.5))
    }
}

/// A canvas well with the canvas's dot grid, every 18 points.
private struct CanvasWell: View {
    var body: some View {
        Canvas { ctx, size in
            for x in stride(from: CGFloat(9), to: size.width, by: 18) {
                for y in stride(from: CGFloat(9), to: size.height, by: 18) {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .style(.separator))
                }
            }
        }
        .background(Color.secondary.opacity(0.06))
    }
}

/// Artboard 37's theme grid: each theme's canvas with three of its branch colours.
private struct ThemeGrid: View {
    var prefs: Preferences
    static let ids = [
        "classic", "paper", "graphite", "blueprint", "pastel", "midnightNeon", "solarized", "highContrast",
    ]
    var body: some View {
        let selected = prefs.string("appearance.theme")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
            ForEach(Self.ids, id: \.self) { id in
                let t = Theme.named(id)
                Button {
                    prefs.set("appearance.theme", id)
                } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(t.palette.isEmpty ? t.ink.swiftUI : t.palette[i % t.palette.count].swiftUI)
                                    .frame(width: 10, height: 10)
                            }
                        }
                        .frame(maxWidth: .infinity).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 8).fill(t.canvas.swiftUI))
                        .selectionRing(selected == id, cornerRadius: 8)
                        Text(id == "midnightNeon" ? Loc.t("Neon") : t.name).font(
                            .chrome(12.5, weight: selected == id ? .semibold : .regular))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Loc.f("Theme %@", t.name))
                .accessibilityAddTraits(selected == id ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Themes")
    }
}

extension View {
    /// The artboards' choice ring: 2 points of Iris, 2 points out from a chosen tile; a
    /// hairline on the others.
    func selectionRing(_ on: Bool, cornerRadius r: CGFloat) -> some View {
        overlay {
            if on {
                RoundedRectangle(cornerRadius: r + 4).strokeBorder(Tokens.Signal.irisLight.swiftUI, lineWidth: 2)
                    .padding(-4)
            } else {
                RoundedRectangle(cornerRadius: r).strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
            }
        }
    }
}

/// Theme + node style + colour theme, rendered by the real canvas.
private struct LookPreview: View {
    var prefs: Preferences
    @State private var image: CGImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06))
                if let image {
                    Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit).padding(6)
                        .illustration(Loc.t("A sample map in the chosen theme, node style and colour theme"))
                }
            }
            .frame(height: 92)
            Text("Live preview of theme + node style + colour theme. Documents keep their own look once created.")
                .font(.chrome(13)).foregroundStyle(.chromeSecondary)
        }
        .task(id: prefs.revision) { render() }
    }

    func render() {
        var c = NexusCore.Canvas(id: "c1", title: "Launch", rootText: "Launch")
        CanvasController.applyDefaults(&c, prefs: prefs)
        var undo = UndoStack()
        c.edit("Sample", undo: &undo) { e in
            for t in ["Pricing", "Channels", "Risks"] { _ = try? e.addChild(of: e.canvas.root, text: t) }
        }
        var o = ImageExporter.Options()
        o.scale = 2
        o.padding = 20
        image = ImageExporter.image(DocumentModel(canvases: [c]), canvas: "c1", o)
    }
}

/// Recovery › Using: a row like the others, the snapshots' size as its subtitle.
private struct SnapshotUsageRow: View {
    @State private var bytes: Int64 = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Using").font(.chrome(13.5))
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                .font(.chrome(11.5)).foregroundStyle(.chromeSecondary).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .task { bytes = SnapshotStore.usage() }
    }
}

private struct RecoveryList: View {
    var onAction: (String) -> Void
    @State private var items: [RecoverySnapshot] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("RECOVERY").font(.chrome(12, weight: .semibold)).foregroundStyle(.chromeSecondary)
                Spacer()
                Text(Loc.n("%lld snapshot", "%lld snapshots", items.count)).font(.chrome(12.5))
                    .foregroundStyle(.chromeSecondary)
            }
            if items.isEmpty {
                Text("No snapshots yet. They appear as you edit.").foregroundStyle(.chromeSecondary)
            }
            ForEach(items.prefix(4)) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.date.formatted(date: .abbreviated, time: .shortened)).font(
                            .chrome(13.5, weight: .medium))
                        Text(
                            s.encrypted
                                ? Loc.n(
                                    "Crash recovery · %lld topic · encrypted",
                                    "Crash recovery · %lld topics · encrypted", s.topics)
                                : Loc.n("Crash recovery · %lld topic", "Crash recovery · %lld topics", s.topics)
                        ).font(
                            .chrome(12.5)
                        ).foregroundStyle(.chromeSecondary)
                    }
                    Spacer()
                    Button("Compare") { onAction("snapshot.compare:\(s.url.path)") }
                    Button("Restore as copy") { onAction("snapshot.copy:\(s.url.path)") }
                }
                .padding(.vertical, 4)
            }
        }
        .task { items = SnapshotStore.allRecent() }
    }
}

/// Artboard 39's six image frames, each a small card on the frame it gets.
private struct FramePicker: View {
    var prefs: Preferences
    static let frames: [(String, String)] = [
        ("none", Loc.t("None")), ("softShadow", Loc.t("Soft shadow")), ("window", Loc.t("Window")),
        ("gradientMat", Loc.t("Gradient mat")),
        ("paper", Loc.t("Paper")),
        ("darkMat", Loc.t("Dark mat")),
    ]
    var body: some View {
        let selected = prefs.string("export.frame")
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(Self.frames, id: \.0) { id, title in
                Button {
                    prefs.set("export.frame", id)
                } label: {
                    VStack(spacing: 6) {
                        FrameSample(frame: id, mat: Color(hex: prefs.string("export.matColor")))
                            .frame(height: 70)
                            .overlay {
                                if selected == id {
                                    RoundedRectangle(cornerRadius: 12).strokeBorder(
                                        Tokens.Signal.irisLight.swiftUI, lineWidth: 2
                                    )
                                    .padding(-4)
                                }
                            }
                        Text(title).font(.chrome(12.5, weight: selected == id ? .semibold : .regular))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Loc.f("Frame %@", title))
                .accessibilityAddTraits(selected == id ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Frames")
    }
}

/// One frame as artboard 39 draws it: the frame's background with a map's card on it. The
/// colours are the export's, so they don't follow the window's appearance.
struct FrameSample: View {
    let frame: String
    var mat: Color
    static let iris = Tokens.Signal.irisLight.swiftUI

    var body: some View {
        ZStack {
            background
            content
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder var background: some View {
        switch frame {
        case "softShadow": Color(hex: "#ECECEF")
        case "window": Color(hex: "#DDE2EC")
        // The export's gradient (`ImageExporter`).
        case "gradientMat":
            LinearGradient(colors: [mat, Color(hex: "#BFE7E3")], startPoint: .topLeading, endPoint: .bottomTrailing)
        case "paper": Color(hex: "#F4EFE4")
        case "darkMat": Color(hex: "#121317")
        default: Color(hex: "#F7F7F5")
        }
    }

    @ViewBuilder var content: some View {
        switch frame {
        case "softShadow":
            card(radius: 8).shadow(color: Color(hex: "#17171C").opacity(0.25), radius: 8, y: 8)
        case "window":
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    ForEach(["#FF5F57", "#FEBC2E", "#28C840"], id: \.self) {
                        Circle().fill(Color(hex: $0)).frame(width: 4, height: 4)
                    }
                    Spacer()
                }
                .padding(.horizontal, 4).frame(height: 9)
                .overlay(alignment: .bottom) { Color(hex: "#E2E2E6").frame(height: 1) }
                Spacer()
            }
            .frame(width: 64, height: 44)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
            .shadow(color: Color(hex: "#17171C").opacity(0.2), radius: 7, y: 6)
        case "gradientMat": card(radius: 8)
        case "paper":
            card(width: 50, height: 30, stroke: Color(hex: "#8C5A3C"))
                .padding(EdgeInsets(top: 5, leading: 5, bottom: 12, trailing: 5))
                .background(Color.white)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 3)
        case "darkMat": card(radius: 8, fill: Color(hex: "#1C1D22"), stroke: Tokens.Signal.irisDark.swiftUI)
        default: card()
        }
    }

    func card(
        radius: CGFloat = 5, width: CGFloat = 56, height: CGFloat = 34, fill: Color = .white, stroke: Color = iris
    ) -> some View {
        RoundedRectangle(cornerRadius: radius).fill(fill)
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(stroke, lineWidth: 1.5))
            .frame(width: width, height: height)
    }
}

/// Mat colour: artboard 39's four presets, then a well for any other colour.
private struct MatColorRow: View {
    var prefs: Preferences
    static let presets: [(hex: String, name: String)] = [
        ("#C9C5FA", Loc.t("Lavender")), ("#ECECEF", Loc.t("Light grey")), ("#121317", Loc.t("Black")),
        ("#F4EFE4", Loc.t("Cream")),
    ]

    var body: some View {
        let current = prefs.string("export.matColor").uppercased()
        HStack(spacing: 12) {
            Text("Mat colour").font(.chrome(13.5))
            Spacer()
            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.hex) { p in
                    Button {
                        prefs.set("export.matColor", p.hex)
                    } label: {
                        Circle().fill(Color(hex: p.hex)).frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
                            .overlay {
                                if current == p.hex { Circle().strokeBorder(.primary, lineWidth: 1.5).padding(-3.5) }
                            }
                            .padding(3.5)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(p.name)
                    .accessibilityAddTraits(current == p.hex ? .isSelected : [])
                }
                ColorPicker(
                    "",
                    selection: Binding(
                        get: { Color(hex: prefs.string("export.matColor")) },
                        set: { c in
                            if let rgb = c.srgbComponents {
                                prefs.set(
                                    "export.matColor",
                                    String(
                                        format: "#%02X%02X%02X", Int(rgb.red * 255), Int(rgb.green * 255),
                                        Int(rgb.blue * 255)))
                            }
                        })
                )
                .labelsHidden()
                .accessibilityLabel("Custom colour")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mat colour")
    }
}

private struct AgentCard: View {
    var prefs: Preferences
    var body: some View {
        let on = prefs.bool("integrations.mcp")
        let folders = AgentFolders.list(prefs).count
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text("CONNECT AN AGENT").font(.chrome(12.5, weight: .semibold)).foregroundStyle(.chromeSecondary)
                Spacer()
                Circle().fill(on ? Color.green : Color.gray.opacity(0.6)).frame(width: 7, height: 7)
                Text(
                    on
                        ? (folders > 0 ? Loc.t("Server on · local only") : Loc.t("On · allow a folder first"))
                        : Loc.t("Server off · local only")
                )
                .font(.chrome(12.5)).foregroundStyle(
                    on ? AnyShapeStyle(Color.statusGreen) : AnyShapeStyle(.chromeSecondary))
            }
            Text(
                "Any MCP client on this Mac (Claude, Codex, Cursor…) can read and edit maps in the folders you allow. Nothing is uploaded."
            )
            .font(.chrome(12.5)).foregroundStyle(.chromeSecondary).fixedSize(horizontal: false, vertical: true)
            Self.code(
                """
                $ nexus mcp            # stdio server
                $ nexus new "Q3 plan" --type mindmap
                $ nexus export plan.nexus --to mermaid
                $ nexus validate plan.nexus
                """)
            Self.code(
                """
                // MCP client config
                { "opennexus": { "command": "nexus", "args": ["mcp"] } }
                """)
            FlowChips(
                read: ["list_maps", "read_map"],
                edit: ["add_topic", "add_edge", "set_style", "convert_type", "export"])
        }
    }

    /// Commands and config on a dark block (artboard 40), selectable for copying.
    static func code(_ text: String) -> some View {
        Text(text).font(.chrome(11.5, design: .monospaced)).foregroundStyle(.white.opacity(0.92))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: "#17171C")))
    }
}

/// The MCP tools: reading (indigo) and changing things (amber).
private struct FlowChips: View {
    let read: [String]
    let edit: [String]
    var body: some View {
        // Wrapping with even gaps, as artboard 40 does; a grid left uneven holes and let long
        // names run into their neighbours.
        FlowLayout(spacing: 6) {
            ForEach(read + edit, id: \.self) { t in
                let isRead = read.contains(t)
                Text(t).font(.chrome(11.5, design: .monospaced))
                    .foregroundStyle(isRead ? Color(hex: "#3F38C8") : Color(hex: "#8A5A00"))
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5).fill(isRead ? Color(hex: "#ECEBFF") : Color(hex: "#FFF1D6")))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("MCP tools")
    }
}

/// The network log, on a card that's dark in both appearances (`CardView.dark`).
private struct NetworkLogCard: View {
    var prefs: Preferences
    var log: NetworkLog
    var onAction: (String) -> Void
    var body: some View {
        let _ = prefs.revision
        let recent = log.recent()
        let head = NetworkActivity.headline(prefs, log: recent)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(head.value).font(.chrome(34, weight: .bold, design: .monospaced))
                Text(head.unit).font(.chrome(14)).foregroundStyle(.white.opacity(0.75))
            }
            .accessibilityElement(children: .combine)
            Text(NetworkActivity.summary(prefs, log: recent))
                .font(.chrome(12.5)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open log…") { onAction("privacy.log") }
                Button("Export Log…") { onAction("privacy.exportLog") }.disabled(log.entries.isEmpty)
            }
        }
        .foregroundStyle(.white)
    }
}

private struct MaskPreviewCard: View {
    var prefs: Preferences
    static let samples = [
        "Owner: dana.ruiz@example.com", "Stripe key sk_" + "live_ExampleNotARealKey0", "Call +1 555 010 0199 if paged",
    ]
    var body: some View {
        let o = Self.options(prefs)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.samples, id: \.self) { s in
                Text(Self.styled(Masker.mask(s, options: o), from: s)).font(.chrome(13.5))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
            }
            Text(
                "Detected on-device with the Natural Language framework plus your patterns. Masking applies to the export copy; your document is unchanged."
            )
            .font(.chrome(13)).foregroundStyle(.chromeSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The masked sample with only what masking replaced in mono, as artboard 41 sets it:
    /// the run between what the sample and its masked copy share at either end.
    static func styled(_ masked: String, from sample: String) -> AttributedString {
        let a = Array(sample)
        let b = Array(masked)
        let head = zip(a, b).prefix { $0 == $1 }.count
        let tail = min(zip(a.reversed(), b.reversed()).prefix { $0 == $1 }.count, min(a.count, b.count) - head)
        var secret = AttributedString(String(b[head..<(b.count - tail)]))
        secret.font = .chrome(13.5, design: .monospaced)
        return AttributedString(String(b[..<head])) + secret + AttributedString(String(b[(b.count - tail)...]))
    }

    static func options(_ prefs: Preferences) -> Masker.Options {
        var o = Masker.Options()
        var kinds: Set<Masker.Kind> = [.custom]
        if prefs.bool("privacy.maskEmails") { kinds.insert(.emails) }
        if prefs.bool("privacy.maskPhones") { kinds.insert(.phones) }
        if prefs.bool("privacy.maskKeys") { kinds.insert(.keys) }
        if prefs.bool("privacy.maskNames") { kinds.insert(.names) }
        o.kinds = kinds
        o.custom = prefs.string("privacy.maskPatterns").split(separator: "\n").map(String.init)
            .filter { (try? NSRegularExpression(pattern: $0)) != nil }
        o.glyph = prefs.string("privacy.maskGlyph")
        return o
    }
}

/// Artboard 42: the topic under the VoiceOver cursor and what VoiceOver says, in the
/// caption panel's dark bubble.
private struct VoiceOverPreview: View {
    var prefs: Preferences
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Pricing").font(.chrome(14, weight: .medium))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.textBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10).strokeBorder(
                            Tokens.Signal.auroraLight.swiftUI, lineWidth: 2)
                    )
                    // The VoiceOver cursor: a thick ring 2 points out.
                    .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.primary, lineWidth: 3).padding(-5))
                    .padding(5)
                Text("→").font(.chrome(12)).foregroundStyle(.chromeSecondary)
            }
            Text("“\(Spoken.sample(prefs))”").font(.chrome(13)).lineSpacing(3)
                .foregroundStyle(Color(hex: "#F2F2F5"))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: "#26272D")))
            Text(
                "Rotor categories: Nodes, Edges, Boundaries, Notes, AI suggestions. Connect mode reads targets by hint letter."
            )
            .font(.chrome(13)).foregroundStyle(.chromeSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension RGBA {
    var swiftUI: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}
