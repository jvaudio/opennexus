import AppKit
import NexusCore
import NexusTheme
import SwiftUI

// MARK: Slash menu

struct SlashMenuView: View {
    var controller: CanvasController

    var body: some View {
        if let s = controller.slash {
            let items = Array(controller.slashResults.prefix(9))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text("/").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                    Text(s.query.isEmpty ? "Type to filter" : s.query)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(s.query.isEmpty ? .tertiary : .primary)
                    Spacer()
                    Keycap(text: "esc")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                Divider()
                if items.isEmpty {
                    Text("No matches").font(.system(size: 12)).foregroundStyle(.secondary).padding(12)
                }
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    HStack(spacing: 10) {
                        Group {
                            if let icon = item.icon {
                                IconGlyph(icon: icon).frame(width: 16, height: 16)
                            } else {
                                Text(item.glyph).font(.system(size: 12, weight: .semibold))
                            }
                        }
                        .frame(width: 22)
                        Text(item.title).font(.system(size: 13))
                        Spacer()
                        Text("/\(item.slug)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(i == s.highlighted ? Color.accentColor.opacity(0.16) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { controller.applySlash(item) }
                }
            }
            .frame(width: 300)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
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
                        .font(.system(size: 12.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(i == controller.suggestionIndex ? Color.accentColor.opacity(0.2) : .clear)
                }
            }
            .frame(width: 190)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
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
                Text("Convert “\(controller.canvas.nodes[controller.canvas.root]?.text ?? "")” to…")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                Text(s.filter.isEmpty ? "Filter types" : s.filter)
                    .font(.system(size: 13))
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
            if !more.isEmpty {
                HStack(spacing: 6) {
                    Text("More").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(more, id: \.self) { t in
                        Button(t.displayName) { controller.chooseConvertType(t) }
                            .buttonStyle(.plain)
                            .font(.system(size: 12))
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
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 636, alignment: .leading)
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
                Text(t.displayName).font(.system(size: 13, weight: .medium))
                if current { Text("current").font(.system(size: 10)).foregroundStyle(.secondary) }
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
        .onTapGesture { controller.chooseConvertType(t) }
        .accessibilityLabel("\(t.displayName), \(number)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    func confirm(_ s: ConvertState) -> some View {
        let options = DiagramCatalog.nodeTypes(for: s.highlighted)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Confirm node types").font(.system(size: 17, weight: .semibold))
            Text(
                "\(s.highlighted.displayName) needs to know what each first-level branch is. Suggestions (✦) are made on this Mac."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 330, alignment: .leading)
            ForEach(Array(s.rows.enumerated()), id: \.element) { i, row in
                HStack {
                    Text(controller.canvas.nodes[row]?.text ?? "").font(.system(size: 13))
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
                        ForEach(options, id: \.id) { Text($0.name).tag($0.id) }
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

/// A wireframe of a scene: outlines and connector lines, fitted to the tile.
struct WireframePreview: View {
    let scene: Scene

    var body: some View {
        Canvas { ctx, size in
            let b = scene.nodes.values.reduce(CGRect.null) { $0.union($1.frame.rect) }
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
                guard let a = scene.nodes[r.relationship.from]?.frame.rect,
                    let c = scene.nodes[r.relationship.to]?.frame.rect
                else { continue }
                lines.move(to: CGPoint(x: t(a).midX, y: t(a).midY))
                lines.addLine(to: CGPoint(x: t(c).midX, y: t(c).midY))
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
                ctx.fill(path, with: .color(Color(nsColor: .textBackgroundColor)))
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
                Text("LEVELS").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(controller.levelPath, id: \.id) { l in
                    Text(l.title)
                        .font(.system(size: 13, weight: l.id == c.id ? .semibold : .regular))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(
                                l.id == c.id ? Color.accentColor.opacity(0.14) : .clear)
                        )
                        .onTapGesture { controller.switchCanvas(to: l.id) }
                }
                let numbers = DFDRules.numbers(c)
                ForEach(
                    FlowGraph(c).elements.filter { DiagramCatalog.effectiveType($0, in: c) == .process }, id: \.self
                ) { p in
                    Text("\(numbers[p] ?? "") \(c.nodes[p]?.text ?? "")")
                        .font(.system(size: 12.5))
                        .padding(.leading, 18)
                        .foregroundStyle(c.nodes[p]?.subCanvas != nil ? .primary : .secondary)
                        .onTapGesture { controller.select(p) }
                }
                Text("RULE CHECKS").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(
                    .top, 10)
                ForEach(DFDRules.summary(controller.violations), id: \.rule.rawValue) { row in
                    HStack(spacing: 8) {
                        Circle().fill(row.ok ? Color.green : controller.theme.critical.color).frame(width: 7, height: 7)
                        Text(row.text).font(.system(size: 12.5)).foregroundStyle(
                            row.ok ? Color.green : controller.theme.critical.color)
                    }
                    .onTapGesture {
                        if let v = controller.violations.first(where: { $0.rule == row.rule }) {
                            controller.focusViolation(v.id)
                        }
                    }
                }
                Text("⌘. drills into a process").font(.system(size: 11)).foregroundStyle(.tertiary).padding(.top, 6)
            }
            .padding(14)
            .frame(width: 230, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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
                Text(v.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(red)
                Text(v.detail).font(.system(size: 12.5)).frame(width: 360, alignment: .leading)
                HStack(spacing: 8) {
                    ForEach(Array(v.fixes.enumerated()), id: \.offset) { i, f in
                        let title: String =
                            switch f {
                            case .insertProcess: "Insert process"
                            case .rerouteVia(_, let p):
                                "Reroute via \(DFDRules.numbers(controller.canvas)[p] ?? controller.canvas.nodes[p]?.text ?? "")"
                            case .ignore: "Ignore"
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(red.opacity(0.6)))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Rule check: \(v.title)")
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
                    if i > 0 { Text("›").foregroundStyle(.secondary) }
                    Text(l.title)
                        .font(.system(size: 12.5, weight: i == path.count - 1 ? .semibold : .regular))
                        .onTapGesture { controller.switchCanvas(to: l.id) }
                }
                Keycap(text: "⌘[")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
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
            let name = controller.canvas.nodes[controller.selection.primary]?.text ?? ""
            VStack(alignment: .leading, spacing: 4) {
                Text("✦ \(s.count) STRIDE threat\(s.count == 1 ? "" : "s") suggested for \(name)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(teal)
                HStack(spacing: 6) {
                    Text(s.map(\.0.name).joined(separator: " · ")).font(.system(size: 12))
                    Keycap(text: "⌃⇧↩")
                    Text("accept all").font(.system(size: 12)).foregroundStyle(.secondary)
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
                    Text("Threat table").font(.system(size: 14, weight: .semibold))
                    Picker("", selection: $filter) {
                        ForEach(["All"] + Stride.statuses, id: \.self) { Text($0) }
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
                    TableColumn("ID", value: \.id).width(52)
                    TableColumn("Element", value: \.elementName)
                    TableColumn("STRIDE") { Text($0.category?.name ?? "—") }
                    TableColumn("Threat", value: \.title)
                    TableColumn("Risk") { t in
                        Text(t.risk)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 3).fill(
                                    t.risk == "High"
                                        ? controller.theme.critical.color.opacity(0.2)
                                        : controller.theme.amber.color.opacity(0.2)))
                    }
                    .width(60)
                    TableColumn("Mitigation") { Text($0.mitigation ?? "—") }
                    TableColumn("Status", value: \.status).width(80)
                }
                .frame(height: 200)
            }
            .frame(width: 960)
            .background(.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        }
    }
}

// MARK: Icon library (⇧⌘Y, artboard 22)

struct IconLibraryView: View {
    var controller: CanvasController
    @State private var query = ""

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
                    Text("Icon library").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Keycap(text: "⇧⌘Y")
                }
                TextField("Search icons", text: $query).textFieldStyle(.roundedBorder)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(["Data", "Compute", "Network", "Clients", "Security", "Diagram"], id: \.self) { cat in
                            if let items = groups[cat] {
                                Text(cat.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(
                                    .secondary)
                                LazyVGrid(
                                    columns: Array(repeating: GridItem(.fixed(62), spacing: 6), count: 4), spacing: 6
                                ) {
                                    ForEach(items, id: \.slug) { info in
                                        Button {
                                            controller.insertIcon(info)
                                        } label: {
                                            VStack(spacing: 4) {
                                                IconGlyph(icon: info.icon ?? info.slug).frame(width: 22, height: 22)
                                                Text(info.name).font(.system(size: 10)).lineLimit(1)
                                            }
                                            .frame(width: 62, height: 58)
                                            .background(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                                        }
                                        .buttonStyle(.plain)
                                        .help("/\(info.slug)")
                                        .accessibilityLabel(info.name)
                                    }
                                }
                            }
                        }
                    }
                }
                Text("Click to insert as a child of the selection. Icon packs install from file or URL.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(width: 290, height: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator))
        }
    }
}

extension Stride.Threat: Hashable {
    public func hash(into h: inout Hasher) { h.combine(id) }
}
