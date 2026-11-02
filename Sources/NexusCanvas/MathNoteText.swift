import NexusCore
import NexusScene
import NexusTheme
import SwiftUI

/// A note's text with its `$…$` and `$$…$$` typeset (M48): the presenter's notes and the
/// note popover's preview. Text without formulas, or with Settings › Editing › Typeset
/// math in text off, is a plain `Text`.
struct MathNoteText: View {
    let text: String
    var size: CGFloat
    var typesets = Preferences.shared.bool("editing.typesetMath")
    @Environment(\.colorScheme) private var scheme
    /// Bumped as formulas finish typesetting in the background.
    @State private var generation = 0

    var body: some View {
        if typesets, !MathMarkup.scan(text).formulas.isEmpty {
            let styled = attributed
            MathTextFrame(text: styled) {
                Canvas { ctx, size in
                    ctx.withCGContext { cg in
                        styled.draw(with: CGRect(origin: .zero, size: size), options: [.lineFragmentOrigin], in: cg)
                    }
                }
            }
            .accessibilityElement()
            .accessibilityLabel(MathMarkup.plain(text))
            .onReceive(NotificationCenter.default.publisher(for: MathEngine.didTypeset)) { _ in generation += 1 }
        } else {
            Text(text).font(.chrome(size))
        }
    }

    var attributed: StyledText {
        _ = generation
        let ink = scheme == .dark ? CGColor(gray: 0.96, alpha: 1) : CGColor(gray: 0.08, alpha: 1)
        let error = Theme.classic.formulaErrorColor(
            on: scheme == .dark ? RGBA(hex: "#1E1E22") : .white, canvas: scheme == .dark ? RGBA(hex: "#1E1E22") : .white
        )
        return MathText.styled(
            text, TextAttributes(font: Fonts.system(size), color: .fixed(ink)), errorColor: .fixed(error.cgColor))
    }
}

/// Sizes its one subview to the text laid out at the width offered.
private struct MathTextFrame: Layout {
    /// Built for this layout and never changed, so sharing it is safe.
    nonisolated(unsafe) let text: StyledText

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let s = text.boundingRect(
            size: CGSize(width: width ?? 1e7, height: 1e7), options: [.lineFragmentOrigin])
        return CGSize(width: width ?? ceil(s.width), height: ceil(s.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for v in subviews { v.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}
