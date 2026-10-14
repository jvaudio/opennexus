import CoreGraphics
import Foundation
import NexusCore

/// Sequence diagrams (artboard 23): participants in a row, messages top to bottom in
/// order, dashed lifelines, and activation bars matched automatically.
public enum SequenceLayout {
    public struct Message: Sendable, Equatable {
        public var from: NodeID
        public var to: NodeID
        public var isReturn: Bool
        public var labelWidth: CGFloat

        public init(from: NodeID, to: NodeID, isReturn: Bool, labelWidth: CGFloat) {
            self.from = from
            self.to = to
            self.isReturn = isReturn
            self.labelWidth = labelWidth
        }
    }

    public struct Result: Sendable, Equatable {
        public var frames: [NodeID: NodeFrame] = [:]
        /// y of each message, in order.
        public var messageY: [CGFloat] = []
        /// Where lifelines end.
        public var lifelineBottom: CGFloat = 0
        /// Activation bars per participant (y ranges).
        public var activations: [NodeID: [ClosedRange<CGFloat>]] = [:]
    }

    public static let messagePitch: CGFloat = 56
    public static let activationWidth: CGFloat = 12

    public static func layout(participants: [NodeID], sizes: [NodeID: CGSize], messages: [Message]) -> Result {
        var r = Result()
        guard !participants.isEmpty else { return r }
        let index = Dictionary(uniqueKeysWithValues: participants.enumerated().map { ($1, $0) })
        // Spacing between neighbours fits the widest label crossing that gap.
        var gapNeed = [CGFloat](repeating: 0, count: max(participants.count - 1, 0))
        for m in messages {
            guard let a = index[m.from], let b = index[m.to], a != b else { continue }
            let lo = min(a, b)
            let hi = max(a, b)
            let per = (m.labelWidth + 60) / CGFloat(hi - lo)
            for g in lo..<hi { gapNeed[g] = max(gapNeed[g], per) }
        }
        var x: CGFloat = 0
        let height = participants.compactMap { sizes[$0]?.height }.max() ?? 44
        for (i, p) in participants.enumerated() {
            let s = sizes[p] ?? CGSize(width: 140, height: 44)
            if i > 0 {
                let prev = sizes[participants[i - 1]]?.width ?? 140
                x += max(prev / 2 + s.width / 2 + 110, gapNeed[i - 1])
            }
            r.frames[p] = NodeFrame(center: CGPoint(x: x, y: height / 2), size: s, side: .down, depth: 1)
        }
        var y = height + 48
        var open: [NodeID: [CGFloat]] = [:]
        for m in messages {
            r.messageY.append(y)
            if m.from != m.to, index[m.from] != nil, index[m.to] != nil {
                if m.isReturn {
                    if let start = open[m.from]?.popLast() {
                        r.activations[m.from, default: []].append(start...y)
                    }
                } else {
                    open[m.to, default: []].append(y)
                }
            }
            y += messagePitch
        }
        let end = y - messagePitch + 20
        for (p, starts) in open {
            for s in starts { r.activations[p, default: []].append(s...max(end, s + 24)) }
        }
        r.lifelineBottom = max(y + 10, height + 160)
        return r
    }
}
