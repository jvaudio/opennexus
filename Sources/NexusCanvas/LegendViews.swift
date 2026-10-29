#if os(macOS)
import AppKit
import NexusCore
import NexusKeys
import NexusScene
import NexusTheme
import SwiftUI

// MARK: Drawing

/// A progress marker's pie for SwiftUI, in the current foreground style (D247).
struct ProgressPie: Shape {
    var fraction: Double

    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let radius = min(r.width, r.height) / 2
        var p = Path(ellipseIn: CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
            .strokedPath(StrokeStyle(lineWidth: radius / 4))
        p.move(to: c)
        p.addArc(
            center: c, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction),
            clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: Editor

/// Edit Legend…: show or hide it, describe each marker, put it back beside the map.
struct LegendPopover: View {
    var controller: CanvasController
    var close: () -> Void
    @State private var drafts: [String: String] = [:]

    var markers: [String] { MarkerLibrary.order(controller.canvas.legendContents.markers) }
    var labels: [String] { controller.canvas.legendContents.labels }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Legend").font(.headline)
                Spacer()
                Button("Done") {
                    save()
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
            Toggle(
                "Show the legend on the canvas",
                isOn: Binding(
                    get: { controller.canvas.legend?.visible ?? false }, set: { controller.setLegendVisible($0) })
            )
            .toggleStyle(.checkbox)
            Text("MARKERS").font(.chrome(11, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if markers.isEmpty { Text("No markers on this canvas yet.").foregroundStyle(.secondary) }
                    ForEach(markers, id: \.self) { m in
                        HStack(spacing: 8) {
                            MarkerDisc(id: m).frame(width: 18, height: 18).accessibilityHidden(true)
                            TextField(
                                MarkerLibrary.name(m),
                                text: Binding(get: { drafts[m] ?? "" }, set: { drafts[m] = $0 })
                            )
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(save)
                            .accessibilityLabel(Loc.f("Description for %@", MarkerLibrary.name(m)))
                        }
                    }
                }
            }
            .accessibilityLabel(Loc.t("Marker descriptions"))
            if !labels.isEmpty {
                Text("LABELS").font(.chrome(11, weight: .semibold)).foregroundStyle(.secondary)
                Text(labels.joined(separator: " · ")).font(.chrome(12.5)).lineLimit(3)
            }
            HStack {
                Text("An empty description shows the marker's own name. Drag the legend to move it.")
                    .font(.chrome(11)).foregroundStyle(.secondary)
                Spacer()
                if controller.canvas.legend?.position != nil {
                    Button("Reset Position") { controller.moveLegend(to: nil) }
                }
            }
        }
        .padding(14)
        .onAppear { drafts = controller.canvas.legend?.markers ?? [:] }
        .onDisappear(perform: save)
    }

    func save() {
        for m in markers where (drafts[m] ?? "") != (controller.canvas.legend?.markers[m] ?? "") {
            controller.setLegendDescription(drafts[m] ?? "", for: m)
        }
    }
}

/// A marker drawn as on topics, for SwiftUI.
struct MarkerDisc: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> NSView { DiscView(id: id) }
    func updateNSView(_ v: NSView, context: Context) {}

    final class DiscView: NSView {
        let id: String
        init(id: String) {
            self.id = id
            super.init(frame: CGRect(x: 0, y: 0, width: 18, height: 18))
        }
        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            if let ctx = NSGraphicsContext.current?.cgContext { LegendLayer.drawMarker(id, in: bounds, context: ctx) }
        }
    }
}
#endif
