import AppKit
import NexusKeys
import SwiftUI

// MARK: Keycap coach (artboard 31)

/// A 3D keycap: prompt, pressed, success (green tick), wrong key (amber) and chords.
struct CoachKey: View {
    enum State { case prompt, pressed, success, wrong }
    let label: String
    var state: State = .prompt
    var large = false

    var body: some View {
        let fill: Color =
            switch state {
            case .success: Color(hex: "#CFEFE0")
            case .wrong: Color(hex: "#FCE7B6")
            default: Color(nsColor: .textBackgroundColor)
            }
        let edge: Color =
            switch state {
            case .success: Color(hex: "#5BB98C")
            case .wrong: Color(hex: "#D9A63A")
            default: Color(hex: "#C9C9D2")
            }
        HStack(spacing: 6) {
            Text(label).font(.chrome(large ? 22 : 17, weight: .semibold, design: .rounded))
            if state == .success { Text("✓").font(.chrome(large ? 20 : 16, weight: .bold)) }
        }
        .foregroundStyle(Color(hex: "#25252B"))
        .padding(.horizontal, large ? 18 : 14)
        .frame(minWidth: large ? 64 : 52, minHeight: large ? 64 : 50)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(edge).offset(y: state == .pressed ? 1 : 5)
                RoundedRectangle(cornerRadius: 12).fill(fill).offset(y: state == .pressed ? 1 : 0)
            }
        )
        .shadow(color: .black.opacity(0.12), radius: 6, y: 4)
        .accessibilityLabel(label)
    }
}

/// The coach that floats beside the selection, with the lesson's prompt.
struct TourCoachView: View {
    var controller: CanvasController

    var body: some View {
        if let t = controller.tour, !t.paused, !t.finished, let s = t.current {
            let large = controller.prefs.string("accessibility.coachSize") == "large"
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    ForEach(Array(s.keys.enumerated()), id: \.offset) { _, k in
                        CoachKey(
                            label: k,
                            state: {
                                switch t.coach {
                                case .success: return .success
                                case .wrong: return .wrong
                                case .prompt: return .prompt
                                }
                            }(), large: large)
                    }
                }
                if case .wrong(let what) = t.coach {
                    Text(what).font(.chrome(12.5, weight: .medium)).foregroundStyle(Color(hex: "#8A5A00"))
                }
                Text(s.prompt).font(.chrome(large ? 15 : 13)).foregroundStyle(.secondary)
            }
            .padding(10)
            .animation(UIMotion.animation(.snappy(duration: 0.2)), value: t.coach)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tour: \(s.prompt)")
        }
    }
}

// MARK: Bar, pause pill and finish card

struct TourOverlay: View {
    enum Part { case bar, pill, finish }
    var controller: CanvasController
    var part: Part

    var body: some View {
        if let t = controller.tour {
            switch part {
            case .finish: if t.finished { finish(t) }
            case .pill: if t.paused && !t.finished { pill(t) }
            case .bar: if !t.paused && !t.finished { bar(t) }
            }
        }
    }

    func bar(_ t: TourController) -> some View {
        HStack(spacing: 14) {
            Text("\(t.lesson + 1) · \(t.lessons[t.lesson].title)").font(.chrome(13.5, weight: .semibold))
            dots(t)
            Button("Skip lesson") { t.skipLesson() }.buttonStyle(.link)
            Button("Pause") { t.pause() }.buttonStyle(.link)
        }
        .padding(.horizontal, 16).frame(height: 40)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().stroke(.separator))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tutorial")
    }

    func dots(_ t: TourController) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<t.lessons.count, id: \.self) { i in
                Capsule().fill(i <= t.lesson ? Color(hex: "#5850EC") : Color.secondary.opacity(0.25))
                    .frame(width: i == t.lesson ? 22 : 7, height: 7)
            }
        }
        // Shapes make no accessibility element of their own: this one is explicit.
        .accessibilityElement()
        .accessibilityLabel("Lesson \(t.lesson + 1) of \(t.lessons.count)")
        .accessibilityAddTraits(.updatesFrequently)
    }

    func pill(_ t: TourController) -> some View {
        HStack(spacing: 10) {
            Circle().fill(Color(hex: "#5850EC")).frame(width: 8, height: 8)
            Text("Tour paused · lesson \(t.lesson + 1) of \(t.lessons.count)").font(.chrome(14))
            Button("Resume") { t.resume() }.buttonStyle(.link).font(.chrome(14, weight: .semibold))
        }
        .padding(.horizontal, 16).frame(height: 40)
        .background(
            Capsule().fill(Color(nsColor: .textBackgroundColor)).shadow(color: .black.opacity(0.12), radius: 10, y: 3))
    }

    func finish(_ t: TourController) -> some View {
        let keys: [(String, String)] = [
            ("⇥", "child"), ("↩", "sibling"), ("⇧↩", "before"), ("⌘↩", "parent"), ("←↑→↓", "move"), ("⌥⌘↑↓", "reorder"),
            ("⇧⌘L", "connect"),
            ("⌥⌘T", "convert"),
        ]
        return VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("You built your first map in \(t.elapsedText)").font(.chrome(26, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                Text("FINISH").font(.chrome(12, weight: .semibold, design: .monospaced)).foregroundStyle(
                    .white.opacity(0.6))
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), alignment: .leading,
                spacing: 14
            ) {
                ForEach(keys, id: \.0) { k, label in
                    HStack(spacing: 8) {
                        Text(k).font(.chrome(12, weight: .medium, design: .monospaced)).foregroundStyle(.white)
                            .padding(.horizontal, 6).frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12)))
                        Text(label).font(.chrome(15)).foregroundStyle(.white.opacity(0.9))
                    }
                }
            }
            HStack(alignment: .bottom) {
                Text("Hold ⌘ any time to see these again. Your tutorial map stays as your first document.")
                    .font(.chrome(15)).foregroundStyle(.white.opacity(0.75)).fixedSize(
                        horizontal: false, vertical: true)
                Spacer(minLength: 20)
                Button {
                    t.end()
                } label: {
                    Text("Keep mapping ↩").font(.chrome(15, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 22).frame(height: 40)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 860)
        .background(RoundedRectangle(cornerRadius: 22).fill(Color(white: 0.1)))
        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)
    }
}

// MARK: Tips (artboard 31, "Progressive tip") and empty-canvas hints

struct TipView: View {
    var controller: CanvasController

    var body: some View {
        if let tip = controller.tip {
            HStack(spacing: 10) {
                Text("Faster:").font(.chrome(14, weight: .medium))
                Text(tip.keys).font(.chrome(12, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6).frame(height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
                Text(tip.does).font(.chrome(14))
                Button("Don’t show tips") {
                    controller.prefs.set("general.tips", false)
                    controller.tip = nil
                }
                .buttonStyle(.link)
                .font(.chrome(13))
                .padding(.leading, 12)
            }
            .padding(.horizontal, 16).frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .textBackgroundColor)).shadow(
                    color: .black.opacity(0.12), radius: 10, y: 3)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.6)))
            .accessibilityElement(children: .combine)
        }
    }
}

/// Three faint keycaps on a fresh canvas (⇥ · ↩ · /) that fade after the first keystroke.
struct EmptyCanvasHints: View {
    var controller: CanvasController

    var body: some View {
        let _ = controller.prefsRevision
        if controller.showsEmptyHints {
            HStack(spacing: 18) {
                hint("⇥", "child")
                hint("↩", "sibling")
                hint("/", "insert")
            }
            .opacity(0.55)
            .transition(.opacity)
            .accessibilityHidden(true)
        }
    }

    func hint(_ k: String, _ t: String) -> some View {
        HStack(spacing: 6) {
            Text(k).font(.chrome(13, weight: .medium, design: .monospaced)).padding(.horizontal, 7).frame(
                height: 24
            )
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator))
            Text(t).font(.chrome(13)).foregroundStyle(.secondary)
        }
    }
}
