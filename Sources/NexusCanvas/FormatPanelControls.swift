import AppKit
import NexusCore
import NexusTheme
import SwiftUI

// Shared building blocks for the Format panel (FMT-1…3).

extension RGBA {
    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(
            r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent),
            a: Double(ns.alphaComponent))
    }
}

/// A collapsible section that remembers whether it is open.
struct PanelSection<Content: View, Accessory: View>: View {
    let title: String
    let key: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content
    @AppStorage private var open: Bool

    init(
        _ title: String, key: String, @ViewBuilder accessory: @escaping () -> Accessory,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.key = key
        self.accessory = accessory
        self.content = content
        _open = AppStorage(wrappedValue: true, "format.section.\(key)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    withAnimation(UIMotion.animation(.snappy(duration: 0.2))) { open.toggle() }
                } label: {
                    Text(title.uppercased())
                        .font(.chrome(11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(open ? "expanded" : "collapsed")")
                accessory()
            }
            if open { content() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

extension PanelSection where Accessory == EmptyView {
    init(_ title: String, key: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title, key: key, accessory: { EmptyView() }, content: content)
    }
}

/// A row of mutually exclusive options (FMT segmented controls).
struct Segments<T: Hashable>: View {
    let options: [(T, String)]
    let selection: T?
    let pick: (T) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                let on = o.0 == selection
                Button {
                    pick(o.0)
                } label: {
                    Text(o.1)
                        .font(.chrome(12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.accentColor : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background(on ? Color.accentColor.opacity(0.12) : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
                if i < options.count - 1 { Divider().frame(height: 18) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

/// A labelled row with a trailing control.
struct PanelRow<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        // One line when it fits, label above the control when the panel is narrow.
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(label).font(.chrome(13)).fixedSize()
                Spacer(minLength: 8)
                trailing()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.chrome(13))
                trailing()
            }
        }
    }
}

struct PanelToggle: View {
    let label: String
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) { Text(label).font(.chrome(13)) }
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}

/// A colour swatch button.
struct Swatch: View {
    let color: RGBA
    var selected = false
    var size: CGFloat = 22
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color.color)
                .frame(width: size, height: size)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .overlay(
                    RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.primary : .clear, lineWidth: 2)
                        .padding(-3))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Loc.f("Colour %@", color.hex))
    }
}

/// A shape or line icon from 24×16 path data.
struct PathIcon: View {
    let d: String
    var lineWidth: CGFloat = 1.5
    var filled = false

    var body: some View {
        Canvas { ctx, size in
            guard let p = SVGPath.parse(d) else { return }
            let b = p.boundingBoxOfPath
            let s = min((size.width - 4) / max(b.width, 1), (size.height - 4) / max(b.height, 1))
            var t = CGAffineTransform(translationX: size.width / 2, y: size.height / 2).scaledBy(x: s, y: s)
                .translatedBy(x: -b.midX, y: -b.midY)
            guard let scaled = p.copy(using: &t) else { return }
            let path = Path(scaled)
            if filled { ctx.fill(path, with: .foreground) }
            ctx.stroke(path, with: .foreground, lineWidth: lineWidth)
        }
    }
}

/// A grid tile used for shapes, skeletons, node styles and branch lines.
struct Tile<Content: View>: View {
    let selected: Bool
    var height: CGFloat = 40
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(selected ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            selected ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Binds a hex colour to SwiftUI's colour picker.
func hexBinding(_ hex: String?, fallback: RGBA, set: @escaping (String) -> Void) -> Binding<Color> {
    Binding(
        get: { (hex.flatMap(RGBA.init(hexString:)) ?? fallback).color },
        set: { set(RGBA(color: $0).hex) })
}

/// A small numeric field with a unit (pt).
struct PointField: View {
    let value: Double?
    var placeholder = Loc.t("Auto")
    let set: (Double?) -> Void
    @State private var text = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .frame(width: 70)
            .multilineTextAlignment(.trailing)
            .onAppear { text = value.map { CanvasPanelFormat.points($0) } ?? "" }
            .onChange(of: value) { _, v in text = v.map { CanvasPanelFormat.points($0) } ?? "" }
            .onSubmit {
                let digits = text.filter { $0.isNumber || $0 == "." }
                set(digits.isEmpty ? nil : Double(digits))
            }
    }
}

enum CanvasPanelFormat {
    static func points(_ v: Double) -> String {
        v == v.rounded() ? Loc.f("%lld pt", Int(v)) : Loc.f("%.1f pt", v)
    }
}
