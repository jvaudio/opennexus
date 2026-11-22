import NexusCore
import NexusScene
import NexusTheme
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: Slash menu

struct SlashMenuView: View {
    var controller: CanvasController

    /// Each type's icon colour (artboard 17): the hue it takes on the canvas, so the list
    /// reads by type before the words do. Others (the note among them) stay ink.
    static let tints: [String: String] = [
        "process": "#9B51E0", "db": "#0F7F7A", "actor": "#1E6FB8", "decision": "#E0A100", "code": "#5850EC",
        "math": "#D6408B",
    ]

    var body: some View {
        if let s = controller.slash {
            let items = Array(controller.slashResults.prefix(9))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text("/").font(.chrome(13, weight: .bold, design: .monospaced)).foregroundStyle(.chromeSecondary)
                    Text(s.query.isEmpty ? Loc.t("Type to filter") : s.query)
                        .font(.chrome(13, design: .monospaced))
                        .foregroundStyle(s.query.isEmpty ? .tertiary : .primary)
                    Spacer()
                    Keycap(text: "esc")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                if items.isEmpty {
                    Text("No matches").font(.chrome(12)).foregroundStyle(.chromeSecondary).padding(12)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    HStack(spacing: 10) {
                        Group {
                            if let icon = item.icon {
                                IconGlyph(icon: icon).frame(width: 16, height: 16)
                            } else {
                                Text(item.glyph).font(.chrome(12, weight: .semibold))
                            }
                        }
                        .frame(width: 22)
                        .foregroundStyle(Self.tints[item.slug].map { RGBA(hex: $0).color } ?? .primary)
                        Text(item.title).font(.chrome(13))
                        Spacer()
                        Text("/\(item.slug)").font(.chrome(11, design: .monospaced)).foregroundStyle(.chromeSecondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7).fill(
                            i == s.highlighted
                                ? (controller.theme.isDark ? Tokens.Signal.irisDark : Tokens.Signal.irisLight).color
                                    .opacity(0.12) : .clear)
                    )
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .accessibleTap { controller.applySlash(item) }
                }
            }
            .frame(width: 300)
            .chromeMaterial(in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.separator))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Insert menu")
        }
    }
}

/// One of the 32 technical icons as a SwiftUI shape.
struct IconGlyph: View {
    let icon: String
    var lineWidth: CGFloat = 1.6

    var body: some View {
        GeometryReader { g in
            if let p = TechIcons.path(icon, in: CGRect(origin: .zero, size: g.size)) {
                Path(p).stroke(
                    style: StrokeStyle(lineWidth: lineWidth * g.size.width / 24, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: Protocol suggestions (architecture labels)

struct ProtocolSuggestionsView: View {
    var controller: CanvasController

    var body: some View {
        let list = controller.protocolSuggestions
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(list.prefix(5).enumerated()), id: \.offset) { i, p in
                    Text(p)
                        .font(.chrome(12.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(i == controller.suggestionIndex ? Color.accentColor.opacity(0.2) : .clear)
                }
            }
            .frame(width: 190)
            .chromeMaterial(in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor.opacity(0.6)))
        }
    }
}

// MARK: Convert (⌥⌘T, artboard 10)

struct ConvertSheetView: View {
    var controller: CanvasController

    var body: some View {
        if let s = controller.convert {
            HStack(alignment: .top, spacing: 20) {
                picker(s)
                if s.step == .confirm { confirm(s) }
            }
            .padding(24)
        }
    }

    func picker(_ s: ConvertState) -> some View {
        let results = controller.convertResults
        let featured = results.filter { CanvasController.featuredTypes.contains($0) }
        let more = results.filter { CanvasController.moreTypes.contains($0) }
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(Loc.f("Convert “%@” to…", controller.canvas.nodes[controller.canvas.root]?.text ?? ""))
                    .font(.chrome(17, weight: .semibold))
                Spacer()
                Text(s.filter.isEmpty ? Loc.t("Filter types") : s.filter)
                    .font(.chrome(13))
                    .foregroundStyle(s.filter.isEmpty ? .tertiary : .primary)
                    .frame(width: 200, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).stroke(.separator))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(150), spacing: 12), count: 4), spacing: 12) {
                ForEach(featured, id: \.self) { t in
                    tile(t, number: (CanvasController.featuredTypes.firstIndex(of: t) ?? 0) + 1, s: s)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Diagram types")
            if !more.isEmpty {
                HStack(spacing: 6) {
                    Text("More").font(.chrome(11, weight: .semibold)).foregroundStyle(.chromeSecondary)
                    ForEach(more, id: \.self) { t in
                        Button(Loc.t(t.displayName)) { controller.chooseConvertType(t) }
                            .buttonStyle(.plain)
                            .font(.chrome(12))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 6).fill(
                                    t == s.highlighted ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)
                                ))
                    }
                }
            }
            Text(
                "Previews are rendered from **this** canvas. Arrow keys move; ↩ converts; Esc closes. Hierarchy types convert losslessly; technical types ask for node types next."
            )
            .font(.chrome(12))
            .foregroundStyle(.chromeSecondary)
            .fixedWidth(636, alignment: .leading)
        }
        .padding(22)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator))
        .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
    }

    func tile(_ t: DiagramType, number: Int, s: ConvertState) -> some View {
        let on = t == s.highlighted
        let current = t == controller.canvas.type
        return VStack(alignment: .leading, spacing: 8) {
            WireframePreview(scene: controller.previewScene(for: t))
                .frame(height: 84)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(on ? 0.06 : 0.08)))
            HStack {
                Text(Loc.t(t.displayName)).font(.chrome(13, weight: .medium))
                if current { Text("current").font(.chrome(10)).foregroundStyle(.chromeSecondary) }
                Spacer()
                Keycap(text: "\(number)")
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(on ? Color.accentColor.opacity(0.07) : .clear)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .accessibleTap { controller.chooseConvertType(t) }
        .accessibilityLabel("\(Loc.t(t.displayName)), \(number)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    func confirm(_ s: ConvertState) -> some View {
        let options = DiagramCatalog.nodeTypes(for: s.highlighted)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Confirm node types").font(.chrome(17, weight: .semibold))
            Text(
                Loc.f(
                    "%@ needs to know what each first-level branch is. Suggestions (✦) are made on this Mac.",
                    Loc.t(s.highlighted.displayName))
            )
            .font(.chrome(12))
            .foregroundStyle(.chromeSecondary)
            .frame(width: 330, alignment: .leading)
            ForEach(Array(s.rows.enumerated()), id: \.element) { i, row in
                HStack {
                    Text(controller.canvas.nodes[row]?.text ?? "").font(.chrome(13))
                    Spacer()
                    if s.suggested.contains(row) {
                        Text("✦").foregroundStyle(controller.theme.ai.color)
                    }
                    Picker(
                        "",
                        selection: Binding(
                            get: { s.proposals[row] ?? options.first?.id ?? "process" },
                            set: { controller.setConvertProposal(row, $0) })
                    ) {
                        ForEach(options, id: \.id) { Text(Loc.t($0.name)).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8).fill(
                        i == s.confirmIndex ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.06)))
            }
            HStack {
                Spacer()
                Button("Back") { controller.convert?.step = .pick }
                Button("Convert · ↩") {
                    let st = controller.convert
                    controller.closeConvert()
                    if let st { controller.performConvert(st.highlighted, nodeTypes: st.proposals) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(width: 360)
        .padding(22)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator))
        .shadow(color: .black.opacity(0.2), radius: 24, y: 10)
    }
}

/// A wireframe of a scene: outlines and connector lines, fitted to the tile. A sequence also
/// draws its lifelines and messages, so its tile reads as a sequence and not a row of boxes.
struct WireframePreview: View {
    let scene: NexusScene.Scene

    /// Each participant's frame and where its lifeline ends.
    var lifelines: [(frame: CGRect, bottom: CGFloat)] {
        scene.decor.compactMap { d in
            guard case .lifeline(let id, let bottom, _) = d, let f = scene.nodes[id]?.frame.rect else { return nil }
            return (f, max(bottom, f.maxY))
        }
        .sorted { $0.frame.midX < $1.frame.midX }
    }

    var body: some View {
        Canvas { ctx, size in
            let lifelines = lifelines
            let nodes = scene.nodes.values.reduce(CGRect.null) { $0.union($1.frame.rect) }
            let b = lifelines.reduce(nodes) { b, l in
                b.union(CGRect(x: l.frame.minX, y: l.frame.minY, width: l.frame.width, height: l.bottom - l.frame.minY))
            }
            guard !b.isNull, b.width > 0, b.height > 0 else { return }
            let k = min((size.width - 16) / b.width, (size.height - 12) / b.height, 0.35)
            let dx = (size.width - b.width * k) / 2 - b.minX * k
            let dy = (size.height - b.height * k) / 2 - b.minY * k
            func t(_ r: CGRect) -> CGRect {
                CGRect(x: r.minX * k + dx, y: r.minY * k + dy, width: r.width * k, height: r.height * k)
            }
            var lines = Path()
            for e in scene.edges {
                guard let a = scene.nodes[e.parent]?.frame.rect, let c = scene.nodes[e.child]?.frame.rect else {
                    continue
                }
                lines.move(to: CGPoint(x: t(a).midX, y: t(a).midY))
                lines.addLine(to: CGPoint(x: t(c).midX, y: t(c).midY))
            }
            for r in scene.relationships {
                if let pts = r.points, pts.count >= 2 {
                    lines.move(to: CGPoint(x: pts[0].x * k + dx, y: pts[0].y * k + dy))
                    for p in pts.dropFirst() { lines.addLine(to: CGPoint(x: p.x * k + dx, y: p.y * k + dy)) }
                    continue
                }
                guard let a = scene.rect(of: r.relationship.from), let c = scene.rect(of: r.relationship.to) else {
                    continue
                }
                lines.move(to: CGPoint(x: t(a).midX, y: t(a).midY))
                lines.addLine(to: CGPoint(x: t(c).midX, y: t(c).midY))
            }
            for l in lifelines {
                let r = t(l.frame)
                lines.move(to: CGPoint(x: r.midX, y: r.maxY))
                lines.addLine(to: CGPoint(x: r.midX, y: l.bottom * k + dy))
            }
            // A hierarchy has no messages yet: one stair of calls between neighbours shows the
            // shape the participants take once it has some.
            if lifelines.count > 1, !scene.relationships.contains(where: { $0.points != nil }) {
                let top = lifelines.map { t($0.frame).maxY }.max() ?? 0
                let bottom = lifelines.map { $0.bottom * k + dy }.min() ?? top
                let step = (bottom - top) / CGFloat(lifelines.count)
                for i in 0..<lifelines.count - 1 {
                    let y = top + step * CGFloat(i + 1) * 0.8
                    lines.move(to: CGPoint(x: t(lifelines[i].frame).midX, y: y))
                    lines.addLine(to: CGPoint(x: t(lifelines[i + 1].frame).midX, y: y))
                }
            }
            ctx.stroke(lines, with: .color(.secondary.opacity(0.7)), lineWidth: 1)
            for n in scene.nodes.values {
                let r = t(n.frame.rect)
                let path: Path =
                    switch n.appearance.shape {
                    case "diamond":
                        Path { p in
                            p.move(to: CGPoint(x: r.midX, y: r.minY))
                            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
                            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
                            p.addLine(to: CGPoint(x: r.minX, y: r.midY))
                            p.closeSubpath()
                        }
                    case "pill", "ellipse", "circle": Path(roundedRect: r, cornerRadius: r.height / 2)
                    case "text": Path()
                    default: Path(roundedRect: r, cornerRadius: 1.5)
                    }
                ctx.fill(path, with: .color(Color.textBackground))
                ctx.stroke(path, with: .color(.primary.opacity(0.75)), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: DFD panel, breadcrumb and violation card (artboard 20)

struct DFDPanelView: View {
    var controller: CanvasController

    var body: some View {
        if controller.canvas.type == .dfd, controller.present == nil {
            let c = controller.canvas
            VStack(alignment: .leading, spacing: 8) {
                Text("LEVELS").font(.chrome(11, weight: .semibold)).foregroundStyle(.chromeSecondary)
                ForEach(controller.levelPath, id: \.id) { l in
                    Text(l.title)
                        .font(.chrome(13, weight: l.id == c.id ? .semibold : .regular))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(
                                l.id == c.id ? Color.accentColor.opacity(0.14) : .clear)
                        )
                        .accessibleTap { controller.switchCanvas(to: l.id) }
                }
                let numbers = DFDRules.numbers(c)
                ForEach(
                    FlowGraph(c).elements.filter { DiagramCatalog.effectiveType($0, in: c) == .process }, id: \.self
                ) { p in
                    Text("\(numbers[p] ?? "") \(c.nodes[p]?.text ?? "")")
                        .font(.chrome(12.5))
                        .padding(.leading, 18)
                        .foregroundStyle(c.nodes[p]?.subCanvas != nil ? .primary : .secondary)
                        .accessibleTap { controller.select(p) }
                }
                Text("RULE CHECKS").font(.chrome(11, weight: .semibold)).foregroundStyle(.chromeSecondary).padding(
                    .top, 10)
                ForEach(DFDRules.summary(controller.violations), id: \.rule.rawValue) { row in
                    HStack(spacing: 8) {
                        Circle().fill(row.ok ? Color.green : controller.theme.critical.color).frame(width: 7, height: 7)
                        Text(row.text).font(.chrome(12.5)).foregroundStyle(
                            row.ok ? Color.green : controller.theme.critical.color)
                    }
                    .accessibleTap {
                        if let v = controller.violations.first(where: { $0.rule == row.rule }) {
                            controller.focusViolation(v.id)
                        }
                    }
                }
                Text("⌘. drills into a process").font(.chrome(11)).foregroundStyle(.chromeTertiary).padding(.top, 6)
            }
            .padding(14)
            .frame(width: 230, alignment: .leading)
            .chromeMaterial(in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        }
    }
}

struct ViolationCardView: View {
    var controller: CanvasController

    var body: some View {
        if controller.present == nil,
            controller.canvas.type == .dfd
                || (controller.canvas.type == .threatModel && !controller.threatTableVisible),
            let v = controller.shownViolation
        {
            let red = controller.theme.critical.color
            VStack(alignment: .leading, spacing: 8) {
                Text(v.title).font(.chrome(14, weight: .semibold)).foregroundStyle(red)
                Text(v.detail).font(.chrome(12.5)).frame(width: 360, alignment: .leading)
                HStack(spacing: 8) {
                    ForEach(Array(v.fixes.enumerated()), id: \.offset) { i, f in
                        let title: String =
                            switch f {
                            case .insertProcess: Loc.t("Insert process")
                            case .rerouteVia(_, let p):
                                Loc.f(
                                    "Reroute via %@",
                                    DFDRules.numbers(controller.canvas)[p] ?? controller.canvas.nodes[p]?.text ?? "")
                            case .ignore: Loc.t("Ignore")
                            }
                        if i == 0 {
                            Button(title + " ↩") { controller.applyFix(f, violation: v.id) }.buttonStyle(
                                .borderedProminent)
                        } else {
                            Button(title) { controller.applyFix(f, violation: v.id) }
                        }
                    }
                }
            }
            .padding(16)
            .chromeMaterial(in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(red.opacity(0.6)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Loc.f("Rule check: %@", v.title))
        }
    }
}

struct LevelBreadcrumbView: View {
    var controller: CanvasController

    var body: some View {
        let path = controller.levelPath
        if controller.canvas.type == .dfd, path.count > 1, controller.present == nil {
            HStack(spacing: 6) {
                ForEach(Array(path.enumerated()), id: \.offset) { i, l in
                    if i > 0 { Text("›").foregroundStyle(.chromeSecondary) }
                    Text(l.title)
                        .font(.chrome(12.5, weight: i == path.count - 1 ? .semibold : .regular))
                        .accessibleTap { controller.switchCanvas(to: l.id) }
                }
                Keycap(text: "⌘[")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .chromeMaterial(in: Capsule())
        }
    }
}

// MARK: Threat model (artboard 21)

struct ThreatSuggestionCard: View {
    var controller: CanvasController

    var body: some View {
        let s = controller.strideSuggestionsForSelection
        if controller.canvas.type == .threatModel, !s.isEmpty, controller.mode == .select, controller.present == nil {
            let teal = controller.theme.ai.color
            let c = controller.canvas
            let id = controller.selection.primary
            // A process goes by its number ("2.0"), as on the canvas; "more" once it has threats.
            let subject = DFDRules.numbers(c)[id] ?? c.nodes[id]?.text ?? ""
            let more = controller.threats.contains { $0.element == id }
            let count =
                more
                ? Loc.n("%lld more STRIDE threat", "%lld more STRIDE threats", s.count)
                : Loc.n("%lld STRIDE threat", "%lld STRIDE threats", s.count)
            VStack(alignment: .leading, spacing: 4) {
                Text(Loc.f("✦ %@ suggested for %@", count, subject))
                    .font(.chrome(13, weight: .semibold)).foregroundStyle(teal)
                HStack(spacing: 6) {
                    Text(s.map { $0.0 == .denialOfService ? Loc.t("DoS") : Loc.t($0.0.name) }.joined(separator: " · "))
                        .font(.chrome(12))
                    Keycap(text: "⌃⇧↩")
                    Text("accept all").font(.chrome(12)).foregroundStyle(.chromeSecondary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(teal.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(teal, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }
    }
}

struct ThreatTableView: View {
    var controller: CanvasController
    @State private var filter = "Open"

    var body: some View {
        if controller.canvas.type == .threatModel, controller.threatTableVisible, controller.present == nil {
            let all = controller.threats
            let rows = filter == "All" ? all : all.filter { $0.status == filter }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Threat table").font(.chrome(14, weight: .semibold))
                    Picker("", selection: $filter) {
                        ForEach(["All"] + Stride.statuses, id: \.self) { Text(Loc.t($0)) }  // tags stay English
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    Spacer()
                    Button("Export CSV") { controller.exportThreatsCSV(rows) }
                    Button("Copy as Markdown") { controller.copyThreatsMarkdown(rows) }
                    Button {
                        controller.threatTableVisible = false
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close threat table")
                }
                .padding(12)
                Divider()
                Table(rows) {
                    TableColumn("ID") { Text($0.id).font(.chrome(12, design: .monospaced)) }.width(52)
                    TableColumn("Element", value: \.elementName)
                    TableColumn("STRIDE") { Text($0.category.map { Loc.t($0.name) } ?? "—") }
                    TableColumn("Threat", value: \.title)
                    TableColumn("Risk") { RiskPill(risk: $0.risk, dark: controller.theme.isDark) }
                        .width(60)
                    TableColumn("Mitigation") { Text($0.mitigation ?? "—") }
                    TableColumn("Status") { Text(Loc.t($0.status)) }.width(80)
                }
                .frame(height: 200)
            }
            // Docked full width under the canvas, as artboard 21 draws it, not a card over it.
            .frame(maxWidth: .infinity)
            .background(.background)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

// MARK: Icon library (⇧⌘Y, artboard 22)

struct IconLibraryView: View {
    var controller: CanvasController
    @State private var query = ""

    /// Tile labels: a 62-point tile fits about ten characters, so the long catalog names get
    /// the short words the artboard uses. The full name stays the accessibility label and is
    /// what an inserted node is called.
    static let tileNames: [String: String] = [
        "gateway": "Gateway", "lb": "Balancer", "stream": "Stream", "storage": "Storage", "saas": "SaaS",
        "auth": "Auth", "monitor": "Monitor", "entity": "Entity", "store": "Data store",
    ]

    var body: some View {
        if controller.iconLibraryVisible {
            let q = query.lowercased()
            let icons = DiagramCatalog.icons.filter {
                q.isEmpty || $0.name.lowercased().contains(q) || $0.slug.contains(q)
                    || $0.category.lowercased().contains(q)
            }
            let groups = Dictionary(grouping: icons, by: \.category)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Icon library").font(.chrome(14, weight: .semibold))
                    Spacer()
                    Keycap(text: "⇧⌘Y")
                }
                TextField("Search icons", text: $query).textFieldStyle(.roundedBorder)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(
                            [
                                ("Data", Loc.t("Data")), ("Compute", Loc.t("Compute")), ("Network", Loc.t("Network")),
                                ("Clients", Loc.t("Clients")), ("Security", Loc.t("Security")),
                                ("Diagram", Loc.t("Diagram")),
                            ], id: \.0
                        ) { cat, title in
                            if let items = groups[cat] {
                                Text(title.uppercased())
                                    .font(.chrome(11, weight: .semibold, design: .monospaced))
                                    .tracking(1.2)
                                    .foregroundStyle(.secondary)
                                LazyVGrid(
                                    columns: Array(repeating: GridItem(.fixed(62), spacing: 6), count: 4), spacing: 6
                                ) {
                                    ForEach(items, id: \.slug) { info in
                                        Button {
                                            controller.insertIcon(info)
                                        } label: {
                                            VStack(spacing: 4) {
                                                IconGlyph(icon: info.icon ?? info.slug).frame(width: 22, height: 22)
                                                Text(Loc.t(Self.tileNames[info.slug] ?? info.name))
                                                    .font(.chrome(10)).lineLimit(1)
                                            }
                                            .frame(width: 62, height: 58)
                                            .background(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                                        }
                                        .buttonStyle(.plain)
                                        .onDrag {
                                            NSItemProvider(
                                                object: (CanvasController.iconDragPrefix + info.slug) as NSString)
                                        }
                                        .help("/\(info.slug)")
                                        .accessibilityLabel(Loc.t(info.name))
                                    }
                                }
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel("Icon library")
                            }
                        }
                    }
                }
                .accessibilityLabel(Loc.t("Icons"))
                Text(
                    "Drag onto the canvas, or click to insert as a child of the selection. Icon packs install from file or URL."
                )
                .font(.chrome(11)).foregroundStyle(.chromeSecondary)
            }
            .padding(14)
            .frame(width: 290, height: 520)
            .chromeMaterial(in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        }
    }
}

extension Stride.Threat: Hashable {
    public func hash(into h: inout Hasher) { h.combine(id) }
}
