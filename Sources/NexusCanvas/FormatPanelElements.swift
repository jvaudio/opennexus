import AppKit
import NexusCore
import NexusTheme
import SwiftUI

/// FMT-2: the Style tab for relationships, boundaries, callouts, summaries and zones.
struct ElementStyleTab: View {
    var controller: CanvasController
    let ref: ElementRef

    var body: some View {
        switch ref {
        case .relationship(let id):
            if let r = controller.canvas.relationships.first(where: { $0.id == id }) {
                RelationshipSection(controller: controller, rel: r)
            }
        case .boundary(let id):
            if let b = controller.canvas.boundaries.first(where: { $0.id == id }) {
                BoundarySection(controller: controller, boundary: b)
            }
        case .summary(let id):
            if let s = controller.canvas.summaries.first(where: { $0.id == id }) {
                SummarySection(controller: controller, summary: s)
            }
        case .callout(let id):
            if let k = controller.canvas.callouts.first(where: { $0.id == id }) {
                CalloutSection(controller: controller, callout: k)
            }
        case .zone(let id):
            if let z = controller.canvas.zones.first(where: { $0.id == id }) {
                ZoneSection(controller: controller, zone: z)
            }
        }
        Divider()
        PanelSection(Loc.t("Actions"), key: "element.actions") {
            Button("Reset style") { controller.resetElementStyle(ref) }.buttonStyle(.plain)
            Button("Delete", role: .destructive) {
                controller.perform(Loc.t("Delete")) { $0.removeElement(ref) }
                controller.selectElement(nil)
            }
            .buttonStyle(.plain)
        }
    }
}

struct RelationshipSection: View {
    var controller: CanvasController
    let rel: Relationship

    func set(_ body: @escaping (inout Relationship) -> Void) { controller.updateRelationship(rel.id, body) }

    static let shapes: [(String, String)] = [
        ("curved", "M2 14 C 14 0, 26 0, 38 14"), ("straight", "M2 14 L 38 2"), ("elbow", "M2 14 H 20 V 2 H 38"),
        ("zigzag", "M2 14 L 10 4 L 18 12 L 26 4 L 38 8"),
    ]

    static let caps: [(String, String, Bool)] = [
        ("none", "M20 7 h0", false), ("arrow", "M18 3 L 26 7 L 18 11", false),
        ("filled-arrow", "M18 3 L 27 7 L 18 11 Z", true), ("triangle", "M19 2 L 28 7 L 19 12 Z", false),
        ("diamond", "M20 7 L 24 3 L 28 7 L 24 11 Z", false), ("filled-diamond", "M20 7 L 24 3 L 28 7 L 24 11 Z", true),
        ("dot", "M24 7 m-3 0 a3 3 0 1 0 6 0 a3 3 0 1 0 -6 0", true),
        ("open-dot", "M24 7 m-3 0 a3 3 0 1 0 6 0 a3 3 0 1 0 -6 0", false), ("bar", "M22 2 V 12", false),
        ("crows-foot", "M20 7 L 28 2 M20 7 L 28 12 M20 7 H 28", false), ("square", "M20 4 h6 v6 h-6 Z", true),
    ]

    static let kinds: [(String, String)] = [
        ("relationship", Loc.t("Relationship")), ("dataflow", Loc.t("Data flow")), ("call", Loc.t("Call")),
        ("return", Loc.t("Return message")),
        ("message", Loc.t("Message")), ("association", Loc.t("Association")), ("inheritance", Loc.t("Inheritance")),
    ]

    var body: some View {
        PanelSection(
            Loc.t("Relationship / edge"), key: "rel.shape",
            accessory: {
                Keycap(text: controller.bindings(for: .connect).first?.glyphs ?? "⇧⌘L")
            }
        ) {
            Text("LINE SHAPE").font(.chrome(11, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Self.shapes, id: \.0) { id, d in
                    Tile(selected: rel.line == id, height: 44) {
                        set { $0.line = id }
                    } content: {
                        VStack(spacing: 2) {
                            PathIcon(d: d).frame(height: 18)
                            Text(id.capitalized).font(.chrome(10))
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Relationship / edge")
            HStack {
                Text("START / END CAPS").font(.chrome(11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("11 each").font(.chrome(11)).foregroundStyle(.secondary)
                Button("⇄ swap") { set { $0.ends = $0.ends.reversed() } }.buttonStyle(.plain).font(.chrome(12))
            }
            capGrid(index: 0)
            capGrid(index: 1)
        }
        Divider()
        PanelSection(Loc.t("Stroke"), key: "rel.stroke") {
            HStack {
                Picker("", selection: Binding(get: { rel.dash }, set: { v in set { $0.dash = v } })) {
                    Text("Solid").tag("solid")
                    Text("- - Dashed").tag("dashed")
                    Text("· · Dotted").tag("dotted")
                }
                .labelsHidden()
                Picker("", selection: Binding(get: { rel.width }, set: { v in set { $0.width = v } })) {
                    ForEach([1, 1.5, 2, 3, 4] as [Double], id: \.self) { Text(CanvasPanelFormat.points($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 80)
                ColorPicker(
                    "",
                    selection: hexBinding(
                        RGBA(hexString: rel.color) != nil ? rel.color : nil, fallback: controller.theme.relationship
                    ) { hex in
                        set { $0.color = hex }
                    }
                )
                .labelsHidden()
                .accessibilityLabel("Custom colour")
                .frame(width: 34)
            }
            PanelToggle(label: Loc.t("Colour follows source topic"), isOn: rel.color == "source") { v in
                set { $0.color = v ? "source" : "theme" }
            }
            PanelToggle(label: Loc.t("Endpoints auto-slide to best edge"), isOn: rel.bend == nil) { v in
                if v { set { $0.bend = nil } }
            }
        }
        Divider()
        PanelSection(Loc.t("Label"), key: "rel.label") {
            PanelRow(label: Loc.t("Position")) {
                Segments(
                    options: [("start", Loc.t("Start")), ("middle", Loc.t("Middle")), ("end", Loc.t("End"))],
                    selection: rel.labelPosition
                ) { v in
                    set { $0.labelPosition = v }
                }
                .frame(maxWidth: 180)
            }
            PanelRow(label: Loc.t("Style")) {
                Segments(
                    options: [("pill", Loc.t("Pill")), ("plain", Loc.t("Plain")), ("boxed", Loc.t("Boxed"))],
                    selection: rel.labelStyle
                ) { v in
                    set { $0.labelStyle = v }
                }
                .frame(maxWidth: 180)
            }
            PanelRow(label: Loc.t("Technical type")) {
                Picker(
                    "",
                    selection: Binding(
                        get: { rel.kind ?? "relationship" },
                        set: { v in set { $0.kind = v == "relationship" ? nil : v } })
                ) {
                    ForEach(Self.kinds, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden()
                .frame(maxWidth: 160)
            }
        }
    }

    func capGrid(index: Int) -> some View {
        HStack(spacing: 4) {
            Text(index == 0 ? Loc.t("Start") : Loc.t("End")).font(.chrome(11)).foregroundStyle(.secondary).frame(
                width: 30, alignment: .leading)
            ForEach(Self.caps, id: \.0) { id, d, filled in
                Tile(selected: rel.ends[index] == id, height: 24) {
                    set { $0.ends[index] = id }
                } content: {
                    PathIcon(d: d, lineWidth: 1.4, filled: filled)
                }
                .help(id.replacingOccurrences(of: "-", with: " ").capitalized)
                .accessibilityLabel(index == 0 ? Loc.f("Start cap %@", id) : Loc.f("End cap %@", id))
            }
        }
    }
}

struct BoundarySection: View {
    var controller: CanvasController
    let boundary: Boundary

    func set(_ body: @escaping (inout Boundary) -> Void) { controller.updateBoundary(boundary.id, body) }

    static let shapes: [(String, String, String?)] = [
        ("rounded", "M6 2h34a4 4 0 0 1 4 4v12a4 4 0 0 1-4 4H6a4 4 0 0 1-4-4V6a4 4 0 0 1 4-4z", nil),
        ("rectangle", "M2 2h42v20H2z", nil), ("stadium", "M12 2h22a10 10 0 0 1 0 20H12a10 10 0 0 1 0-20z", nil),
        ("ellipse", "M23 2c12 0 21 4.5 21 10s-9 10-21 10S2 17.5 2 12 11 2 23 2z", nil),
        ("wave", "M2 4c7-3 14 3 21 0s14 3 21 0v16c-7 3-14-3-21 0s-14-3-21 0z", nil),
        (
            "scallop", "M4 6q3-5 7-1q4-4 8 0q4-4 8 0q4-4 8 0q4-4 7 1v12q-3 5-7 1q-4 4-8 0q-4 4-8 0q-4 4-8 0q-4 4-7-1z",
            nil
        ),
        ("polygon", "M8 2h30l6 10-6 10H8L2 12z", nil),
        ("dashed", "M6 2h34a4 4 0 0 1 4 4v12a4 4 0 0 1-4 4H6a4 4 0 0 1-4-4V6a4 4 0 0 1 4-4z", "dashed"),
        ("corners", "M2 8V2h6 M38 2h6v6 M44 16v6h-6 M8 22H2v-6", nil),
    ]

    var body: some View {
        PanelSection(
            Loc.t("Boundary"), key: "boundary.shape",
            accessory: {
                Keycap(text: controller.bindings(for: .boundary).first?.glyphs ?? "⇧⌘B")
            }
        ) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Self.shapes, id: \.0) { id, d, _ in
                    Tile(selected: boundary.shape == id, height: 40) {
                        set { $0.shape = id }
                    } content: {
                        VStack(spacing: 2) {
                            PathIcon(d: d).frame(height: 18)
                            Text(id.capitalized).font(.chrome(10))
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Boundary")
            PanelRow(label: Loc.t("Title")) {
                TextField("Title", text: Binding(get: { boundary.title }, set: { v in set { $0.title = v } }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 170)
            }
        }
        Divider()
        PanelSection(Loc.t("Meaning · technical canvases"), key: "boundary.meaning") {
            Segments(
                options: [
                    ("group", Loc.t("Group")), ("zone", Loc.t("Zone")), ("vpc", "VPC"), ("subnet", Loc.t("Subnet")),
                    ("trust", Loc.t("Trust")),
                ],
                selection: boundary.meaning
            ) { v in set { $0.meaning = v } }
            PanelRow(label: Loc.t("Trust level")) {
                Segments(
                    options: [("high", Loc.t("High")), ("medium", Loc.t("Medium")), ("low", Loc.t("Low"))],
                    selection: boundary.trust
                ) {
                    v in
                    set { $0.trust = v }
                }
                .frame(maxWidth: 180)
            }
        }
        Divider()
        PanelSection(Loc.t("Fill · border · title"), key: "boundary.fill") {
            PanelRow(label: Loc.t("Tint")) {
                Slider(
                    value: Binding(
                        get: { boundary.fillOpacity }, set: { v in set { $0.fillOpacity = (v * 100).rounded() / 100 } }),
                    in: 0...0.3
                )
                .frame(maxWidth: 140)
                .accessibilityLabel(Loc.t("Tint"))
                Text("\(Int(boundary.fillOpacity * 100))%").font(.chrome(12, design: .monospaced))
            }
            HStack {
                Picker(
                    "",
                    selection: Binding(
                        get: { boundary.dash ?? "auto" }, set: { v in set { $0.dash = v == "auto" ? nil : v } })
                ) {
                    Text("Auto").tag("auto")
                    Text("Solid").tag("solid")
                    Text("- - Dashed").tag("dashed")
                    Text("· · Dotted").tag("dotted")
                }
                .labelsHidden()
                Picker("", selection: Binding(get: { boundary.width }, set: { v in set { $0.width = v } })) {
                    ForEach([1, 1.5, 2, 3] as [Double], id: \.self) { Text(CanvasPanelFormat.points($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 80)
                ColorPicker(
                    "",
                    selection: hexBinding(boundary.color, fallback: controller.theme.ring) { hex in
                        set { $0.color = hex }
                    }
                )
                .labelsHidden()
                .accessibilityLabel("Custom colour")
                .frame(width: 34)
            }
            PanelToggle(label: Loc.t("Hatch pattern by trust level"), isOn: boundary.hatch) { v in set { $0.hatch = v }
            }
        }
    }
}

struct CalloutSection: View {
    var controller: CanvasController
    let callout: Callout

    func set(_ body: @escaping (inout Callout) -> Void) { controller.updateCallout(callout.id, body) }

    var body: some View {
        PanelSection(
            Loc.t("Callout"), key: "callout",
            accessory: {
                Keycap(text: controller.bindings(for: .callout).first?.glyphs ?? "⇧⌘C")
            }
        ) {
            PanelRow(label: Loc.t("Shape")) {
                Segments(
                    options: [
                        ("rounded", Loc.t("Rounded")), ("ellipse", Loc.t("Ellipse")), ("rectangle", Loc.t("Rectangle")),
                    ],
                    selection: callout.shape
                ) { v in
                    set { $0.shape = v }
                    controller.select(callout.topic)
                    controller.updateSelectionStyle(Loc.t("Callout Shape")) {
                        $0.shape = v == "rectangle" ? "rectangle" : v == "ellipse" ? "ellipse" : "rounded"
                    }
                }
                .frame(maxWidth: 200)
            }
            PanelRow(label: Loc.t("Pointer side")) {
                Segments(
                    options: [
                        ("auto", Loc.t("Auto")), ("top", Loc.t("Top")), ("right", Loc.t("Right")),
                        ("below", Loc.t("Below")),
                    ],
                    selection: callout.side
                ) { v in
                    set { $0.side = v }
                }
                .frame(maxWidth: 200)
            }
            Text("Fill and text style: select the bubble's text and use the topic controls.")
                .font(.chrome(11)).foregroundStyle(.secondary)
        }
    }
}

struct SummarySection: View {
    var controller: CanvasController
    let summary: Summary

    func set(_ body: @escaping (inout Summary) -> Void) { controller.updateSummary(summary.id, body) }

    static let brackets: [(String, String)] = [
        ("curly", "M14 2 Q 20 2 20 7 V 10 Q 20 12 24 12 Q 20 12 20 14 V 17 Q 20 22 14 22"),
        ("square", "M14 2 H 20 V 22 H 14 M20 12 H 25"), ("round", "M15 2 Q 27 12 15 22"),
        ("line", "M20 2 V 22 M20 12 H 25"),
    ]

    var body: some View {
        PanelSection(
            Loc.t("Summary"), key: "summary",
            accessory: {
                Keycap(text: controller.bindings(for: .summary).first?.glyphs ?? "⇧⌘]")
            }
        ) {
            Text("BRACKET").font(.chrome(11, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(Self.brackets, id: \.0) { id, d in
                    Tile(selected: summary.bracket == id, height: 40) {
                        set { $0.bracket = id }
                    } content: {
                        PathIcon(d: d, lineWidth: 1.6).frame(height: 24)
                    }
                    .help(id.capitalized)
                    .accessibilityLabel(Loc.f("%@ bracket", id))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Summary")
            HStack {
                Picker("", selection: Binding(get: { summary.width }, set: { v in set { $0.width = v } })) {
                    ForEach([1, 1.5, 2, 3] as [Double], id: \.self) { Text(CanvasPanelFormat.points($0)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 80)
                ColorPicker(
                    Loc.t("Ink"),
                    selection: hexBinding(summary.color, fallback: controller.theme.ink2) { hex in
                        set { $0.color = hex }
                    })
            }
            PanelRow(label: Loc.t("Range")) {
                Button("Extend ↓") { controller.extendSummary(summary.id, by: 1) }
                Button("Shrink ↑") { controller.extendSummary(summary.id, by: -1) }
            }
            Button("Edit summary topic") { controller.beginEditing(summary.topic) }
        }
    }
}

struct ZoneSection: View {
    var controller: CanvasController
    let zone: Zone

    func set(_ body: @escaping (inout Zone) -> Void) { controller.updateZone(zone.id, body) }

    var body: some View {
        PanelSection(
            Loc.t("Zone"), key: "zone",
            accessory: {
                Keycap(text: controller.bindings(for: .zone).first?.glyphs ?? "⌥⌘Z")
            }
        ) {
            PanelRow(label: Loc.t("Title")) {
                TextField("Title", text: Binding(get: { zone.title }, set: { v in set { $0.title = v } }))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 170)
            }
            HStack {
                Text("W")
                PointField(value: zone.width) { v in if let v { set { $0.width = max(Zone.minimumSize, v) } } }
                Text("H")
                PointField(value: zone.height) { v in if let v { set { $0.height = max(Zone.minimumSize, v) } } }
            }
            .font(.chrome(12))
            PanelToggle(label: Loc.t("Auto resize to content"), isOn: zone.autoResize) { v in set { $0.autoResize = v }
            }
            PanelToggle(label: Loc.t("Collapsed"), isOn: zone.collapsed) { v in set { $0.collapsed = v } }
            PanelRow(label: Loc.t("Frame")) {
                Segments(
                    options: [("rounded", Loc.t("Rounded")), ("square", Loc.t("Square")), ("dashed", Loc.t("Dashed"))],
                    selection: zone.frame
                ) { v in
                    set { $0.frame = v }
                }
                .frame(maxWidth: 200)
            }
            PanelRow(label: Loc.t("Order")) {
                Segments(
                    options: [
                        ("front", Loc.t("Front")), ("forward", Loc.t("Fwd")), ("backward", Loc.t("Back")),
                        ("back", Loc.t("Rear")),
                    ],
                    selection: nil
                ) { v in
                    let order: CanvasEditor.ZOrder =
                        v == "front" ? .front : v == "forward" ? .forward : v == "backward" ? .backward : .back
                    controller.perform(Loc.t("Arrange")) { $0.reorderZone(zone.id, order) }
                }
                .frame(maxWidth: 200)
            }
            HStack {
                Button("Export Zone…") { controller.exportZone(zone.id) }
                Button("Print Zone…") { controller.printZone(zone.id) }
            }
            Button("Remove zone (keep content)") {
                controller.perform(Loc.t("Remove Zone")) { $0.removeZone(zone.id) }
                controller.selectElement(nil)
            }
        }
    }
}
