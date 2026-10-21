import Foundation
import NexusCore

// MARK: Fishbone diagrams

extension Builder {
    /// An Ishikawa diagram (D192): a head at one end of a horizontal spine, category labels
    /// at the far ends of diagonal bones above and below it, and causes along each bone on
    /// the side away from the head. Nil unless the text fits that shape: nothing crosses the
    /// spine, everything sits behind the head, both sides have bones standing side by side,
    /// the causes sit the same distance behind their bones, and they shift toward the head
    /// as they near the spine.
    func fishbone() -> (tree: T, structure: LayoutStructure)? {
        guard lines.count >= 5 else { return nil }
        let c = content
        let span = c.maxY - c.minY
        for headRight in [true, false] {
            let h = lines.indices.max { headRight ? lines[$0].maxX < lines[$1].maxX : lines[$0].minX > lines[$1].minX }!
            let H = lines[h]
            guard H.size >= medianHeight, H.midY > c.minY + 0.25 * span, H.midY < c.maxY - 0.25 * span else {
                continue
            }
            let wrapped = Self.mergeWrapped(lines, keep: h)
            if let found = fishbone(wrapped.lines, head: wrapped.root, headRight: headRight) { return found }
        }
        return nil
    }

    /// Bones found for one slope: category labels and, for each, its causes (nearest the
    /// label first), with how far each cause's inner end sits from its bone.
    struct Bones {
        var labels: [Int] = []
        var causes: [Int: [Int]] = [:]
        var gaps: [Double] = []

        var spread: Double {
            guard !gaps.isEmpty else { return 0 }
            let mean = gaps.reduce(0, +) / Double(gaps.count)
            return gaps.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(gaps.count)
        }
    }

    func fishbone(_ lines: [TextBox], head h: Int, headRight: Bool) -> (tree: T, structure: LayoutStructure)? {
        let H = lines[h]
        let spine = H.midY
        let tol = 0.5 * medianHeight
        let others = lines.indices.filter { $0 != h }
        // Everything is behind the head, and text sits along the bones, not across the spine.
        guard
            others.allSatisfy({ headRight ? lines[$0].maxX <= H.minX + tol : lines[$0].minX >= H.maxX - tol })
        else { return nil }
        let crossing = others.filter { lines[$0].minY < spine && lines[$0].maxY > spine }.count
        guard crossing * 20 <= others.count else { return nil }
        // +1 when the bones lean right, toward a head on the right, as they near the spine.
        let lean: Double = headRight ? 1 : -1
        func up(_ i: Int) -> Bool { lines[i].midY < spine }
        func fromSpine(_ i: Int) -> Double { abs(lines[i].midY - spine) }
        /// The head-side end of a cause, which sits just behind its bone.
        func anchor(_ b: TextBox) -> Double { headRight ? b.maxX : b.minX }
        /// The bone's x at height `y`: it leaves the label's edge nearest the spine and leans
        /// toward the head by `slope` per unit of height.
        func bone(_ k: Int, at y: Double, slope: Double) -> Double {
            let L = lines[k]
            let from = up(k) ? L.maxY : L.minY
            return L.midX + lean * slope * max(0, abs(y - from))
        }
        // Farthest from the spine first: a bone's label is its outermost text.
        let order = others.sorted { fromSpine($0) > fromSpine($1) }
        func fit(_ slope: Double) -> Bones {
            var f = Bones()
            for i in order {
                let b = lines[i]
                var best: (k: Int, d: Double)?
                for k in f.labels where up(k) == up(i) {
                    let d = lean * (bone(k, at: b.midY, slope: slope) - anchor(b))
                    // Behind the bone, close to it, and not reaching past the label's far edge.
                    let L = lines[k]
                    let reaches = headRight ? b.maxX > L.minX - 2 * tol : b.minX < L.maxX + 2 * tol
                    guard d >= -tol, d <= 6 * tol, reaches else { continue }
                    if best.map({ d < $0.d }) ?? true { best = (k, d) }
                }
                if let best {
                    f.causes[best.k, default: []].append(i)
                    f.gaps.append(best.d)
                } else {
                    f.labels.append(i)
                }
            }
            return f
        }
        // The slope that explains the text with the fewest bones, then the most even gaps.
        var best: (slope: Double, bones: Bones)?
        for step in 4...32 {
            let slope = Double(step) * 0.05
            let f = fit(slope)
            if let b = best, (b.bones.labels.count, b.bones.spread) <= (f.labels.count, f.spread) { continue }
            best = (slope, f)
        }
        guard let (slope, bones) = best else { return nil }
        let causes = bones.causes.values.reduce(0) { $0 + $1.count }
        guard bones.labels.count >= 2, bones.labels.contains(where: up), bones.labels.contains(where: { !up($0) }),
            causes >= 2, bones.causes.count * 2 >= bones.labels.count,
            // Causes sit the same distance behind their bones.
            bones.spread.squareRoot() <= 1.5 * tol
        else { return nil }
        // The bones lean: a bone's causes shift toward the head as they near the spine, where
        // a map's children stay in one column.
        for list in bones.causes.values where list.count >= 2 {
            let shift = lean * (anchor(lines[list.last!]) - anchor(lines[list[0]]))
            guard shift >= 0.5 * slope * (fromSpine(list[0]) - fromSpine(list.last!)) else { return nil }
        }
        // Bones stand side by side along the spine: no two labels on a side share a column.
        for side in [true, false] {
            let row = bones.labels.filter { up($0) == side }.map { lines[$0] }.sorted { $0.minX < $1.minX }
            guard zip(row, row.dropFirst()).allSatisfy({ $0.maxX < $1.minX + tol }) else { return nil }
        }
        // Where each bone meets the spine: nearest the head first, the upper bone of a pair first.
        func joint(_ k: Int) -> Double { lean * bone(k, at: spine, slope: slope) }
        var categories = bones.labels.sorted { joint($0) > joint($1) }
        for i in categories.indices.dropFirst()
        where !up(categories[i - 1]) && up(categories[i]) && joint(categories[i - 1]) - joint(categories[i]) < 1.5 * tol
        {
            categories.swapAt(i - 1, i)
        }
        var root = Self.topic(H)
        root.children = categories.map { k in
            var t = Self.topic(lines[k])
            t.children = (bones.causes[k] ?? []).map { Self.topic(lines[$0]) }
            return t
        }
        return (root, headRight ? .fishboneLeft : .fishboneRight)
    }
}
