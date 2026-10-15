# Benchmarks

Generated maps for the performance targets in README §12. They're not checked in
(`*.nexus` here is ignored by Git). Make them with:

```sh
NEXUS_WRITE_BENCHMARKS=1 swift test --filter writeBenchmarkMaps
```

- `Benchmark 1k.nexus`: 1,011 topics (10 main topics × 10 subtopics × 9 leaves).
- `Benchmark 5k.nexus`: 5,021 topics (20 × 25 × 9).

The same maps are built in memory by `PerformanceTests` and `ScalePerformanceTests`
(`Tests/NexusCanvasTests/PerformanceTests.swift`), which check the targets on every
`swift test`. They're measured in a debug build, so a release build has more headroom.
Instruments' signposts (`com.opennexus.canvas`: `create→caret`, `scene`) cover the same
paths in the app.

| Measure | Target | Test |
| --- | --- | --- |
| Key press to new node with live caret | < 16 ms | `keyToCaretUnder16ms` (209 topics) |
| Layout reflow, 1,000 nodes | < 50 ms | `reflow1000NodesUnder50ms` |
| Pan and zoom with 5,000 nodes | 120 fps (8.3 ms a frame) | `panAndZoom5000NodesAt120fps` |
| Open a 1,000-node document | < 1 s | `open1000NodeDocumentUnder1s` |
| First AI ghost suggestion | < 1.5 s | `firstGhostUnderOneAndAHalfSeconds` (NexusAITests; runs when Apple Intelligence is ready) |
