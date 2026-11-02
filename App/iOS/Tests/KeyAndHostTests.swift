import NexusCanvas
import NexusCore
import NexusKeys
import NexusScene
import NexusTouch
import Testing
import UIKit

@testable import OpenNexus

extension HostedTests {
    /// A7's keyboard half and the platform host on iOS: every registered binding is a
    /// `UIKeyCommand` on the canvas, routed to the same `handleKey`; chords reach the
    /// controller as `pressesBegan` sends them; the app installs the touch host.
    @MainActor
    @Suite(.serialized) struct KeyAndHostTests {
        @Test func everyBindingIsAKeyCommand() {
            let h = TouchHarness()
            let commands = h.view.keyCommands ?? []
            let specs = Set(commands.compactMap { $0.propertyList as? String })
            var missing: [String] = []
            var bound = 0
            for c in h.controller.registry.commands {
                for chord in h.controller.bindings(for: c.id) {
                    bound += 1
                    // ⌦ has no UIKeyCommand input; pressesBegan still routes it.
                    if case .forwardDelete = chord.key { continue }
                    if !specs.contains(chord.spec) { missing.append("\(c.id.rawValue): \(chord.spec)") }
                }
            }
            #expect(bound > 150, "the registry's bindings")
            #expect(missing.isEmpty, "bindings without a UIKeyCommand: \(missing)")
            // Holding ⌘ lists each command once: later bindings are hidden.
            let listed = commands.filter { !$0.attributes.contains(.hidden) }
            #expect(Set(listed.compactMap(\.title)).count > 100)
            #expect(commands.allSatisfy { $0.wantsPriorityOverSystemBehavior })
        }

        @Test func chordsBuildAThreeLevelMap() {
            let h = TouchHarness()
            let root = h.canvas.root
            h.controller.select(root)
            h.press("tab")
            h.type("First")
            h.press("return")
            #expect(h.canvas.nodes[root]?.children.count == 1)
            let first = h.canvas.nodes[root]!.children[0]
            #expect(h.text(first) == "First")
            h.press("return")
            h.type("Second")
            h.press("return")
            h.press("tab")
            h.type("Deep")
            h.press("return")
            #expect(h.canvas.nodes[root]?.children.count == 2)
            let second = h.canvas.nodes[root]!.children[1]
            #expect(h.canvas.nodes[second]?.children.map { h.text($0) } == ["Deep"])
            h.key("cmd+z")
            h.key("cmd+z")
            #expect(h.canvas.nodes[second]?.children.isEmpty == true, "two undos take back the name and the topic")
        }

        /// Esc closes the palette from the canvas's key path, and ⌘. does the same (D406).
        @Test func escAndCommandDotCloseThePalette() {
            let h = TouchHarness()
            h.controller.select(h.canvas.root)
            for spec in ["esc", "cmd+."] {
                h.key("cmd+k")
                #expect(h.controller.palette != nil, "⌘K opens the palette")
                h.key(spec)
                #expect(h.controller.palette == nil, "\(spec) closes it")
            }
        }

        @Test func theAppInstallsTheTouchHost() {
            #expect(CanvasHosts.platform() is TouchCanvasHost)
            #expect(Graphics.platform is UIKitGraphics)
            #expect(PlatformNetwork.provider is InProcessNetwork)
        }
    }
}
