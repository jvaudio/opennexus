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
            // Sub-causes first (D237), kept only when some are found; then the plain fit
            // (D192), so a fishbone without them reads exactly as before.
            // A sub-cause isn't a wrap of its cause, and the next one under it, starting with a
            // capital, isn't a wrap of it either.
            func sub(_ a: TextBox) -> Bool {
                lines.contains { stacked(a, under: $0) && tucked(a, under: $0, headRight: headRight) }
            }
            let apart = Self.mergeWrapped(lines, keep: h) { a, b in
                tucked(b, under: a, headRight: headRight)
                    || (b.text.first.map { $0.isUppercase || $0.isNumber } == true && sub(a))
            }
            if let found = fishbone(apart.lines, head: apart.root, headRight: headRight, subCauses: true) {
                return found
            }
            let wrapped = Self.mergeWrapped(lines, keep: h)
            if let found = fishbone(wrapped.lines, head: wrapped.root, headRight: headRight) { return found }
        }
        return nil
    }

    /// `b` sits under `a`, across from it, at most 1.2 lines below.
    func stacked(_ b: TextBox, under a: TextBox) -> Bool {
        let gap = b.minY - a.maxY
        return a.minY < b.minY && gap >= -0.25 * medianHeight && gap <= 1.2 * max(a.size, b.size)
            && min(a.maxX, b.maxX) > max(a.minX, b.minX)
    }

    /// `b`, tightly under `a`, starts behind `a`'s head-side end by half a line or more,
    /// and isn't a wrapped line of it: those share `a`'s far end (left- or right-aligned
    /// text) or are inset equally at both ends (centred).
    func tucked(_ b: TextBox, under a: TextBox, headRight: Bool) -> Bool {
        let line = medianHeight
        let headInset = headRight ? a.maxX - b.maxX : b.minX - a.minX
        let farInset = headRight ? b.minX - a.minX : a.maxX - b.maxX
        return headInset >= 0.5 * line && abs(farInset) >= 0.3 * line && abs(headInset - farInset) >= 0.5 * line
    }

    /// Bones found for one slope: category labels and, for each, its causes (nearest the
    /// label first), with how far each cause's inner end sits from its bone.
    struct Bones {
        var labels: [Int] = []
        var causes: [Int: [Int]] = [:]
        var gaps: [Double] = []
        /// Each cause's gap, by line.
        var gap: [Int: Double] = [:]

        var spread: Double {
            guard !gaps.isEmpty else { return 0 }
            let mean = gaps.reduce(0, +) / Double(gaps.count)
            return gaps.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(gaps.count)
        }
    }

    /// The fit for one head. With `subCauses`, lines tucked under a cause and set back from
    /// its bone are that cause's sub-causes (D237), and nil unless there are some.
    func fishbone(
        _ lines: [TextBox], head h: Int, headRight: Bool, subCauses: Bool = false
    ) -> (tree: T, structure: LayoutStructure)? {
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
        // Sub-cause candidates, top down: a line tucked under the nearest line above it on
        // its side of the spine (`host`), across from it and at most 1.2 lines below, whose
        // head-side end is half a line or more behind the host's, or level with a host that
        // is itself a candidate (the next sub-cause of a list).
        var host: [Int: Int] = [:]
        var candidates: [Int] = []
        if subCauses {
            for i in others.sorted(by: { lines[$0].minY < lines[$1].minY }) {
                let b = lines[i]
                let above = others.filter { k in k != i && up(k) == up(i) && stacked(b, under: lines[k]) }
                guard var p = above.max(by: { lines[$0].maxY < lines[$1].maxY }) else { continue }
                // Out from under a deeper sub-cause, back to the level it lines up with.
                while let q = host[p], lean * (anchor(lines[p]) - anchor(b)) <= -tol { p = q }
                let inset = lean * (anchor(lines[p]) - anchor(b))
                if inset >= tol || (host[p] != nil && abs(inset) < tol) {
                    host[i] = p
                    candidates.append(i)
                }
            }
            guard !candidates.isEmpty else { return nil }
        }
        // Farthest from the spine first: a bone's label is its outermost text.
        let order = others.sorted { fromSpine($0) > fromSpine($1) }
        func fit(_ slope: Double, without excluded: Set<Int>) -> Bones {
            var f = Bones()
            for i in order where !excluded.contains(i) {
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
                    f.gap[i] = best.d
                } else {
                    f.labels.append(i)
                }
            }
            return f
        }
        // The slope that explains the text with the fewest bones, then the most even gaps.
        func bestFit(without excluded: Set<Int>) -> (slope: Double, bones: Bones)? {
            var best: (slope: Double, bones: Bones)?
            for step in 4...32 {
                let slope = Double(step) * 0.05
                let f = fit(slope, without: excluded)
                if let b = best, (b.bones.labels.count, b.bones.spread) <= (f.labels.count, f.spread) { continue }
                best = (slope, f)
            }
            return best
        }
        var excluded = Set(candidates)
        /// The cause a sub-cause belongs to: the first host up its chain that isn't one.
        func cause(of s: Int) -> Int? {
            var k = host[s]
            while let x = k, excluded.contains(x) { k = host[x] }
            return k
        }
        /// A sub-cause sits further behind its cause's bone than the bone's causes do: by
        /// ¾ of a line, or half a line in text no more than 0.8× its cause's.
        func setBack(_ s: Int, slope: Double, bones: Bones) -> Bool {
            guard let c = cause(of: s), let (k, list) = bones.causes.first(where: { $0.value.contains(c) }) else {
                return false
            }
            let typical = Self.median(list.compactMap { bones.gap[$0] })
            let gap = lean * (bone(k, at: lines[s].midY, slope: slope) - anchor(lines[s]))
            let smaller = lines[s].size <= 0.8 * lines[c].size
            return gap - typical >= (smaller ? 1 : 1.5) * tol
        }
        var best = bestFit(without: excluded)
        // The candidates set back from the bones of the last fit are the sub-causes, the rest
        // are causes, and the bones are fitted again, until the sub-causes settle.
        if subCauses {
            var settled = false
            for _ in 0..<5 {
                guard let (slope, bones) = best else { return nil }
                let kept = Set(candidates).filter { setBack($0, slope: slope, bones: bones) }
                if kept == excluded {
                    settled = true
                    break
                }
                excluded = kept
                guard !excluded.isEmpty else { return nil }
                best = bestFit(without: excluded)
            }
            guard settled else { return nil }
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
        // Sub-causes, top down, hang from their host: beside a host that is a sub-cause too,
        // they share its parent; behind it, or under a cause, they're its children.
        var parent: [Int: Int] = [:]
        var subs: [Int: [Int]] = [:]
        for s in candidates where excluded.contains(s) {
            let p = host[s]!
            let inset = lean * (anchor(lines[p]) - anchor(lines[s]))
            let under = excluded.contains(p) && abs(inset) < tol ? parent[p]! : p
            parent[s] = under
            subs[under, default: []].append(s)
        }
        func topic(_ i: Int) -> T {
            var t = Self.topic(lines[i])
            t.children = (subs[i] ?? []).map(topic)
            return t
        }
        var root = Self.topic(H)
        root.children = categories.map { k in
            var t = Self.topic(lines[k])
            t.children = (bones.causes[k] ?? []).map(topic)
            return t
        }
        return (root, headRight ? .fishboneLeft : .fishboneRight)
    }
}
