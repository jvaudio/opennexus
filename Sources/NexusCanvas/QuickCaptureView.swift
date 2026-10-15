import AppKit
import NexusFormat
import SwiftUI

/// Quick Capture (✦N from any app, artboard 33): one field on a glass panel. ↩ saves,
/// ⇥ / ⇧⇥ choose the map, ⌥↩ adds a line, Esc closes.
@MainActor
@Observable
public final class QuickCaptureModel {
    public var text = ""
    public var targets: CaptureTargets
    /// Shown briefly after saving ("Saved to Inbox map").
    public var saved: String?
    @ObservationIgnored public var onSave: (String, CaptureTargets.Target) -> Void = { _, _ in }
    @ObservationIgnored public var onClose: () -> Void = {}

    public init(targets: CaptureTargets) { self.targets = targets }

    public func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return onClose() }
        onSave(t, targets.current)
        saved = "Saved to \(targets.current.title)"
        text = ""
    }
}

public struct QuickCaptureView: View {
    @Bindable var model: QuickCaptureModel
    @FocusState private var focused: Bool

    public init(model: QuickCaptureModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                AppMarkGlyph().frame(width: 18, height: 18).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                TextField("Jot an idea", text: $model.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.chrome(21, weight: .regular))
                    .lineLimit(1...6)
                    .focused($focused)
                    .onSubmit { model.save() }
                    .onKeyPress(.tab, phases: .down) { press in
                        if press.modifiers.contains(.shift) { model.targets.previous() } else { model.targets.next() }
                        return .handled
                    }
                    .onExitCommand { model.onClose() }
                    .accessibilityLabel("Quick Capture")
            }
            HStack(spacing: 6) {
                Text("→").foregroundStyle(.secondary)
                Text(model.saved ?? targetLine)
                    .foregroundStyle(model.saved == nil ? Color.primary.opacity(0.75) : Color.green)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text("↩ save · ⇥ choose map").foregroundStyle(.secondary)
            }
            .font(.chrome(13))
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .frame(width: 560, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onAppear { focused = true }
        .onChange(of: model.text) { if !model.text.isEmpty { model.saved = nil } }
    }

    /// "Inbox map · Product ideas": the target, then the next one ⇥ would pick.
    var targetLine: String {
        var t = model.targets
        let current = t.current.title
        t.next()
        return t.targets.count > 1 ? "\(current) · \(t.current.title)" : current
    }
}

/// The OpenNexus triangle in the accent colours, small enough for a text line.
struct AppMarkGlyph: View {
    var body: some View {
        Canvas { ctx, s in
            let a = CGPoint(x: s.width * 0.5, y: s.height * 0.12)
            let b = CGPoint(x: s.width * 0.12, y: s.height * 0.88)
            let c = CGPoint(x: s.width * 0.88, y: s.height * 0.88)
            var p = Path()
            p.move(to: a)
            p.addLine(to: b)
            p.addLine(to: c)
            p.closeSubpath()
            ctx.stroke(
                p,
                with: .linearGradient(
                    Gradient(colors: [Color(hex: "#5850EC"), Color(hex: "#0F7F7A")]), startPoint: b, endPoint: c),
                lineWidth: s.width * 0.11)
            let r = s.width * 0.13
            ctx.fill(
                Path(ellipseIn: CGRect(x: a.x - r, y: a.y - r, width: r * 2, height: r * 2)), with: .color(.primary))
        }
        .accessibilityHidden(true)
    }
}
