import Foundation
import NexusCore
import NexusScene
import QuartzCore
import Testing
import UIKit

@testable import NexusCanvas
@testable import NexusTouch

extension HostedTests {
    /// A4 on the iPad Pro 13-inch (M5) simulator: the Mac's budgets, measured the Mac's way
    /// (`PerformanceTests`), on the touch canvas in a window of the app.
    @MainActor
    @Suite(.serialized) struct TimingTests {
        static func bigDocument(mains: Int, subs: Int, leaves: Int) -> DocumentModel {
            var c = NexusCore.Canvas(id: "c1", title: "Big", rootText: "Benchmark")
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

        static func median(_ xs: [Duration]) -> Duration { xs.sorted()[xs.count / 2] }

        static func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }

        /// The harness's canvas in a window of the running app, so it can hold the keyboard.
        static func windowed(_ h: TouchHarness) -> UIWindow {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
            let window = UIWindow(windowScene: scene)
            window.frame = h.view.frame
            window.addSubview(h.view)
            window.makeKeyAndVisible()
            h.view.layoutIfNeeded()
            _ = h.view.becomeFirstResponder()
            return window
        }

        /// Key press to a new topic with a live caret: under 16 ms.
        @Test func keyToCaretUnder16ms() {
            let h = TouchHarness(model: Self.bigDocument(mains: 8, subs: 5, leaves: 4))  // 209 topics
            let window = Self.windowed(h)
            defer { window.isHidden = true }
            // A hardware keyboard's session: keys arrive through `pressesBegan`.
            h.view.keyboardDriven = true
            let clock = ContinuousClock()
            var samples: [Duration] = []
            for i in 0..<30 {
                let main = h.canvas.nodes[h.canvas.root]!.children[i % 8]
                h.controller.select(main)
                let d = clock.measure { h.key("tab") }
                #expect(h.controller.mode == .edit)
                #expect(h.view.editor.isFirstResponder)
                #expect(!h.view.editor.isHidden)
                samples.append(d)
                h.key("return")
            }
            let m = Self.median(samples)
            print("TIMING key→caret median \(Self.ms(m)) ms, max \(Self.ms(samples.max()!)) ms")
            #expect(Self.ms(m) < 16, "key→caret median \(Self.ms(m)) ms")
        }

        /// Layout reflow on a 1,000-node map: under 50 ms (the controller, as the Mac measures
        /// it; with the touch canvas redrawing too, reported).
        @Test func reflow1000NodesUnder50ms() {
            let doc = Self.bigDocument(mains: 10, subs: 10, leaves: 9)  // 1,011 topics
            let controller = CanvasController(store: DocumentStore(model: doc))
            controller.host = MemoryCanvasHost()
            #expect(controller.scene.nodes.count == 1011)
            func run(_ c: CanvasController) -> Duration {
                let clock = ContinuousClock()
                let target = c.canvas.nodes[c.canvas.root]!.children[3]
                var samples: [Duration] = []
                for i in 0..<20 {
                    c.select(target)
                    samples.append(clock.measure { c.perform("Typing") { $0.setText(target, "Renamed \(i)") } })
                }
                return Self.median(samples)
            }
            let m = run(controller)
            let drawn = run(TouchHarness(model: doc).controller)
            print("TIMING 1k reflow median \(Self.ms(m)) ms; with the canvas redrawing \(Self.ms(drawn)) ms")
            #expect(Self.ms(m) < 50, "1k reflow median \(Self.ms(m)) ms")
        }

        /// 5,000 topics: each pan or zoom step's main-thread work fits ProMotion's frame (8.3 ms).
        @Test func panAndZoom5000NodesAt120fps() {
            let h = TouchHarness(model: Self.bigDocument(mains: 20, subs: 25, leaves: 9))  // 5,021 topics
            #expect(h.controller.scene.nodes.count == 5_021)
            let window = Self.windowed(h)
            defer { window.isHidden = true }
            let v = h.view
            CATransaction.flush()
            let clock = ContinuousClock()
            var pan: [Duration] = []
            var zoom: [Duration] = []
            for i in 0..<60 {
                var c = v.camera
                c.offset.x += i % 2 == 0 ? 14 : -9
                c.offset.y += 6
                pan.append(
                    clock.measure {
                        v.setCamera(c, animated: false)
                        CATransaction.flush()
                    })
            }
            for i in 0..<40 {
                zoom.append(
                    clock.measure {
                        v.zoom(by: i < 20 ? 0.94 : 1.06)
                        CATransaction.flush()
                    })
            }
            print(
                "TIMING 5k pan median \(Self.ms(Self.median(pan))) ms, max \(Self.ms(pan.max()!)) ms; zoom median \(Self.ms(Self.median(zoom))) ms, max \(Self.ms(zoom.max()!)) ms"
            )
            #expect(Self.ms(Self.median(pan)) < 8.3, "pan \(Self.ms(Self.median(pan))) ms")
            #expect(Self.ms(Self.median(zoom)) < 8.3, "zoom \(Self.ms(Self.median(zoom))) ms")
        }
    }
}
