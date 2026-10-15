import NexusCore
import NexusKeys
import NexusTheme
import SwiftUI

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

/// A keycap: monospaced glyphs in a small rounded key.
struct Keycap: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.chrome(11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(.background.opacity(0.9), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
            .fixedSize()
    }
}

/// Bottom-left: the always-visible state pill and the context hints beside it (P0).
public struct CanvasStatusBar: View {
    var controller: CanvasController

    public init(controller: CanvasController) { self.controller = controller }

    public var body: some View {
        // Slides right of the navigation panel when it's open.
        if !controller.zen && controller.present == nil { bar.padding(.leading, controller.navTab != nil ? 320 : 0) }
    }

    var bar: some View {
        HStack(spacing: 12) {
            StatePill(mode: controller.mode, theme: controller.theme)
            HStack(spacing: 14) {
                ForEach(hints, id: \.label) { h in
                    HStack(spacing: 6) {
                        Keycap(text: h.key)
                        Text(h.label).font(.chrome(13)).foregroundStyle(.secondary).fixedSize()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
        }
        .animation(UIMotion.animation(.snappy(duration: 0.18)), value: controller.mode)
    }

    struct Hint {
        var key: String
        var label: String
    }

    private func key(_ id: CommandID) -> String {
        controller.bindings(for: id).first?.glyphs ?? ""
    }

    var hints: [Hint] {
        switch controller.mode {
        case .edit:
            [
                Hint(key: key(.commitEdit), label: "commit"),
                Hint(key: key(.commitAndAddChild), label: "commit + child"),
                Hint(key: key(.lineBreak), label: "line break"),
            ]
        case .connect:
            [
                Hint(key: "A S D", label: "pick target"), Hint(key: "abc", label: "filter by text"),
                Hint(key: "↑↓", label: "move"), Hint(key: "↩", label: "connect"), Hint(key: "esc", label: "cancel"),
            ]
        case .select:
            [
                Hint(key: key(.addChild), label: "child"), Hint(key: key(.addSiblingAfter), label: "sibling"),
                Hint(key: key(.editKeepText), label: "edit"), Hint(key: key(.connect), label: "connect"),
                Hint(key: key(.convert), label: "convert"), Hint(key: key(.aiGhosts), label: "AI ideas"),
                Hint(key: key(.undo), label: "undo"), Hint(key: "hold ⌘", label: "all keys"),
            ]
        }
    }
}

/// SELECT / EDIT / CONNECT: shape + colour + word (artboard 02).
public struct StatePill: View {
    var mode: CanvasMode
    var theme: Theme

    public var body: some View {
        let (bg, fg): (Color, Color) =
            switch mode {
            case .select: theme.isDark ? (Color(white: 0.95), Color(white: 0.07)) : (RGBA(hex: "#17171C").color, .white)
            case .edit: (Tokens.Signal.irisLight.color, .white)
            case .connect: (theme.amber.color, RGBA(hex: "#17171C").color)
            }
        HStack(spacing: 8) {
            glyph(fg)
            Text(mode.rawValue.uppercased())
                .font(.chrome(13, weight: .semibold, design: .monospaced))
                .tracking(1.2)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(bg, in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Loc.f("%@ mode", mode.rawValue.capitalized))
        .accessibilityAddTraits(.isStaticText)
        .accessibilityIdentifier("state-pill")
    }

    @ViewBuilder func glyph(_ c: Color) -> some View {
        switch mode {
        case .select: RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8)
        case .edit: Rectangle().fill(c).frame(width: 2, height: 12)
        case .connect: Rectangle().fill(c).frame(width: 14, height: 2)
        }
    }
}

/// A quiet glass toast, top centre.
public struct ToastView: View {
    var controller: CanvasController

    public init(controller: CanvasController) { self.controller = controller }

    public var body: some View {
        VStack {
            if let t = controller.toast {
                Text(t.text)
                    .font(.chrome(13))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(t.serial)
                    .accessibilityIdentifier("toast")
            }
        }
        .animation(UIMotion.animation(.snappy(duration: 0.25)), value: controller.toast)
        .allowsHitTesting(false)
    }
}

/// Hold ⌘ for one second: every key for the current selection, from the registry.
public struct CheatSheetView: View {
    var controller: CanvasController

    public init(controller: CanvasController) { self.controller = controller }

    static let groups: [(String, [CommandID])] = [
        ("CREATE", [.addChild, .addSiblingAfter, .addSiblingBefore, .addParent, .addFloating, .duplicate]),
        ("MOVE & SELECT", [.selectRight, .extendRight, .selectRoot, .selectSiblings, .moveUp, .promote, .demote]),
        (
            "EDIT & STRUCTURE",
            [
                .editKeepText, .fold, .foldAll, .delete, .deleteKeepChildren, .priority(1), .toggleTodo,
                .structure(2),
            ]
        ),
        ("CONNECT · CONVERT · AI", [.connect, .convert, .aiGhosts, .aiAccept, .cycleNodeStyle, .smartColor, .undo]),
    ]

    public var body: some View {
        if controller.cheatSheetVisible {
            HStack(alignment: .top, spacing: 28) {
                ForEach(Self.groups, id: \.0) { title, ids in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Loc.t(title))
                            .font(.chrome(11, weight: .semibold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(.secondary)
                        ForEach(ids, id: \.self) { id in
                            if let c = controller.registry[id] {
                                HStack {
                                    Text(Loc.t(c.title)).font(.chrome(13))
                                    Spacer(minLength: 16)
                                    Keycap(text: controller.bindings(for: id).first?.glyphs ?? "—")
                                }
                            }
                        }
                    }
                    .frame(width: 220)
                }
            }
            .padding(24)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 20))
            .transition(.opacity)
            .accessibilityIdentifier("cheat-sheet")
        }
    }
}

/// The Connect mode search field (F2 step 2–3).
struct ConnectFieldView: View {
    let state: ConnectState
    let texts: [NodeID: String]
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Connect to").foregroundStyle(.secondary)
                Text(state.query).fontWeight(.semibold)
                Rectangle().fill(Color.primary).frame(width: 1.5, height: 15)
                Spacer(minLength: 0)
            }
            .font(.chrome(13))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            if state.offersCreate {
                row(hint: "↩", text: "Create new node “\(state.query)”", on: true)
            } else {
                ForEach(Array(state.matches.prefix(5).enumerated()), id: \.offset) { i, m in
                    row(hint: m.hint, text: texts[m.node] ?? "", on: i == state.highlighted)
                }
            }
        }
        .frame(minWidth: 260, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.amber.color, lineWidth: 1.5))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
        .accessibilityIdentifier("connect-field")
    }

    var accessibility: String {
        if state.offersCreate { return "Connect to new node \(state.query)" }
        let names = state.matches.prefix(5).map { "\($0.hint), \(texts[$0.node] ?? "")" }
        return "Connect to. \(names.joined(separator: "; "))"
    }

    func row(hint: String, text: String, on: Bool) -> some View {
        HStack(spacing: 10) {
            Text(hint)
                .font(.chrome(11, weight: .bold, design: .monospaced))
                .foregroundStyle(RGBA(hex: "#17171C").color)
                .frame(minWidth: 20, minHeight: 20)
                .background(theme.amber.color, in: RoundedRectangle(cornerRadius: 5))
            Text(text).font(.chrome(13)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(on ? theme.amberSoft.color : .clear)
    }
}
