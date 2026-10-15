import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusInterchange

/// M10: the file loader never crashes or hangs. Every damaged file either fails to open
/// with an error, or opens as a valid document that lays out and renders.
@MainActor
@Suite(.serialized) struct LoaderFuzzTests {
    /// SplitMix64: seeded, so every failure reproduces.
    struct RNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D1_049B_B133_11EB
            return z ^ (z >> 31)
        }
    }

    static let base = NexusPackage.files(for: richDocument())

    /// A document with every element kind, so mutations reach them all.
    static func richDocument() -> DocumentModel {
        var doc = launchPlanDocument()
        var c = doc.canvases["c1"]!
        var e = CanvasEditor(c)
        let kids = c.nodes[c.root]!.children
        _ = try? e.addBoundary(around: [kids[0]], title: "Group")
        _ = try? e.addSummary(over: Array(c.nodes[kids[1]]!.children.prefix(2)), text: "Summary")
        _ = try? e.addCallout(on: kids[2], text: "Callout")
        c = e.canvas
        doc.canvases["c1"] = c
        return doc
    }

    /// Opening a file the way the app does: read, then lay out and draw a scene.
    func open(_ files: [String: Data]) -> DocumentModel? {
        guard let doc = try? NexusPackage.read(files: files) else { return nil }
        for c in doc.orderedCanvases {
            #expect(c.validate().isEmpty, "loaded an invalid canvas: \(c.validate().prefix(3))")
            var n = 0
            for top in c.tops { c.walk(from: top) { _, _, _ in n += 1 } }
            #expect(n == c.nodes.count, "walk visits every topic once")
        }
        let controller = CanvasController(store: DocumentStore(model: doc))
        controller.prefs = .isolated()
        for id in doc.canvasOrder {
            controller.switchCanvas(to: id)
            #expect(controller.scene.nodes.count <= doc.canvases[id]!.nodes.count + 64)
        }
        return doc
    }

    // MARK: Byte damage

    @Test func bitFlipsTruncationAndGarbage() {
        var rng = RNG(state: 0x0E4E_C5)
        let paths = Self.base.keys.filter { $0.hasSuffix(".json") }.sorted()
        var opened = 0
        for i in 0..<1_500 {
            var files = Self.base
            let p = paths[Int.random(in: 0..<paths.count, using: &rng)]
            var d = files[p]!
            switch i % 3 {
            case 0:
                for _ in 0..<Int.random(in: 1...8, using: &rng) where !d.isEmpty {
                    let at = Int.random(in: 0..<d.count, using: &rng)
                    d[at] ^= UInt8(1 << Int.random(in: 0..<8, using: &rng))
                }
            case 1: d = d.prefix(Int.random(in: 0..<max(d.count, 1), using: &rng))
            default:
                d = Data((0..<Int.random(in: 0..<200, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            }
            files[p] = d
            if open(files) != nil { opened += 1 }
        }
        #expect(opened > 0, "some flips land in strings and still open")
    }

    // MARK: Structural damage

    static func randomValue(_ rng: inout RNG) -> JSONValue {
        switch Int.random(in: 0..<9, using: &rng) {
        case 0: return .null
        case 1: return .bool(Bool.random(using: &rng))
        case 2: return .number([0, -1, 1e308, -1e308, 2_147_483_648, 0.5, 1e-300][Int.random(in: 0..<7, using: &rng)])
        case 3: return .string("")
        case 4: return .string(String(repeating: "x", count: Int.random(in: 1...20_000, using: &rng)))
        case 5:
            return .string(["n1", "n2", "n3", "c1", "../x", "\u{0}", "🧭", "nope"][Int.random(in: 0..<8, using: &rng)])
        case 6: return .array([.string("n1"), .string("n1"), .string("n2")])
        case 7: return .object(["id": .string("n1")])
        default:
            var v = JSONValue.array([])
            for _ in 0..<Int.random(in: 1...300, using: &rng) { v = .array([v]) }
            return v
        }
    }

    /// Every path into a JSON value (object keys and array indices).
    static func paths(_ v: JSONValue, _ prefix: [String] = []) -> [[String]] {
        switch v {
        case .object(let o): return [prefix] + o.flatMap { paths($0.value, prefix + [$0.key]) }
        case .array(let a): return [prefix] + a.enumerated().flatMap { paths($0.element, prefix + ["#\($0.offset)"]) }
        default: return [prefix]
        }
    }

    static func mutate(_ v: JSONValue, at path: ArraySlice<String>, _ f: (JSONValue?) -> JSONValue?) -> JSONValue? {
        guard let head = path.first else { return f(v) }
        switch v {
        case .object(var o):
            o[head] = o[head].flatMap { mutate($0, at: path.dropFirst(), f) }
            return .object(o)
        case .array(var a):
            guard head.hasPrefix("#"), let i = Int(head.dropFirst()), a.indices.contains(i) else { return v }
            if let n = mutate(a[i], at: path.dropFirst(), f) { a[i] = n } else { a.remove(at: i) }
            return .array(a)
        default: return v
        }
    }

    @Test func structuralMutations() throws {
        var rng = RNG(state: 0xF00D)
        let canvasPaths = Self.base.keys.filter { $0.hasPrefix("canvases/") || $0 == "manifest.json" }.sorted()
        var opened = 0
        var repaired = 0
        for _ in 0..<2_500 {
            var files = Self.base
            let p = canvasPaths[Int.random(in: 0..<canvasPaths.count, using: &rng)]
            var json = try CanonicalJSON.parse(files[p]!)
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                let all = Self.paths(json)
                let path = all[Int.random(in: 0..<all.count, using: &rng)]
                let op = Int.random(in: 0..<3, using: &rng)
                let replacement = Self.randomValue(&rng)
                json = Self.mutate(json, at: path[...]) { _ in op == 0 ? nil : replacement } ?? json
            }
            files[p] = CanonicalJSON.data(json)
            if let doc = open(files) {
                opened += 1
                if !doc.repairs.isEmpty { repaired += 1 }
            }
        }
        #expect(opened > 100 && repaired > 0, "opened \(opened), repaired \(repaired)")
    }

    // MARK: Targeted cases

    func withCanvas(_ body: (inout [String: JSONValue]) -> Void) throws -> [String: Data] {
        var files = Self.base
        guard case .object(var c) = try CanonicalJSON.parse(files["canvases/c1.json"]!) else { return files }
        body(&c)
        files["canvases/c1.json"] = CanonicalJSON.data(.object(c))
        return files
    }

    func setChildren(_ c: inout [String: JSONValue], _ id: String, _ kids: [String]) {
        guard case .object(var nodes)? = c["nodes"], case .object(var n)? = nodes[id] else { return }
        n["children"] = .array(kids.map { .string($0) })
        nodes[id] = .object(n)
        c["nodes"] = .object(nodes)
    }

    @Test func cyclesSecondParentsAndOrphansAreRepaired() throws {
        let c1 = Self.richDocument().canvases["c1"]!
        let root = c1.root.rawValue
        let first = c1.nodes[c1.root]!.children[0].rawValue
        let grand = c1.nodes[c1.nodes[c1.root]!.children[0]]!.children.first?.rawValue ?? first
        let cases: [(String, (inout [String: JSONValue]) -> Void)] = [
            ("root is its own child", { self.setChildren(&$0, root, [root, first]) }),
            ("a child lists an ancestor", { self.setChildren(&$0, grand, [root, first]) }),
            ("a topic lists itself", { self.setChildren(&$0, first, [first]) }),
            ("two parents", { self.setChildren(&$0, root, c1.nodes[c1.root]!.children.map(\.rawValue) + [grand]) }),
            ("missing child", { self.setChildren(&$0, first, ["ghost"]) }),
            ("orphaned branch", { self.setChildren(&$0, root, []) }),
            (
                "pure cycle off the tree",
                {
                    self.setChildren(&$0, root, [])
                    self.setChildren(&$0, first, [grand])
                    self.setChildren(&$0, grand, [first])
                }
            ),
        ]
        for (name, body) in cases {
            let doc = try #require(open(try withCanvas(body)), "\(name) didn't open")
            let c = doc.canvases["c1"]!
            #expect(!doc.repairs.isEmpty, "\(name) reported no repair")
            #expect(c.nodes.count == c1.nodes.count, "\(name) lost topics")
        }
        // The CLI says so.
        let issues = try withCanvas { self.setChildren(&$0, root, [root, first]) }
        #expect((try? NexusPackage.read(files: issues))?.repairs.first?.hasPrefix("canvases/c1.json") == true)
    }

    @Test func deepChainsAndHugeDocumentsDoNotCrash() throws {
        // 3,000 levels deep: deeper than any real map, shallower than the main thread's stack.
        // Built directly (the editor refuses to nest past Canvas.maxDepth), as a damaged
        // or generated file might be.
        var c = Canvas(id: "c1", title: "Deep", rootText: "Root")
        var cur = c.root
        for i in 0..<3_000 {
            let id = NodeID("d\(i)")
            c.nodes[id] = Node(text: "L\(i)")
            c.nodes[cur]!.children = [id]
            cur = id
        }
        let files = NexusPackage.files(for: DocumentModel(canvases: [c]))
        let doc = try #require(open(files), "a 3,000-level chain opens, lays out and renders")
        #expect(doc.canvases["c1"]!.nodes.count == 3_001, "nothing is lost")
        #expect(doc.repairs.contains { $0.contains("nested over 256 levels") })
        let deep = doc.canvases["c1"]!
        var depths: [NodeID: Int] = [:]
        for top in deep.tops { deep.walk(from: top) { id, _, d in depths[id] = d } }
        #expect(depths.values.allSatisfy { $0 < Canvas.maxDepth })
        // The editor refuses to go deeper than the limit.
        var e = CanvasEditor(deep)
        let deepest = depths.max { $0.value < $1.value }!.key
        #expect(throws: TreeOperationRefusal.tooDeep) { try e.addChild(of: deepest) }
        // Text marks past the end of the title.
        var marked = Self.richDocument()
        let pro = marked.canvases["c1"]!.nodes.first { $0.value.text == "Pro" }!.key
        marked.canvases["c1"]!.nodes[pro]!.marks = [
            TextMark(start: 2, length: 9_000, bold: true), TextMark(start: 9_000_000, length: 3, italic: true),
        ]
        #expect(open(NexusPackage.files(for: marked)) != nil)
        // Duplicate canvases in the manifest, and a manifest that lists none.
        var dup = Self.base
        dup["manifest.json"] = Data(
            String(decoding: dup["manifest.json"]!, as: UTF8.self).replacingOccurrences(
                of: "\"c1\",", with: "\"c1\",\n    \"c1\",", options: [], range: nil
            ).utf8)
        #expect(open(dup) == nil || open(dup)?.canvasOrder.count == Set(open(dup)!.canvasOrder).count)
    }

    @Test func otherLoadersSurviveGarbage() {
        var rng = RNG(state: 0xBADF00D)
        let zip = { () -> Data in
            var z = ZipWriter()
            for (k, v) in Self.base.sorted(by: { $0.key < $1.key }) { z.add(k, v) }
            return z.finish()
        }()
        let json = Data(DocumentJSON.export(Self.richDocument(), pretty: false).utf8)
        let key = PackageCrypto.derive(password: "pw", info: PackageCrypto.newInfo(hint: nil))
        let sealed = (try? PackageCrypto.encrypt(Self.base, with: key)) ?? [:]
        for i in 0..<1_200 {
            func damage(_ d: Data) -> Data {
                var d = d
                if i % 2 == 0 {
                    for _ in 0..<Int.random(in: 1...16, using: &rng) where !d.isEmpty {
                        d[Int.random(in: 0..<d.count, using: &rng)] = UInt8.random(in: 0...255, using: &rng)
                    }
                } else {
                    d = d.prefix(Int.random(in: 0..<max(d.count, 1), using: &rng))
                }
                return d
            }
            if let files = try? Zip.read(damage(zip)) { _ = try? NexusPackage.read(files: files) }
            if let doc = try? DocumentJSON.parse(damage(json), name: "x.nexusjson") {
                for c in doc.orderedCanvases { #expect(c.validate().isEmpty) }
            }
            var s = sealed
            if let k = s.keys.sorted().randomElement(using: &rng) { s[k] = damage(s[k]!) }
            _ = try? PackageCrypto.decrypt(s, with: key)
            _ = try? CanonicalJSON.parse(damage(json))
        }
    }
}
