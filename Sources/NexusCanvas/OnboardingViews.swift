import AppKit
import SwiftUI

// MARK: Welcome (artboard 14)

public struct WelcomeView: View {
    var onTour: () -> Void
    var onSkip: () -> Void
    var onImport: () -> Void

    public init(onTour: @escaping () -> Void, onSkip: @escaping () -> Void, onImport: @escaping () -> Void) {
        self.onTour = onTour
        self.onSkip = onSkip
        self.onImport = onImport
    }

    public var body: some View {
        ZStack {
            Color(white: 0.07)
            SelfBuildingMap().opacity(0.35)
            VStack(spacing: 0) {
                AppMark(size: 84).padding(.bottom, 26)
                Text("WELCOME TO OPENNEXUS").font(.chrome(13, weight: .medium, design: .monospaced)).kerning(2)
                    .foregroundStyle(.white.opacity(0.6)).padding(.bottom, 10)
                Text("Think at the speed\nof your keyboard.").font(.chrome(44, weight: .heavy)).kerning(-1.3)
                    .multilineTextAlignment(.center).foregroundStyle(.white).padding(.bottom, 36)
                Button(action: onTour) {
                    HStack(spacing: 12) {
                        Text("Start the 4-minute tour").font(.chrome(17, weight: .medium))
                        Text("↩").font(.chrome(12, design: .monospaced)).padding(.horizontal, 6).frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.black.opacity(0.15)))
                    }
                    .foregroundStyle(Color(white: 0.1))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.95)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                HStack(spacing: 12) {
                    secondary("Skip to a blank map", onSkip)
                    secondary("Import from Xmind…", onImport)
                }
                .padding(.top, 12)
                HStack(spacing: 18) {
                    Text("Runs entirely on this Mac")
                    Text("·")
                    Text("Plain .nexus files")
                    Text("·")
                    Text("Open source")
                }
                .font(.chrome(13.5)).foregroundStyle(.white.opacity(0.55)).padding(.top, 30)
            }
            .padding(.horizontal, 48).padding(.vertical, 44)
            .frame(width: 640)
            .background(
                RoundedRectangle(cornerRadius: 30).fill(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.94))
            )
            .overlay(RoundedRectangle(cornerRadius: 30).stroke(Color.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.5), radius: 50, y: 20)
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }

    func secondary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.chrome(15)).foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.14)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A mind map that adds a topic every second (the welcome screen's background).
struct SelfBuildingMap: View {
    static let topics: [(String, CGPoint, Int?)] = [
        ("New product", CGPoint(x: 0.5, y: 0.5), nil), ("Research", CGPoint(x: 0.3, y: 0.3), 0),
        ("Interviews", CGPoint(x: 0.14, y: 0.22), 1),
        ("Competitors", CGPoint(x: 0.14, y: 0.36), 1), ("Design", CGPoint(x: 0.7, y: 0.28), 0),
        ("Prototype", CGPoint(x: 0.86, y: 0.2), 4),
        ("Motion", CGPoint(x: 0.86, y: 0.34), 4), ("Build", CGPoint(x: 0.72, y: 0.72), 0),
        ("Canvas engine", CGPoint(x: 0.88, y: 0.78), 7),
        ("Launch", CGPoint(x: 0.28, y: 0.72), 0), ("Beta", CGPoint(x: 0.12, y: 0.66), 9),
        ("Learn", CGPoint(x: 0.12, y: 0.8), 9),
    ]
    @State private var shown = 1

    var body: some View {
        GeometryReader { g in
            ZStack {
                ForEach(0..<shown, id: \.self) { i in
                    let t = Self.topics[i]
                    let p = CGPoint(x: t.1.x * g.size.width, y: t.1.y * g.size.height)
                    if let parent = t.2 {
                        let q = CGPoint(
                            x: Self.topics[parent].1.x * g.size.width, y: Self.topics[parent].1.y * g.size.height)
                        Path { path in
                            path.move(to: q)
                            path.addCurve(
                                to: p, control1: CGPoint(x: (q.x + p.x) / 2, y: q.y),
                                control2: CGPoint(x: (q.x + p.x) / 2, y: p.y))
                        }
                        .stroke(Color(hex: ["#7B6CF6", "#3DD6C6", "#F2A93B", "#EB5E8C"][i % 4]), lineWidth: 2)
                    }
                    Text(t.0).font(.chrome(i == 0 ? 22 : 15, weight: i == 0 ? .bold : .medium)).foregroundStyle(
                        .white
                    )
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(i == 0 ? Color.white.opacity(0.12) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(i == 0 ? 0 : 0.3)))
                    .position(p)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .task {
            // Reduce Motion: the map is simply there.
            if UIMotion.reduce {
                shown = Self.topics.count
                return
            }
            while shown < Self.topics.count {
                try? await Task.sleep(for: .seconds(1))
                withAnimation(UIMotion.animation(.spring(duration: 0.6))) { shown += 1 }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Role picker (artboard 15)

public struct RolePickerView: View {
    @State private var role: Role = .engineer
    var onContinue: (Role) -> Void
    var onSkip: (Role) -> Void

    public init(initial: Role = .engineer, onContinue: @escaping (Role) -> Void, onSkip: @escaping (Role) -> Void) {
        _role = State(initialValue: initial)
        self.onContinue = onContinue
        self.onSkip = onSkip
    }

    public var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            DotGrid().opacity(0.6)
            VStack(alignment: .leading, spacing: 0) {
                Text("STEP 2 OF 9 · PICK YOUR WORLD").font(.chrome(12.5, weight: .medium, design: .monospaced))
                    .kerning(2)
                    .foregroundStyle(.secondary).padding(.bottom, 10)
                Text("What will you map first?").font(.chrome(36, weight: .heavy)).kerning(-1).padding(
                    .bottom, 10)
                HStack {
                    Text(
                        "This sets the tour’s example and your template shelf. You can change it any time in Settings."
                    )
                    .font(.chrome(16)).foregroundStyle(.secondary)
                    Spacer()
                    HStack(spacing: 6) {
                        key("1")
                        Text("–")
                        key("4")
                        Text("or")
                        key("←")
                        key("→")
                        Text("then")
                        key("↩")
                    }
                    .font(.chrome(14)).foregroundStyle(.secondary)
                }
                .padding(.bottom, 28)
                HStack(alignment: .top, spacing: 18) {
                    ForEach(Array(Role.allCases.enumerated()), id: \.offset) { i, r in card(r, number: i + 1) }
                }
                HStack {
                    HStack(spacing: 6) {
                        ForEach(0..<9, id: \.self) { i in
                            Capsule().fill(i <= 1 ? Color(hex: "#5850EC") : Color.secondary.opacity(0.25)).frame(
                                width: i == 1 ? 22 : 7, height: 7)
                        }
                    }
                    Spacer()
                    Button("Skip tour") { onSkip(role) }.buttonStyle(FileButtonStyle()).controlSize(.large)
                    Button {
                        onContinue(role)
                    } label: {
                        Text("Continue as \(role.title.components(separatedBy: " · ").first ?? role.title)")
                            .font(.chrome(16, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 22).frame(height: 44)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.1)))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 34)
            }
            .padding(42)
            .frame(width: 1040)
            .background(
                RoundedRectangle(cornerRadius: 30).fill(Color(nsColor: .textBackgroundColor)).shadow(
                    color: .black.opacity(0.1), radius: 30, y: 10))
        }
        .background {
            ForEach(Array(Role.allCases.enumerated()), id: \.offset) { i, r in
                Button("") { role = r }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: []).opacity(0)
            }
            Button("") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: []).opacity(0)
            Button("") { step(1) }.keyboardShortcut(.rightArrow, modifiers: []).opacity(0)
        }
    }

    func step(_ d: Int) {
        let all = Role.allCases
        let i = all.firstIndex(of: role) ?? 0
        role = all[(i + d + all.count) % all.count]
    }

    func key(_ s: String) -> some View {
        Text(s).font(.chrome(13, weight: .medium, design: .monospaced)).padding(.horizontal, 7).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }

    func card(_ r: Role, number: Int) -> some View {
        let on = r == role
        let (icon, tint): (String, Color) =
            switch r {
            case .engineer: ("chevron.left.forwardslash.chevron.right", Color(hex: "#5850EC"))
            case .architect: ("building.columns", Color(hex: "#1E6FB8"))
            case .security: ("checkmark.shield", Color(hex: "#D93A3F"))
            case .planner: ("calendar", Color(hex: "#0F9F9A"))
            }
        return Button {
            role = r
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon).font(.chrome(17, weight: .semibold)).foregroundStyle(tint)
                        .frame(width: 42, height: 42).background(
                            RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.12)))
                    Spacer()
                    key("\(number)")
                }
                Text(r.title).font(.chrome(19, weight: .bold)).padding(.top, 6)
                Text(r.blurb).font(.chrome(13.5)).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true)
                Divider().padding(.vertical, 6)
                detail("Tour example", r.tourExample)
                detail("Lesson 5 converts to", r.conversionTitle)
                detail("Shelf", r.shelfSummary)
            }
            .padding(22)
            .frame(maxWidth: .infinity, minHeight: 340, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 18).stroke(
                    on ? Color(hex: "#5850EC") : Color.secondary.opacity(0.12), lineWidth: on ? 3 : 1)
            )
            .shadow(color: on ? Color(hex: "#5850EC").opacity(0.18) : .clear, radius: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(number). \(r.title). \(r.blurb)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    func detail(_ k: String, _ v: String) -> some View {
        (Text(k).fontWeight(.semibold) + Text(" · " + v).foregroundStyle(.secondary)).font(.chrome(12.5))
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct DotGrid: View {
    var body: some View {
        Canvas { ctx, s in
            let step: CGFloat = 22
            for y in stride(from: step, to: s.height, by: step) {
                for x in stride(from: step, to: s.width, by: step) {
                    ctx.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(.secondary.opacity(0.35))
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// "Your keys already work here" (artboard 31): shown beside the import report for .xmind.
public struct XmindSwitcherCard: View {
    var report: String
    public init(report: String) { self.report = report }
    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("XMIND SWITCHERS · ON .XMIND IMPORT").font(.chrome(12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text("Your keys already work here.").font(.chrome(19, weight: .bold))
            (Text("Same: ").bold() + Text("⇥ ↩ ⇧↩ ⌘↩, structures, markers, Pitch → Present")).font(.chrome(12.5))
            (Text("New: ").bold() + Text("⇧⌘L Connect mode, typed diagrams, ⌥⌘T convert")).font(.chrome(12.5))
            (Text("New: ").bold() + Text("AI that runs on this Mac, no credits")).font(.chrome(12.5))
            Text(report).font(.chrome(13.5)).foregroundStyle(.secondary)
        }
        .padding(22)
        .frame(width: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.separator))
        .shadow(color: .black.opacity(0.15), radius: 24, y: 10)
    }
}
