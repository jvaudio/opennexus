import Foundation
import NexusCore
import NexusScene
import NexusTheme
import SwiftUI

// MARK: - Data tab (artboard 24)

/// One row of the Data tab's LINKS: where a link goes and what kind of link it is.
struct DataLink {
    enum Kind {
        case web, file, topic
        /// Another topic's topic link that points here (a backlink).
        case linkedFrom(CanvasID, NodeID)
    }

    var kind: Kind
    var title: String

    var glyph: String {
        switch kind {
        case .web, .file: "↗"
        case .topic, .linkedFrom: "⤳"
        }
    }

    var kindName: String {
        switch kind {
        case .web: Loc.t("web link")
        case .file: Loc.t("file")
        case .topic: Loc.t("topic link")
        case .linkedFrom: Loc.t("linked from")
        }
    }
}

/// The Data tab: the topic's type, task and fields, then what it links to, what's attached
/// and where it came from (artboard 24). A section with nothing to show is left out.
struct DataTab: View {
    var controller: CanvasController
    /// The metadata row under the pointer, which shows its remove button.
    @State private var hoveredField: Int?

    var id: NodeID { controller.selection.primary }
    var node: Node? { controller.canvas.nodes[id] }

    /// The selected topic's semantic type, from the canvas's palette (M41): what guides,
    /// rule checks and STRIDE read. Automatic shows what inference makes of it.
    @ViewBuilder var typeSection: some View {
        let c = controller.canvas
        let palette = DiagramCatalog.nodeTypes(for: c.type)
        if !palette.isEmpty, let node {
            PanelSection(Loc.t("Type"), key: "nodeType") {
                let inferred = node.nodeType == nil ? DiagramCatalog.effectiveType(id, in: c) : nil
                let auto = inferred.flatMap { t in palette.first { $0.id == t } }.map {
                    Loc.f("Automatic · %@", Loc.t($0.name))
                }
                Picker(
                    "Type",
                    selection: Binding(
                        get: { node.nodeType?.rawValue ?? "" },
                        set: { controller.setNodeType($0.isEmpty ? nil : NodeType(rawValue: $0)) })
                ) {
                    Text(auto ?? Loc.t("Automatic")).tag("")
                    ForEach(palette, id: \.id) { Text(Loc.t($0.name)).tag($0.id.rawValue) }
                    if let t = node.nodeType, !palette.contains(where: { $0.id == t }) {
                        Text(t.rawValue).tag(t.rawValue)
                    }
                }
                .labelsHidden()
                .accessibilityLabel("Node type")
            }
            Divider()
        }
    }

    var fields: [MetadataField] { node?.metadata ?? [] }

    func update(_ body: @escaping (inout [MetadataField]) -> Void) {
        let id = id
        controller.perform(Loc.t("Edit Fields")) { e in e.update(id) { body(&$0.metadata) } }
    }

    var body: some View {
        typeSection
        PanelSection(Loc.t("Task"), key: "task") {
            let c = controller.canvas
            if let line = TaskFormat.line(c, id, today: controller.todayDate) {
                Text(line).font(.chrome(12.5)).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No dates, owner or progress yet.").font(.chrome(12)).foregroundStyle(.chromeSecondary)
            }
            let after = node?.todo?.after.compactMap { c.nodes[$0.task]?.text } ?? []
            if !after.isEmpty {
                Text(Loc.f("After %@", after.joined(separator: ", "))).font(.chrome(12)).foregroundStyle(
                    .chromeSecondary)
            }
            Button("Edit Task…  ⌃⌘T") { controller.openTaskEditor() }.buttonStyle(.bordered)
        }
        Divider()
        metadata
        let links = Self.links(of: id, in: controller)
        if !links.isEmpty {
            Divider()
            linksSection(links)
        }
        if let node, !node.attachments.isEmpty {
            Divider()
            attachments(node.attachments)
        }
        if node?.ai == true {
            Divider()
            provenance
        }
    }

    // MARK: Metadata

    /// Key in the interface font, value in mono, and a dot that pins the field to the topic:
    /// filled Iris when pinned, hollow when not (artboard 24). Remove is on hover, on the
    /// dot's context menu and in each field's accessibility actions.
    var metadata: some View {
        PanelSection(Loc.t("Metadata · pin to show on node"), key: "metadata") {
            ForEach(Array(fields.enumerated()), id: \.offset) { i, f in
                HStack(spacing: 6) {
                    TextField("key", text: Binding(get: { f.key }, set: { v in update { $0[i].key = v } }))
                        .textFieldStyle(.roundedBorder)
                        .font(.chrome(12))
                        .foregroundStyle(.chromeSecondary)
                        .frame(width: 96)
                        .accessibilityAction(named: Loc.t("Remove field")) { update { $0.remove(at: i) } }
                    TextField("value", text: Binding(get: { f.value }, set: { v in update { $0[i].value = v } }))
                        .textFieldStyle(.roundedBorder)
                        .font(.chrome(12, design: .monospaced))
                        .overlay(alignment: .trailing) {
                            if hoveredField == i {
                                Button {
                                    update { $0.remove(at: i) }
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.chromeSecondary)
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 5)
                                .help(Loc.t("Remove field"))
                                .accessibilityLabel(Loc.t("Remove field"))
                            }
                        }
                        .accessibilityAction(named: Loc.t("Remove field")) { update { $0.remove(at: i) } }
                    pinDot(f, at: i)
                }
                .onHover { inside in
                    if inside {
                        hoveredField = i
                    } else if hoveredField == i {
                        hoveredField = nil
                    }
                }
            }
            Button("+ Add field") { update { $0.append(MetadataField(key: "owner", value: "")) } }
                .buttonStyle(.plain)
                .font(.chrome(12))
                .foregroundStyle(Color.accentColor)
        }
    }

    func pinDot(_ f: MetadataField, at i: Int) -> some View {
        Button {
            update { $0[i].pinned.toggle() }
        } label: {
            Group {
                if f.pinned {
                    Circle().fill(Color.accentColor)
                } else {
                    Circle().strokeBorder(.chromeTertiary, lineWidth: 1.2)
                }
            }
            .frame(width: 9, height: 9)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(f.pinned ? Loc.t("Unpin") : Loc.t("Pin"))
        .accessibilityLabel(f.pinned ? Loc.t("Unpin") : Loc.t("Pin"))
        .accessibilityAction(named: Loc.t("Remove field")) { update { $0.remove(at: i) } }
        .contextMenu {
            Button(f.pinned ? Loc.t("Unpin") : Loc.t("Pin")) { update { $0[i].pinned.toggle() } }
            Button(Loc.t("Remove field"), role: .destructive) { update { $0.remove(at: i) } }
        }
    }

    // MARK: Links

    /// The topic's own link (web, file or topic link), then the topic links that point at it.
    static func links(of id: NodeID, in controller: CanvasController) -> [DataLink] {
        var out: [DataLink] = []
        if let link = controller.canvas.nodes[id]?.link {
            if let t = TopicLink.parse(link) {
                out.append(DataLink(kind: .topic, title: topicTitle(t.canvas, t.node, in: controller)))
            } else if link.hasPrefix("file:") {
                let name = URL(string: link)?.lastPathComponent ?? ""
                out.append(DataLink(kind: .file, title: name.isEmpty ? link : name))
            } else {
                out.append(DataLink(kind: .web, title: webTitle(link)))
            }
        }
        for b in controller.backlinks(to: id) {
            out.append(
                DataLink(kind: .linkedFrom(b.canvas, b.node), title: topicTitle(b.canvas, b.node, in: controller)))
        }
        return out
    }

    /// "Canvas › Topic" for a topic on another canvas, the topic's title on this one.
    static func topicTitle(_ canvas: CanvasID, _ node: NodeID, in controller: CanvasController) -> String {
        guard let c = controller.store.model.canvases[canvas], let n = c.nodes[node] else {
            return Loc.t("That topic no longer exists")
        }
        return canvas == controller.canvasID ? n.text : "\(c.title) › \(n.text)"
    }

    /// A web link without its scheme or trailing slash: what the reader recognises.
    static func webTitle(_ link: String) -> String {
        var s = link
        for scheme in ["https://", "http://", "mailto:"] where s.hasPrefix(scheme) { s.removeFirst(scheme.count) }
        if s.hasSuffix("/") { s.removeLast() }
        return s.isEmpty ? link : s
    }

    func follow(_ link: DataLink) {
        switch link.kind {
        case .web, .file, .topic:
            controller.followLink(of: id)
        case .linkedFrom(let canvas, let node):
            // As following a topic link does, so ⌘[ flies back here.
            controller.linkHistory.append((controller.canvasID, id))
            if canvas != controller.canvasID { controller.switchCanvas(to: canvas) }
            controller.select(node)
        }
    }

    func linksSection(_ links: [DataLink]) -> some View {
        PanelSection(Loc.t("Links"), key: "links") {
            ForEach(Array(links.enumerated()), id: \.offset) { _, link in
                Button {
                    follow(link)
                } label: {
                    dataRow(Text(verbatim: "\(link.glyph) \(link.title)"), trailing: link.kindName)
                }
                .buttonStyle(.plain)
                .help(Loc.t("Open"))
                .accessibilityLabel("\(link.title), \(link.kindName)")
            }
        }
    }

    // MARK: Attachments

    /// Each attached file, with its size; clicking one shows it in Quick Look (artboard 24).
    func attachments(_ refs: [AssetRef]) -> some View {
        PanelSection(Loc.t("Attachments"), key: "attachments") {
            ForEach(Array(refs.enumerated()), id: \.offset) { i, a in
                let name = a.name ?? a.asset
                let size = controller.store.model.assets[a.asset].map {
                    ByteCountFormatter.string(fromByteCount: Int64($0.count), countStyle: .file)
                }
                Button {
                    controller.onRequest?(.attachment(id, i))
                } label: {
                    dataRow(
                        Text(name), trailing: [size, Loc.t("Quick Look")].compactMap { $0 }.joined(separator: " · "))
                }
                .buttonStyle(.plain)
                .help(Loc.t("Quick Look"))
                .accessibilityLabel(size.map { "\(name), \($0)" } ?? name)
            }
        }
    }

    func dataRow(_ title: Text, trailing: String) -> some View {
        HStack(spacing: 8) {
            title.font(.chrome(12.5)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(trailing).font(.chrome(11.5)).foregroundStyle(.chromeSecondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }

    // MARK: Provenance

    /// Shown while the topic is still as AI made it. The file records only that AI made it
    /// (`Node.ai`), not which model or command, so the card says no more than that.
    var provenance: some View {
        PanelSection(Loc.t("Provenance"), key: "provenance") {
            HStack(alignment: .top, spacing: 8) {
                Text(verbatim: "✦").font(.chrome(12)).foregroundStyle(Color.statusTeal).accessibilityHidden(true)
                Text("Created by AI. Editing the title clears the sparkle.")
                    .font(.chrome(12))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.statusTeal.opacity(0.07)))
            .accessibilityElement(children: .combine)
        }
    }
}
