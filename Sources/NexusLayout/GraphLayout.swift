import CoreGraphics
import Foundation
import NexusCore

/// Layered layout for technical canvases (Sugiyama-lite): flowcharts top-down; DFD,
/// threat model and architecture left-to-right; swimlanes with lanes as rows.
///
/// 1. Break cycles (DFS back edges are reversed for ranking only).
/// 2. Rank by longest path; sources are pulled next to their first successor.
/// 3. Order each rank by tree order, then barycentre sweeps, keeping boundary groups
///    together.
/// 4. Place ranks along the flow and align nodes with their neighbours across it.
public enum GraphLayout {
    public enum Direction: Sendable { case down, right }

    public struct Result: Sendable, Equatable {
        public var frames: [NodeID: NodeFrame] = [:]
        /// Swimlane bands (one per lane), in canvas coordinates.
        public var bands: [CGRect] = []
        public var bounds: CGRect { frames.values.reduce(CGRect.null) { $0.union($1.rect) } }
    }

    public struct Options: Sendable {
        public var direction: Direction = .down
        /// Gap between ranks (along the flow).
        public var rankGap: CGFloat = 64
        /// Gap between neighbours in a rank (across the flow).
        public var nodeGap: CGFloat = 48
        /// Node → group (boundary) so members stay together.
        public var groups: [NodeID: Int] = [:]
        /// Swimlanes: node → lane index, and the number of lanes.
        public var lanes: [NodeID: Int]? = nil
        public var laneCount: Int = 0
        public var lanePadding: CGFloat = 36
        public var laneHeader: CGFloat = 32
        public init() {}
    }

    public static func layout(
        nodes: [NodeID: CGSize], order: [NodeID], edges: [(NodeID, NodeID)], options: Options = Options()
    ) -> Result {
        let ids = order.filter { nodes[$0] != nil }
        guard !ids.isEmpty else { return Result() }
        let index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        var succ = [[Int]](repeating: [], count: ids.count)
        var pred = [[Int]](repeating: [], count: ids.count)
        var seen = Set<[Int]>()
        for (a, b) in edges {
            guard let i = index[a], let j = index[b], i != j, seen.insert([i, j]).inserted else { continue }
            succ[i].append(j)
            pred[j].append(i)
        }

        // 1. Cycle breaking: DFS in tree order; edges into a node on the stack are back edges.
        var dagSucc = [[Int]](repeating: [], count: ids.count)
        var state = [UInt8](repeating: 0, count: ids.count)  // 0 new, 1 on stack, 2 done
        func dfs(_ v: Int) {
            state[v] = 1
            for w in succ[v] {
                if state[w] == 1 {
                    dagSucc[w].append(v)  // reversed
                } else {
                    dagSucc[v].append(w)
                    if state[w] == 0 { dfs(w) }
                }
            }
            state[v] = 2
        }
        for v in ids.indices where state[v] == 0 { dfs(v) }
        var dagPred = [[Int]](repeating: [], count: ids.count)
        for v in ids.indices { for w in dagSucc[v] { dagPred[w].append(v) } }

        // 2. Ranks: longest path over the DAG (Kahn order).
        var rank = [Int](repeating: 0, count: ids.count)
        var indeg = dagPred.map(\.count)
        var queue = ids.indices.filter { indeg[$0] == 0 }
        var topo: [Int] = []
        while let v = queue.first {
            queue.removeFirst()
            topo.append(v)
            for w in dagSucc[v] {
                rank[w] = max(rank[w], rank[v] + 1)
                indeg[w] -= 1
                if indeg[w] == 0 { queue.append(w) }
            }
        }
        // Sources sit just before their nearest successor (an entity feeding step 3 sits at rank 2).
        for v in topo.reversed() where dagPred[v].isEmpty && !dagSucc[v].isEmpty {
            rank[v] = max(0, (dagSucc[v].map { rank[$0] }.min() ?? 1) - 1)
        }
        let maxRank = rank.max() ?? 0
        var layers = [[Int]](repeating: [], count: maxRank + 1)
        for v in ids.indices { layers[rank[v]].append(v) }  // tree order within each rank

        // 3. Ordering: barycentre sweeps, stable by tree order, boundary groups together.
        var pos = [Double](repeating: 0, count: ids.count)
        func renumber() { for layer in layers { for (i, v) in layer.enumerated() { pos[v] = Double(i) } } }
        renumber()
        let laneOf: (Int) -> Int = { v in options.lanes?[ids[v]] ?? 0 }
        func sortLayer(_ r: Int, by neighbours: [[Int]]) {
            var key: [Int: Double] = [:]
            for v in layers[r] {
                let ns = neighbours[v].filter { rank[$0] != r }
                key[v] = ns.isEmpty ? pos[v] : ns.map { pos[$0] }.reduce(0, +) / Double(ns.count)
            }
            var groupKey: [Int: Double] = [:]
            var groupCount: [Int: Int] = [:]
            for v in layers[r] {
                if let g = options.groups[ids[v]] {
                    groupKey[g, default: 0] += key[v]!
                    groupCount[g, default: 0] += 1
                }
            }
            func primary(_ v: Int) -> Double {
                if let g = options.groups[ids[v]] { return groupKey[g]! / Double(groupCount[g]!) }
                return key[v]!
            }
            layers[r].sort { a, b in
                if laneOf(a) != laneOf(b) { return laneOf(a) < laneOf(b) }
                let pa = primary(a)
                let pb = primary(b)
                if abs(pa - pb) > 1e-9 { return pa < pb }
                let ga = options.groups[ids[a]] ?? -1
                let gb = options.groups[ids[b]] ?? -1
                if ga != gb { return ga < gb }
                if abs(key[a]! - key[b]!) > 1e-9 { return key[a]! < key[b]! }
                return a < b
            }
            for (i, v) in layers[r].enumerated() { pos[v] = Double(i) }
        }
        let allPred = pred.enumerated().map { v, ps in ps + succ[v].filter { rank[$0] < rank[v] } }
        let allSucc = succ.enumerated().map { v, ss in ss + pred[v].filter { rank[$0] > rank[v] } }
        if maxRank > 0 {
            for _ in 0..<4 {
                for r in 1...maxRank { sortLayer(r, by: allPred) }
                for r in stride(from: maxRank - 1, through: 0, by: -1) { sortLayer(r, by: allSucc) }
            }
        }

        // 4. Coordinates.
        let down = options.direction == .down
        func along(_ v: Int) -> CGFloat { down ? nodes[ids[v]]!.height : nodes[ids[v]]!.width }
        func across(_ v: Int) -> CGFloat { down ? nodes[ids[v]]!.width : nodes[ids[v]]!.height }
        var rankPos: [CGFloat] = []
        var cursor: CGFloat = 0
        for layer in layers {
            let thick = layer.map(along).max() ?? 0
            rankPos.append(cursor + thick / 2)
            cursor += thick + options.rankGap
        }
        var cross = [CGFloat](repeating: 0, count: ids.count)
        var result = Result()

        if let lanes = options.lanes, options.laneCount > 0 {
            // Swimlanes: each lane is a band; same-rank nodes in a lane stack within it.
            var laneHeight = [CGFloat](repeating: 0, count: options.laneCount)
            for layer in layers {
                var used = [CGFloat](repeating: 0, count: options.laneCount)
                for v in layer {
                    let l = min(max(lanes[ids[v]] ?? 0, 0), options.laneCount - 1)
                    used[l] += across(v) + (used[l] > 0 ? options.nodeGap / 2 : 0)
                }
                for l in 0..<options.laneCount { laneHeight[l] = max(laneHeight[l], used[l]) }
            }
            var top: CGFloat = 0
            var laneTop: [CGFloat] = []
            for l in 0..<options.laneCount {
                laneHeight[l] = max(140, laneHeight[l] + 2 * options.lanePadding + options.laneHeader)
                laneTop.append(top)
                top += laneHeight[l]
            }
            for layer in layers {
                var byLane: [Int: [Int]] = [:]
                for v in layer { byLane[min(max(lanes[ids[v]] ?? 0, 0), options.laneCount - 1), default: []].append(v) }
                for (l, vs) in byLane {
                    let total = vs.map(across).reduce(0, +) + CGFloat(vs.count - 1) * options.nodeGap / 2
                    var c =
                        laneTop[l] + options.laneHeader + (laneHeight[l] - options.laneHeader - total) / 2
                    for v in vs {
                        cross[v] = c + across(v) / 2
                        c += across(v) + options.nodeGap / 2
                    }
                }
            }
            let length = cursor - options.rankGap
            for l in 0..<options.laneCount {
                result.bands.append(
                    CGRect(x: -150, y: laneTop[l], width: length + 300, height: laneHeight[l]))
            }
        } else {
            // Initial packing, then neighbour alignment sweeps with minimum separation.
            for layer in layers {
                var c: CGFloat = 0
                for v in layer {
                    cross[v] = c + across(v) / 2
                    c += across(v) + options.nodeGap
                }
                let shift = (c - options.nodeGap) / 2
                for v in layer { cross[v] -= shift }
            }
            func align(_ layer: [Int], toward neighbours: [[Int]]) {
                guard !layer.isEmpty else { return }
                var desired = layer.map { v -> CGFloat in
                    let ns = neighbours[v]
                    return ns.isEmpty ? cross[v] : ns.map { cross[$0] }.reduce(0, +) / CGFloat(ns.count)
                }
                // Forward pass: honour order and separation.
                for i in layer.indices.dropFirst() {
                    let minC = desired[i - 1] + (across(layer[i - 1]) + across(layer[i])) / 2 + options.nodeGap
                    desired[i] = max(desired[i], minC)
                }
                // Backward pass pulls an over-pushed run back toward its targets.
                let original = layer.map { v -> CGFloat in
                    let ns = neighbours[v]
                    return ns.isEmpty ? cross[v] : ns.map { cross[$0] }.reduce(0, +) / CGFloat(ns.count)
                }
                let drift = zip(desired, original).map { $0 - $1 }.reduce(0, +) / CGFloat(layer.count)
                for i in layer.indices { desired[i] -= drift / 2 }
                for i in layer.indices.dropFirst() {
                    let minC = desired[i - 1] + (across(layer[i - 1]) + across(layer[i])) / 2 + options.nodeGap
                    desired[i] = max(desired[i], minC)
                }
                for (i, v) in layer.enumerated() { cross[v] = desired[i] }
            }
            for _ in 0..<4 {
                for r in layers.indices.dropFirst() { align(layers[r], toward: allPred) }
                for r in layers.indices.reversed().dropFirst() { align(layers[r], toward: allSucc) }
            }
        }

        for v in ids.indices {
            let size = nodes[ids[v]]!
            let center = down ? CGPoint(x: cross[v], y: rankPos[rank[v]]) : CGPoint(x: rankPos[rank[v]], y: cross[v])
            result.frames[ids[v]] = NodeFrame(center: center, size: size, side: down ? .down : .right, depth: rank[v])
        }
        // Round to the format's half-point grid so files and goldens stay stable.
        for (id, f) in result.frames {
            result.frames[id]?.center = CGPoint(x: (f.center.x * 2).rounded() / 2, y: (f.center.y * 2).rounded() / 2)
        }
        return result
    }
}
