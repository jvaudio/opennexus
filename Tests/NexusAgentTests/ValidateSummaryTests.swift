import Foundation
import Testing

@testable import NexusAgent
@testable import NexusCore
@testable import NexusFormat

/// M33: `nexus validate` counts in English, "1 canvas, 1 topic" (D257).
extension CLITests {
    @Test func validateSummaryIsSingularAware() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let blank = DocumentModel.blank()
        #expect(blank.canvases.count == 1 && blank.topicCount == 1)
        let one = box.maps.appending(path: "One.nexus")
        try NexusPackage.write(blank, to: one)
        let (ok, out, _, _) = run(["validate", "One.nexus"], in: box.maps)
        #expect(ok == 0 && out == "One.nexus: valid (1 canvas, 1 topic)\n")
        // The launch plan still reads in plurals.
        let (plan, planOut, _, _) = run(["validate", "Launch plan.nexus"], in: box.maps)
        #expect(plan == 0 && planOut.contains("valid (2 canvases, 20 topics)"))
        #expect(NexusCLI.counted(0, "topic", "topics") == "0 topics")
        #expect(NexusCLI.counted(1, "canvas", "canvases") == "1 canvas")
    }
}
