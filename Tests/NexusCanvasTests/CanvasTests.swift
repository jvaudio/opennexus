import Testing

@testable import NexusCanvas

@Suite struct CanvasSmokeTests {
    @Test @MainActor func moduleLoads() { #expect(!NexusCanvasInfo.version.isEmpty) }
}
