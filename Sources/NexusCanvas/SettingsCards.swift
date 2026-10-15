import AppKit
import NexusAI
import NexusCore
import NexusFormat
import NexusTheme
import SwiftUI

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
        case .card("networkLog"): NetworkLogCard(onAction: onAction)
        case .card("maskPreview"): MaskPreviewCard(prefs: prefs)
        case .card("voiceOverPreview"): VoiceOverPreview(prefs: prefs)
        default: EmptyView()
        }
    }
}

private struct Card<Content: View>: View {
    var dark = false
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14).fill(
                    dark ? Color(white: 0.1) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.separator.opacity(dark ? 0 : 0.6)))
            .environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// The OpenNexus mark: a triangle of three nodes.
public struct AppMark: View {
    var size: CGFloat = 48
    public init(size: CGFloat = 48) { self.size = size }
    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24)
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.2), Color(white: 0.11)], startPoint: .top, endPoint: .bottom)
                )
                .overlay(RoundedRectangle(cornerRadius: size * 0.24).stroke(Color.white.opacity(0.1)))
                .shadow(color: .black.opacity(0.45), radius: size * 0.12, y: size * 0.06)
            Canvas { ctx, s in
                let a = CGPoint(x: s.width * 0.5, y: s.height * 0.3)
                let b = CGPoint(x: s.width * 0.34, y: s.height * 0.66)
                let c = CGPoint(x: s.width * 0.66, y: s.height * 0.66)
                var p = Path()
                p.move(to: a)
                p.addLine(to: b)
                p.addLine(to: c)
                p.closeSubpath()
                ctx.stroke(
                    p,
                    with: .linearGradient(
                        Gradient(colors: [Color(hex: "#9B8CFF"), Color(hex: "#3DD6C6")]), startPoint: b, endPoint: c),
                    lineWidth: s.width * 0.05)
                let r = s.width * 0.07
                ctx.fill(
                    Path(ellipseIn: CGRect(x: a.x - r, y: a.y - r, width: r * 2, height: r * 2)), with: .color(.white))
                ctx.fill(
                    Path(ellipseIn: CGRect(x: b.x - r, y: b.y - r, width: r * 2, height: r * 2)),
                    with: .color(Color(hex: "#9B8CFF")))
                ctx.fill(
                    Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                    with: .color(Color(hex: "#3DD6C6")))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct AboutCard: View {
    var onAction: (String) -> Void
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    AppMark(size: 54)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            "OpenNexus \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")"
                        )
                        .font(.chrome(18, weight: .semibold))
                        Text(
                            "Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1") · Open source · MIT"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button("Source code") { onAction("about.source") }
                    Button("Release notes") { onAction("about.notes") }
                    Button("Report an issue…") { onAction("about.issue") }
                }
                Text("Usage statistics are off. See Privacy & Data.").font(.chrome(13)).foregroundStyle(
                    .secondary)
            }
        }
    }
}

private struct MouseAidsPreview: View {
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 18) {
                    ZStack(alignment: .topLeading) {
                        HStack(spacing: 4) {
                            Text("✦ Ideas").font(.chrome(12, weight: .semibold)).foregroundStyle(.teal)
                            ForEach(["⇢", "↗", "▣", "≡", "☐", "Aa"], id: \.self) {
                                Text($0).font(.chrome(12)).frame(width: 22)
                            }
                        }
                        .padding(.horizontal, 8).frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)).shadow(
                                color: .black.opacity(0.12), radius: 6, y: 2)
                        )
                        .offset(x: 0, y: 0)
                        Text("Pricing").font(.chrome(15, weight: .medium))
                            .padding(.horizontal, 18).frame(height: 38)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(hex: "#E4572E"), lineWidth: 2))
                            .offset(x: 30, y: 44)
                        plus.offset(x: 132, y: 53)
                        plus.offset(x: 62, y: 92)
                    }
                    .frame(width: 240, height: 120, alignment: .topLeading)
                }
                Text(
                    "Right + adds a child (⇥), lower + a sibling (↩). The floating toolbar offers AI ideas, connect, link, image, note, to-do and style. It never appears while typing."
                )
                .font(.chrome(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    var plus: some View {
        Text("+").font(.chrome(13, weight: .bold)).foregroundStyle(.white)
            .frame(width: 20, height: 20).background(Circle().fill(Color(hex: "#5850EC")))
    }
}

/// Artboard 37's theme grid.
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
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(t.canvas.swiftUI)
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 3).fill(t.root.background.swiftUI).frame(
                                    width: 20, height: 9)
                                VStack(spacing: 3) {
                                    ForEach(0..<3, id: \.self) { i in
                                        RoundedRectangle(cornerRadius: 2).stroke(
                                            t.palette.isEmpty ? t.ink.swiftUI : t.palette[i % t.palette.count].swiftUI,
                                            lineWidth: 1.5
                                        )
                                        .frame(width: 16, height: 6)
                                    }
                                }
                            }
                        }
                        .frame(height: 54)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8).stroke(
                                selected == id ? Color(hex: "#5850EC") : Color.secondary.opacity(0.25),
                                lineWidth: selected == id ? 2.5 : 1))
                        Text(id == "midnightNeon" ? "Neon" : t.name).font(
                            .chrome(12.5, weight: selected == id ? .semibold : .regular))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Theme \(t.name)")
                .accessibilityAddTraits(selected == id ? .isSelected : [])
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.6)))
    }
}

/// Theme + node style + colour theme, rendered by the real canvas.
private struct LookPreview: View {
    var prefs: Preferences
    @State private var image: CGImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.06))
                if let image {
                    Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit).padding(10)
                }
            }
            .frame(height: 170)
            Text("Live preview of theme + node style + colour theme. Documents keep their own look once created.")
                .font(.chrome(13)).foregroundStyle(.secondary)
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

private struct SnapshotUsageRow: View {
    @State private var bytes: Int64 = 0
    var body: some View {
        HStack {
            Text("Using").font(.chrome(14.5))
            Spacer()
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)).foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .task { bytes = SnapshotStore.usage() }
    }
}

private struct RecoveryList: View {
    var onAction: (String) -> Void
    @State private var items: [RecoverySnapshot] = []
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("RECOVERY").font(.chrome(12, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(items.count) snapshot\(items.count == 1 ? "" : "s")").font(.chrome(12.5))
                        .foregroundStyle(.secondary)
                }
                if items.isEmpty {
                    Text("No snapshots yet. They appear as you edit.").foregroundStyle(.secondary)
                }
                ForEach(items.prefix(4)) { s in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.date.formatted(date: .abbreviated, time: .shortened)).font(
                                .chrome(13.5, weight: .medium))
                            Text("Crash recovery · \(s.topics) topics\(s.encrypted ? " · encrypted" : "")").font(
                                .chrome(12.5)
                            ).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Compare") { onAction("snapshot.compare:\(s.url.path)") }
                        Button("Restore as copy") { onAction("snapshot.copy:\(s.url.path)") }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .task { items = SnapshotStore.allRecent() }
    }
}

/// Artboard 39's six image frames.
private struct FramePicker: View {
    var prefs: Preferences
    static let frames: [(String, String)] = [
        ("none", "None"), ("softShadow", "Soft shadow"), ("window", "Window"), ("gradientMat", "Gradient mat"),
        ("paper", "Paper"),
        ("darkMat", "Dark mat"),
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
                            .overlay(
                                RoundedRectangle(cornerRadius: 8).stroke(
                                    selected == id ? Color(hex: "#5850EC") : Color.secondary.opacity(0.25),
                                    lineWidth: selected == id ? 2.5 : 1))
                        Text(title).font(.chrome(12.5, weight: selected == id ? .semibold : .regular))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Frame \(title)")
                .accessibilityAddTraits(selected == id ? .isSelected : [])
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

struct FrameSample: View {
    let frame: String
    var mat: Color
    var body: some View {
        ZStack {
            switch frame {
            case "gradientMat":
                LinearGradient(
                    colors: [mat, Color(hex: "#BFE7E3")], startPoint: .topLeading, endPoint: .bottomTrailing)
            case "paper": Color(hex: "#F4EFE4")
            case "darkMat": Color(white: 0.12)
            default: Color(nsColor: .textBackgroundColor)
            }
            VStack(spacing: 0) {
                if frame == "window" {
                    HStack(spacing: 3) {
                        ForEach([Color.red, .yellow, .green], id: \.self) {
                            Circle().fill($0).frame(width: 4, height: 4)
                        }
                        Spacer()
                    }
                    .padding(4).background(Color.secondary.opacity(0.15))
                }
                Color(hex: "#F7F7F5").overlay(
                    RoundedRectangle(cornerRadius: 2).fill(Color.black).frame(width: 18, height: 7))
            }
            .clipShape(RoundedRectangle(cornerRadius: frame == "none" ? 0 : 4))
            .shadow(
                color: .black.opacity(frame == "softShadow" || frame.hasSuffix("Mat") || frame == "window" ? 0.25 : 0),
                radius: 4, y: 2
            )
            .padding(frame == "none" ? 0 : 10)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct MatColorRow: View {
    var prefs: Preferences
    var body: some View {
        HStack {
            Text("Mat colour").font(.chrome(14.5))
            Spacer()
            ColorPicker(
                "",
                selection: Binding(
                    get: { Color(hex: prefs.string("export.matColor")) },
                    set: { c in
                        if let ns = NSColor(c).usingColorSpace(.sRGB) {
                            prefs.set(
                                "export.matColor",
                                String(
                                    format: "#%02X%02X%02X", Int(ns.redComponent * 255), Int(ns.greenComponent * 255),
                                    Int(ns.blueComponent * 255)))
                        }
                    })
            )
            .labelsHidden()
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

private struct AgentCard: View {
    var prefs: Preferences
    var body: some View {
        let on = prefs.bool("integrations.mcp")
        let folders = AgentFolders.list(prefs).count
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text("CONNECT AN AGENT").font(.chrome(12.5, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Circle().fill(on ? Color.green : Color.gray.opacity(0.6)).frame(width: 7, height: 7)
                    Text(
                        on
                            ? (folders > 0 ? "Server on · local only" : "On · allow a folder first")
                            : "Server off · local only"
                    )
                    .font(.chrome(12.5)).foregroundStyle(on ? Color.green : .secondary)
                }
                Text(
                    "Any MCP client on this Mac (Claude, Codex, Cursor…) can read and edit maps in the folders you allow. Nothing is uploaded."
                )
                .font(.chrome(12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 96), spacing: 6, alignment: .leading)], alignment: .leading,
            spacing: 6
        ) {
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
    }
}

private struct NetworkLogCard: View {
    var onAction: (String) -> Void
    var body: some View {
        // Dark like artboard 41, so the log reads as the system's record rather than a setting.
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("0").font(.chrome(34, weight: .bold))
                Text("requests").font(.chrome(14)).foregroundStyle(.white.opacity(0.75))
            }
            Text(
                "Documents, AI prompts and AI results never leave this Mac. OpenNexus has no network permission, so this log stays empty."
            )
            .font(.chrome(12.5)).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            Button("Open log…") { onAction("privacy.log") }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: "#17171C")))
    }
}

private struct MaskPreviewCard: View {
    var prefs: Preferences
    static let samples = [
        "Owner: dana.ruiz@example.com", "Stripe key sk_" + "live_ExampleNotARealKey0", "Call +1 555 010 0199 if paged",
    ]
    var body: some View {
        let o = Self.options(prefs)
        Card {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.samples, id: \.self) { s in
                    Text(Masker.mask(s, options: o)).font(.chrome(13.5, design: .monospaced))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
                }
                Text(
                    "Detected on-device with the Natural Language framework plus your patterns. Masking applies to the export copy; your document is unchanged."
                )
                .font(.chrome(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
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

private struct VoiceOverPreview: View {
    var prefs: Preferences
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text("Pricing").font(.chrome(15, weight: .medium))
                        .padding(.horizontal, 16).frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 10).stroke(Color.teal, lineWidth: 2))
                    Text("→").foregroundStyle(.secondary)
                }
                Text("“\(Spoken.sample(prefs))”").font(.chrome(14)).italic()
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    "Rotor categories: Nodes, Edges, Boundaries, Notes, AI suggestions. Connect mode reads targets by hint letter."
                )
                .font(.chrome(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension RGBA {
    var swiftUI: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

// MARK: Spoken descriptions (VoiceOver)

/// What VoiceOver says for a topic, shaped by Settings › Accessibility › VoiceOver.
@MainActor
public enum Spoken {
    public static func describe(
        _ id: NodeID, in c: NexusCore.Canvas, prefs: Preferences, branchColor: String? = nil,
        depth knownDepth: Int? = nil,
        maxDepth knownMax: Int? = nil
    ) -> String {
        guard let n = c.nodes[id] else { return "" }
        let depth: Int
        let maxDepth: Int
        if let knownDepth, let knownMax {
            (depth, maxDepth) = (knownDepth, knownMax)
        } else {
            // One walk from the root gives every depth.
            let d = depths(c)
            depth = d.depths[id] ?? c.depth(of: id)
            maxDepth = d.max
        }
        var parts: [String] = [n.text.isEmpty ? "Topic" : n.text]
        let role =
            id == c.root
            ? "Central topic" : c.floating.contains(id) ? "Floating topic" : depth == 1 ? "Main topic" : "Subtopic"
        if prefs.bool("accessibility.announceLevel") {
            parts.append("\(role), level \(depth + 1) of \(maxDepth + 1)")
            parts.append(
                "\(n.children.count) \(n.children.count == 1 ? "child" : "children")\(n.folded ? ", collapsed" : "")")
        } else {
            parts.append(role)
        }
        if let t = n.nodeType, let info = DiagramCatalog.info(t, in: c.type) { parts.append(info.name) }
        if let b = branchColor { parts.append("Branch colour \(b)") }
        if let todo = n.todo { parts.append(todo.done ? "Done" : "To do") }
        if n.note != nil { parts.append("Has note") }
        if prefs.string("accessibility.readEdges") == "source" {
            for r in c.relationships where r.from == id || r.to == id {
                let other = r.from == id ? r.to : r.from
                let label = r.label.isEmpty ? "" : " by ‘\(r.label)’"
                parts.append("Connected to \(c.nodes[other]?.text ?? "a topic")\(label)")
            }
        }
        if prefs.bool("accessibility.speakHints") { parts.append("Tab adds a child") }
        return parts.joined(separator: ". ") + "."
    }

    /// Depth of every topic in the tree under the root (floating tops start their own).
    public static func depths(_ c: NexusCore.Canvas) -> (depths: [NodeID: Int], max: Int) {
        var depths: [NodeID: Int] = [:]
        for top in c.tops { c.walk(from: top) { id, _, d in depths[id] = d } }
        return (depths, depths.values.max() ?? 0)
    }

    /// A plain colour word for a branch colour ("teal", "orange"…), for VoiceOver.
    public static func colorName(_ c: RGBA) -> String {
        let mx = max(c.r, c.g, c.b)
        let mn = min(c.r, c.g, c.b)
        let delta = mx - mn
        if delta < 0.08 { return mx > 0.85 ? "white" : mx < 0.2 ? "black" : "grey" }
        var h: Double
        if mx == c.r {
            h = ((c.g - c.b) / delta).truncatingRemainder(dividingBy: 6)
        } else if mx == c.g {
            h = (c.b - c.r) / delta + 2
        } else {
            h = (c.r - c.g) / delta + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        switch h {
        case ..<15, 345...: return "red"
        case ..<40: return "orange"
        case ..<65: return "yellow"
        case ..<150: return "green"
        case ..<195: return "teal"
        case ..<235: return "blue"
        case ..<260: return "indigo"
        case ..<290: return "purple"
        default: return "pink"
        }
    }

    static func sample(_ prefs: Preferences) -> String {
        var c = NexusCore.Canvas(id: "c1", title: "", rootText: "Launch plan")
        var undo = UndoStack()
        c.edit("Sample", undo: &undo) { e in
            let p = try! e.addChild(of: e.canvas.root, text: "Pricing")
            for t in ["Free", "Pro", "Team"] {
                let k = try! e.addChild(of: p, text: t)
                _ = try? e.addChild(of: k, text: "Seats")
            }
            e.update(p) {
                $0.folded = true
                $0.note = Note(text: "x")
            }
            let t = try! e.addChild(of: e.canvas.root, text: "Timeline")
            _ = e.connect(p, to: t, label: "drives")
        }
        let id = c.nodes.first { $0.value.text == "Pricing" }!.key
        return describe(id, in: c, prefs: prefs, branchColor: "teal").replacingOccurrences(
            of: "level 2 of 4", with: "level 2 of 4")
    }
}
