import AppKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusLayout

/// A map with `mains × subs × leaves` topics under one root.
func bigDocument(mains: Int, subs: Int, leaves: Int) -> DocumentModel {
    var c = Canvas(id: "c1", title: "Big", rootText: "Benchmark")
    var undo = UndoStack()
    c.edit("Build", undo: &undo) { e in
        for m in 0..<mains {
            let mid = try! e.addChild(of: e.canvas.root, text: "Main topic \(m)")
            for s in 0..<subs {
                let sid = try! e.addChild(of: mid, text: "Subtopic \(m).\(s) with words")
                for l in 0..<leaves { try! e.addChild(of: sid, text: "Leaf \(m).\(s).\(l)") }
            }
        }
    }
    return DocumentModel(canvases: [c])
}

func median(_ xs: [Duration]) -> Duration { xs.sorted()[xs.count / 2] }

func ms(_ d: Duration) -> Double {
    Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
}

@MainActor
@Suite(.serialized) struct PerformanceTests {
    /// Key press to a new node with a live caret: under 16 ms (one frame at 60 Hz).
    @Test func keyToCaretUnder16ms() throws {
        let h = CanvasHarness(model: bigDocument(mains: 8, subs: 5, leaves: 4))  // 209 topics
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for i in 0..<30 {
            let main = h.canvas.nodes[h.canvas.root]!.children[i % 8]
            h.controller.select(main)
            let d = clock.measure { h.press("tab") }
            #expect(h.controller.mode == .edit)
            #expect(h.window.firstResponder === h.host.canvasView.editor)
            #expect(!h.host.canvasView.editor.isHidden)
            samples.append(d)
            h.press("return")
        }
        let m = median(samples)
        print("key→caret median \(ms(m)) ms, max \(ms(samples.max()!)) ms")
        #expect(ms(m) < 16, "key→caret median \(ms(m)) ms")
    }

    /// Layout reflow on a 1,000-node map: under 50 ms.
    @Test func reflow1000NodesUnder50ms() {
        let doc = bigDocument(mains: 10, subs: 10, leaves: 9)  // 1,011 topics
        let store = DocumentStore(model: doc)
        let controller = CanvasController(store: store)
        #expect(controller.scene.nodes.count == 1011)
        let clock = ContinuousClock()
        let target = controller.canvas.nodes[controller.canvas.root]!.children[3]
        var samples: [Duration] = []
        for i in 0..<20 {
            controller.select(target)
            let d = clock.measure {
                controller.perform("Typing") { $0.setText(target, "Renamed \(i)") }
            }
            samples.append(d)
        }
        let m = median(samples)
        print("1k reflow median \(ms(m)) ms")
        #expect(ms(m) < 50, "1k reflow median \(ms(m)) ms")
    }

    /// Pure layout cost for 1,000 and 5,000 nodes (reported, and bounded).
    @Test func pureLayoutScales() {
        for (mains, subs, leaves) in [(10, 10, 9), (20, 25, 9)] {
            var nodes: [NodeID: LayoutNode] = [:]
            var rootKids: [NodeID] = []
            var n = 2
            for _ in 0..<mains {
                let m = NodeID("n\(n)"); n += 1
                var sk: [NodeID] = []
                for _ in 0..<subs {
                    let s = NodeID("n\(n)"); n += 1
                    var lk: [NodeID] = []
                    for _ in 0..<leaves {
                        let l = NodeID("n\(n)"); n += 1
                        nodes[l] = LayoutNode(size: CGSize(width: 90, height: 32), children: [])
                        lk.append(l)
                    }
                    nodes[s] = LayoutNode(size: CGSize(width: 120, height: 32), children: lk)
                    sk.append(s)
                }
                nodes[m] = LayoutNode(size: CGSize(width: 140, height: 38), children: sk)
                rootKids.append(m)
            }
            nodes["n1"] = LayoutNode(size: CGSize(width: 160, height: 52), children: rootKids)
            let d = ContinuousClock().measure {
                _ = TreeLayout.layout(root: "n1", nodes: nodes, structure: .mindmapBalanced)
            }
            print("pure layout \(nodes.count) nodes: \(ms(d)) ms")
            #expect(ms(d) < 50)
        }
    }

    /// Renders the P0 sample map (for visual review; written to the scratch folder).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"] != nil))
    func snapshotSampleMap() throws {
        let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NEXUS_SNAPSHOT_DIR"]!)
        var c = Canvas(id: "c1", title: "Launch plan", rootText: "Launch plan")
        var undo = UndoStack()
        c.edit("Sample", undo: &undo) { e in
            let tree: [(String, [String])] = [
                ("Positioning", ["Developers", "Teams"]), ("Pricing", ["Free tier", "Pro", "Annual discount"]),
                ("Channels", ["Product Hunt", "Newsletter"]), ("Timeline", ["Beta · Nov", "GA · Jan"]),
                ("Risks", ["Competitor response"]),
            ]
            for (m, subs) in tree {
                let id = try! e.addChild(of: e.canvas.root, text: m)
                for s in subs { try! e.addChild(of: id, text: s) }
            }
        }
        let h = CanvasHarness(model: DocumentModel(canvases: [c]))
        h.host.canvasView.centerScene()
        h.controller.select(h.canvas.nodes[h.canvas.root]!.children[1])
        h.snapshot(to: dir.appendingPathComponent("sample-select.png"))
        h.press("tab")
        h.type("Enterprise")
        h.snapshot(to: dir.appendingPathComponent("sample-edit.png"))
        h.press("return")
        h.controller.select(h.canvas.nodes[h.canvas.root]!.children[4])
        h.press("cmd+/")
        h.press("ctrl+1")
        h.press("cmd+home")
        h.press("opt+cmd+2")
        h.snapshot(to: dir.appendingPathComponent("sample-logic.png"))
        h.controller.cheatSheetVisible = true
        h.snapshot(to: dir.appendingPathComponent("cheat-sheet.png"))
    }
}
