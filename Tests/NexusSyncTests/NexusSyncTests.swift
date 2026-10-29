import CryptoKit
import Foundation
import NexusCore
import NexusFormat
import Testing

@testable import NexusSync

/// A Mac in a test: its library folder in memory, its own sync state on disk.
struct Replica {
    let name: String
    let folder = MemoryFolder()
    let engine: SyncEngine

    init(
        _ name: String, _ bucket: any SyncTransport, crypto: LibraryCrypto, state: URL? = nil, conditional: Bool = true
    ) {
        self.name = name
        engine = SyncEngine(
            transport: bucket, crypto: crypto, folder: folder,
            stateDirectory: state ?? Fixtures.temp(), options: .init(device: name, conditionalWrites: conditional))
    }

    /// A replica that shares this one's folder and state (the app relaunched).
    init(relaunching r: Replica, _ bucket: any SyncTransport, crypto: LibraryCrypto, state: URL) {
        name = r.name
        engine = SyncEngine(
            transport: bucket, crypto: crypto, folder: r.folder, stateDirectory: state,
            options: .init(device: r.name))
    }

    func model(_ path: String = "Plan.nexus") async throws -> DocumentModel {
        try NexusPackage.read(files: try #require(try await folder.read(path)))
    }

    func edit(_ path: String = "Plan.nexus", _ body: (inout DocumentModel) throws -> Void) async throws {
        var m = try await model(path)
        try body(&m)
        try await folder.write(path, NexusPackage.files(for: m))
    }

    func editCanvas(_ path: String = "Plan.nexus", _ c: CanvasID = "c1", _ body: (inout CanvasEditor) throws -> Void)
        async throws
    {
        try await edit(path) { m in
            var e = CanvasEditor(m.canvases[c]!)
            try body(&e)
            m.canvases[c] = e.canvas
        }
    }

    @discardableResult func sync() async throws -> SyncReport { try await engine.sync() }
}

/// A bucket that runs something just before the next head write (a race, on cue).
actor Hooked: SyncTransport {
    let bucket: MemoryBucket
    var hook: (@Sendable () async -> Void)?
    init(_ bucket: MemoryBucket) { self.bucket = bucket }
    func beforeHeadWrite(_ f: @escaping @Sendable () async -> Void) { hook = f }

    func get(_ key: String, ifNoneMatch: String?) async throws -> SyncGet {
        try await bucket.get(key, ifNoneMatch: ifNoneMatch)
    }
    func put(_ key: String, _ data: Data, condition: SyncCondition) async throws -> SyncPut {
        if key.hasSuffix("/head.json"), let h = hook {
            hook = nil
            await h()
        }
        return try await bucket.put(key, data, condition: condition)
    }
    func delete(_ key: String) async throws { try await bucket.delete(key) }
    func list(_ prefix: String) async throws -> [String] { try await bucket.list(prefix) }
}

enum Fixtures {
    static func temp() -> URL {
        let u = FileManager.default.temporaryDirectory.appending(path: "nexus-sync-tests/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// "Launch plan": Pricing (Free, Pro), Channels (Newsletter), Risks (Churn).
    static func plan(id: String = "doc-1") -> DocumentModel {
        var c = Canvas(id: "c1", title: "Launch plan", rootText: "Launch plan")
        var undo = UndoStack()
        c.edit("Sample", undo: &undo) { e in
            for (m, subs) in [("Pricing", ["Free", "Pro"]), ("Channels", ["Newsletter"]), ("Risks", ["Churn"])] {
                let id = try! e.addChild(of: e.canvas.root, text: m)
                for s in subs { try! e.addChild(of: id, text: s) }
            }
        }
        var d = DocumentModel(canvases: [c])
        d.manifestExtra["documentID"] = .string(id)
        return d
    }

    static func texts(_ m: DocumentModel) -> Set<String> {
        Set(m.canvases.values.flatMap { $0.nodes.values.map(\.text) })
    }

    static func node(_ m: DocumentModel, _ text: String, _ c: CanvasID = "c1") -> NodeID {
        m.canvases[c]!.nodes.first { $0.value.text == text }!.key
    }
}

/// SplitMix64: the property test's random choices, the same for a seed every run.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 &+ 1 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Random edits on 2–3 Macs, synced in a random order, then everyone syncs until quiet.
/// Returns what to check: whether the copies are byte-identical, and what was lost that
/// no clash reported.
enum Convergence {
    struct Outcome {
        var identical: Bool
        var unexplained: Set<String>
        var clashes: Int
        /// Canvases kept whole because a merge wasn't a valid tree: none expected.
        var canvasClashes: Int
        var steps: Int
    }

    /// `conditional`: the bucket honours conditions (else each Mac reads its head writes back).
    static func run(
        seed: UInt64, bucket: any SyncTransport, crypto: LibraryCrypto, steps: Int = 30, conditional: Bool = true
    ) async throws -> Outcome {
        var rng = SeededRandom(seed)
        let replicas = (0..<(2 + Int(seed % 2))).map {
            Replica("Mac \($0)", bucket, crypto: crypto, conditional: conditional)
        }
        try await replicas[0].folder.write("Plan.nexus", NexusPackage.files(for: Fixtures.plan(id: "prop-\(seed)")))
        for r in replicas { try await r.sync() }

        var created = Fixtures.texts(Fixtures.plan())
        var gone = Set<String>()
        var clashTexts = Set<String>()
        // A topic deleted on one side and changed (or given subtopics) on the other: what
        // was under it goes with it when the deleting side wins.
        var deleteClashTexts = Set<String>()
        var parentText: [String: String] = [:]
        var renamed: [String: String] = [:]
        var clashes = 0
        var canvasClashes = 0
        // SYNC_TRACE=<seed> prints that seed's steps and merges, to debug a failing seed.
        let trace = ProcessInfo.processInfo.environment["SYNC_TRACE"] == "\(seed)"
        func note(_ report: SyncReport) {
            if trace {
                print(
                    "   sync:",
                    report.items.map {
                        "\($0.change) \($0.clashes.map { "\($0.kind) \($0.node?.rawValue ?? "") b=\($0.base ?? "-") m=\($0.mine ?? "-") t=\($0.theirs ?? "-")" })"
                    })
            }
            for c in report.clashes {
                clashes += 1
                if c.kind == .canvas { canvasClashes += 1 }
                clashTexts.formUnion([c.base, c.mine, c.theirs].compactMap { $0 })
                if c.kind == .topic, c.mine == nil || c.theirs == nil {
                    deleteClashTexts.formUnion([c.base, c.mine, c.theirs].compactMap { $0 })
                }
            }
        }

        for step in 0..<steps {
            let r = replicas[Int.random(in: 0..<replicas.count, using: &rng)]
            let text = "\(r.name)·\(step)"
            let roll = Int.random(in: 0..<10, using: &rng)
            if roll < 2 {
                // Two Macs at once: their head writes race.
                let other = replicas.first { $0.name != r.name }!
                if trace { print("\(step) \(r.name) and \(other.name) sync together") }
                async let x = r.sync()
                async let y = other.sync()
                let (rx, ry) = try await (x, y)
                note(rx)
                note(ry)
                continue
            }
            if roll < 4 {
                if trace { print("\(step) \(r.name) sync") }
                note(try await r.sync())
                continue
            }
            let op = Int.random(in: 0..<20, using: &rng)
            try await r.edit { m in
                if op == 0 {
                    m.add([Canvas(id: "x", title: text, rootText: text)])
                    created.insert(text)
                    return
                }
                let cid = m.canvasOrder[Int.random(in: 0..<m.canvasOrder.count, using: &rng)]
                var e = CanvasEditor(m.canvases[cid]!)
                let ids = e.canvas.nodes.keys.sorted { $0.rawValue < $1.rawValue }
                let pick = ids[Int.random(in: 0..<ids.count, using: &rng)]
                switch op {
                case 1..<11:
                    _ = try e.addChild(of: pick, text: text)
                    created.insert(text)
                    parentText[text] = e.canvas.nodes[pick]!.text
                case 11..<16 where pick != e.canvas.root:
                    let old = e.canvas.nodes[pick]!.text
                    gone.insert(old)
                    renamed[old] = text
                    e.setText(pick, text)
                    created.insert(text)
                default:
                    let leaves = ids.filter { $0 != e.canvas.root && e.canvas.nodes[$0]!.children.isEmpty }
                    guard let leaf = leaves.first else { break }
                    gone.insert(e.canvas.nodes[leaf]!.text)
                    _ = try e.delete([leaf])
                }
                m.canvases[cid] = e.canvas
                if trace {
                    print(
                        "\(step) \(r.name) op \(op) on \(cid)/\(pick.rawValue) “\(m.canvases[cid]?.nodes[pick]?.text ?? "?")”"
                    )
                    let c = e.canvas
                    func dump(_ n: NodeID, _ d: Int) {
                        print(String(repeating: "  ", count: d + 2) + "\(n.rawValue) \(c.nodes[n]!.text)")
                        for k in c.nodes[n]!.children { dump(k, d + 1) }
                    }
                    dump(c.root, 0)
                }
            }
        }
        for _ in 0..<3 { for r in replicas { note(try await r.sync()) } }

        var copies: [[String: [String: Data]]] = []
        for r in replicas { copies.append(await r.folder.packages) }
        let final = Fixtures.texts(try NexusPackage.read(files: copies[0]["Plan.nexus"] ?? [:]))
        // Under a topic a delete clash removed (by its text then, or after renames)?
        func underDeleted(_ t: String, _ depth: Int = 0) -> Bool {
            guard depth < 64, let p = parentText[t] else { return false }
            var names = [p]
            while let n = renamed[names.last!], names.count < 64 { names.append(n) }
            return names.contains { deleteClashTexts.contains($0) } || underDeleted(p, depth + 1)
        }
        let lost = created.subtracting(gone).subtracting(final).subtracting(clashTexts).filter { !underDeleted($0) }
        return Outcome(
            identical: copies.allSatisfy { $0 == copies[0] } && copies[0].count == 1, unexplained: Set(lost),
            clashes: clashes, canvasClashes: canvasClashes, steps: steps)
    }
}

@Suite struct NexusSyncTests {
    let crypto = LibraryCrypto(key: Sealed.newKey())

    @Test func aDocumentReachesAnotherMac() async throws {
        let bucket = MemoryBucket()
        let a = Replica("A", bucket, crypto: crypto)
        let b = Replica("B", bucket, crypto: crypto)
        try await a.folder.write("Plans/Launch.nexus", NexusPackage.files(for: Fixtures.plan()))
        let pushed = try await a.sync()
        #expect(pushed.items.map(\.change) == [.pushed])
        let got = try await b.sync()
        #expect(got.items.map(\.change) == [.added] && got.written == ["Plans/Launch.nexus"])
        let (pa, pb) = (await a.folder.packages, await b.folder.packages)
        #expect(pa == pb)
        // Nothing to do the second time: only reads.
        await bucket.resetRequests()
        _ = try await a.sync()
        _ = try await b.sync()
        #expect(await bucket.requests.allSatisfy { $0.method == "GET" })
    }

    /// A1 (in memory; `scripts/test-sync.sh` runs it against MinIO).
    @Test(arguments: 0..<50) func randomEditsAndSyncOrderConverge(seed: Int) async throws {
        let o = try await Convergence.run(seed: UInt64(seed), bucket: MemoryBucket(), crypto: crypto)
        #expect(o.identical, "seed \(seed): the copies differ")
        #expect(o.unexplained.isEmpty, "seed \(seed): lost without a clash: \(o.unexplained.sorted())")
        #expect(o.canvasClashes == 0, "seed \(seed): a canvas kept whole")
    }

    /// The property test, longer and wider (`SYNC_SOAK=1`; `scripts/test-sync.sh` runs it).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SYNC_SOAK"] == "1"), arguments: 0..<20)
    func soak(batch: Int) async throws {
        for s in 0..<25 {
            let seed = UInt64(1_000 + batch * 25 + s)
            let o = try await Convergence.run(
                seed: seed, bucket: MemoryBucket(honoursConditions: s % 5 != 0), crypto: crypto, steps: 80,
                conditional: s % 5 != 0)
            #expect(o.identical && o.unexplained.isEmpty && o.canvasClashes == 0, "seed \(seed): \(o)")
        }
    }

    /// A2: the same topic changed on two Macs is one clash; Resolve offers each side.
    @Test func theSameTopicOnTwoMacsIsOneClash() async throws {
        let bucket = MemoryBucket()
        let a = Replica("A", bucket, crypto: crypto)
        let b = Replica("B", bucket, crypto: crypto)
        try await a.folder.write("Plan.nexus", NexusPackage.files(for: Fixtures.plan()))
        try await a.sync()
        try await b.sync()
        let pro = Fixtures.node(Fixtures.plan(), "Pro")
        try await a.editCanvas { $0.setText(pro, "Pro · $12") }
        try await b.editCanvas { $0.setText(pro, "Pro · $15") }
        try await a.sync()
        let report = try await b.sync()
        #expect(report.clashes.count == 1)
        #expect(report.items.map(\.change) == [.merged(clashes: 1)])
        // B kept its side, and pushed it.
        #expect(try await b.model().canvases["c1"]!.nodes[pro]!.text == "Pro · $15")
        try await a.sync()
        #expect(try await a.model().canvases["c1"]!.nodes[pro]!.text == "Pro · $15")

        let id = try #require(await b.engine.conflicts.keys.first)
        let pending = try #require(try await b.engine.conflict(id))
        let clash = try #require(pending.clashes.first)
        #expect(pending.clashes.count == 1 && clash.mine == "Pro · $15" && clash.theirs == "Pro · $12")
        #expect(pending.theirsDevice == "A")
        let theirs = pending.resolve([clash.id: .theirs]).model
        #expect(theirs.canvases["c1"]!.nodes[pro]!.text == "Pro · $12")
        let mine = pending.resolve([clash.id: .mine]).model
        #expect(mine.canvases["c1"]!.nodes[pro]!.text == "Pro · $15")
        let both = pending.resolve([clash.id: .both]).model
        #expect(both.canvases.count == 2 && both.canvases["c2"]!.nodes[pro]!.text == "Pro · $12")
        try await b.engine.clearConflict(id)
        #expect(await b.engine.conflicts.isEmpty)
    }

    /// A3: with encryption on, no object or name carries a topic; the recovery key opens
    /// the library on another Mac, and another key can't.
    @Test func encryptedLibrariesRevealNoTopicText() async throws {
        let marks = ["Zanzibar-pricing", "Quokka-channel", "Narwhal-risk"]
        var plan = Fixtures.plan()
        var e = CanvasEditor(plan.canvases["c1"]!)
        for m in marks { _ = try e.addChild(of: e.canvas.root, text: m) }
        plan.canvases["c1"] = e.canvas
        plan.assets["photo.png"] = Data("PNG Zanzibar-pricing".utf8)

        func leaks(_ bucket: MemoryBucket) async -> [String] {
            var out: [String] = []
            for k in await bucket.keys {
                let d = await bucket.data(k) ?? Data()
                for m in marks + ["Launch plan", "Plan.nexus"]
                where k.contains(m) || d.range(of: Data(m.utf8)) != nil {
                    out.append("\(k): \(m)")
                }
            }
            return out
        }

        let bucket = MemoryBucket()
        let a = Replica("A", bucket, crypto: crypto)
        try await a.folder.write("Plan.nexus", NexusPackage.files(for: plan))
        try await a.sync()
        #expect(await leaks(bucket).isEmpty)
        #expect(await bucket.keys.count >= 5)

        // The same library unencrypted does show them (so the check above can see a leak).
        let plain = MemoryBucket()
        let p = Replica("P", plain, crypto: .unencrypted)
        try await p.folder.write("Plan.nexus", NexusPackage.files(for: plan))
        try await p.sync()
        #expect(await !leaks(plain).isEmpty)

        // Another Mac with the recovery key syncs.
        let text = RecoveryKey.text(crypto.key!)
        let key = try #require(RecoveryKey.key(text.lowercased().replacingOccurrences(of: "-", with: " ")))
        let b = Replica("B", bucket, crypto: LibraryCrypto(key: key))
        try await b.sync()
        let (mb, ma) = (try await b.model(), try await a.model())
        #expect(mb == ma)

        // Without it, it can't.
        let c = Replica("C", bucket, crypto: LibraryCrypto(key: Sealed.newKey()))
        await #expect(throws: SyncError.wrongKey) { try await c.sync() }
        let d = Replica("D", bucket, crypto: .unencrypted)
        await #expect(throws: SyncError.encryptionMismatch(remoteEncrypted: true)) { try await d.sync() }
        let (pc, pd) = (await c.folder.packages, await d.folder.packages)
        #expect(pc.isEmpty && pd.isEmpty)
    }

    @Test func recoveryKeysRoundTripAndCatchTypos() throws {
        for _ in 0..<20 {
            let k = Sealed.newKey()
            let text = RecoveryKey.text(k)
            #expect(text.count == 55 + 10 && text.split(separator: "-").count == 11)
            #expect(RecoveryKey.key(text) == k)
            // I, L and O read as 1, 1 and 0.
            #expect(
                RecoveryKey.key(text.replacingOccurrences(of: "1", with: "l").replacingOccurrences(of: "0", with: "O"))
                    == k)
            var typo = Array(text)
            let i = typo.firstIndex { $0 != "-" }!
            typo[i] = typo[i] == "A" ? "B" : "A"
            #expect(RecoveryKey.key(String(typo)) == nil)
        }
        #expect(RecoveryKey.key("not a key") == nil)
    }

    /// A4: editing one canvas of a three-canvas document with images uploads that canvas's
    /// file and the head (and its history copy), nothing else.
    @Test func anEditUploadsOnlyThatCanvas() async throws {
        var doc = Fixtures.plan()
        doc.add([
            Canvas(id: "x", title: "Roadmap", rootText: "Roadmap"), Canvas(id: "y", title: "Team", rootText: "Team"),
        ])
        doc.assets["logo.png"] = Data(repeating: 7, count: 40_000)
        doc.assets["chart.png"] = Data(repeating: 9, count: 60_000)
        #expect(doc.canvases.count == 3)
        let bucket = MemoryBucket()
        let a = Replica("A", bucket, crypto: crypto)
        try await a.folder.write("Plan.nexus", NexusPackage.files(for: doc))
        try await a.sync()

        await bucket.resetRequests()
        try await a.editCanvas("Plan.nexus", "c2") { _ = try $0.addChild(of: $0.canvas.root, text: "Q3") }
        try await a.sync()
        let puts = await bucket.requests.filter { $0.method == "PUT" }
        let blobs = puts.filter { $0.key.contains("/blobs/") }
        #expect(blobs.count == 1, "\(puts.map(\.key))")
        #expect(puts.count == 3 && puts.map(\.key).filter { $0.hasSuffix("head.json") }.count == 1)
        #expect(blobs[0].bytes < 2_000, "only the canvas, not the images")
    }

    /// A5: a crash between the blob uploads and the head write loses nothing, and the
    /// next sync (after a relaunch) completes.
    @Test func aCrashBeforeTheHeadLosesNothing() async throws {
        let bucket = MemoryBucket()
        let state = Fixtures.temp()
        let a = Replica("A", bucket, crypto: crypto, state: state)
        let b = Replica("B", bucket, crypto: crypto)
        try await a.folder.write("Plan.nexus", NexusPackage.files(for: Fixtures.plan()))
        try await a.sync()
        try await b.sync()

        try await a.editCanvas { _ = try $0.addChild(of: $0.canvas.root, text: "Launch party") }
        await bucket.fail { $0.method == "PUT" && $0.key.hasSuffix("head.json") }
        await #expect(throws: SyncError.self) { try await a.sync() }
        #expect(await bucket.requests.contains { $0.key.contains("/blobs/") }, "the blobs went up first")
        await bucket.fail(when: nil)

        let relaunched = Replica(relaunching: a, bucket, crypto: crypto, state: state)
        let r = try await relaunched.sync()
        #expect(r.items.map(\.change) == [.pushed])
        try await b.sync()
        #expect(Fixtures.texts(try await b.model()).contains("Launch party"))
        let (pa, pb) = (await a.folder.packages, await b.folder.packages)
        #expect(pa == pb)
    }

    /// A6: a delete reaches the other Macs (their copy goes to the Trash); Restore brings it
    /// back everywhere; after the days to keep, the library's copy is purged.
    @Test func deletesReachOtherMacsAndRestoreBringsThemBack() async throws {
        let bucket = MemoryBucket()
        let a = Replica("A", bucket, crypto: crypto)
        let b = Replica("B", bucket, crypto: crypto)
        try await a.folder.write("Plan.nexus", NexusPackage.files(for: Fixtures.plan()))
        try await a.folder.write("Other.nexus", NexusPackage.files(for: Fixtures.plan(id: "doc-2")))
        try await a.sync()
        try await b.sync()

        await a.folder.set("Plan.nexus", nil)
        #expect(try await a.sync().items.map(\.change) == [.deleted])
        #expect(try await b.sync().items.map(\.change) == [.trashed])
        #expect(await b.folder.trashed == ["Plan.nexus"])
        let deleted = try await b.engine.deletedDocuments()
        #expect(deleted.map(\.path) == ["Plan.nexus"] && deleted[0].device == "A")

        try await b.engine.restore("doc-1")
        #expect(try await b.model() == Fixtures.plan())
        try await a.sync()
        let (pa, pb) = (await a.folder.packages, await b.folder.packages)
        #expect(pa == pb)
        #expect(try await a.engine.deletedDocuments().isEmpty)

        // Deleted 31 days ago: purged.
        await a.folder.set("Other.nexus", nil)
        try await a.sync()
        #expect(await bucket.keys.contains { $0.hasPrefix("docs/doc-2/") })
        var later = await a.engine.options
        later.now = { Date().addingTimeInterval(31 * 86_400) }
        await a.engine.setOptions(later)
        #expect(try await a.sync().items.map(\.change) == [.purged])
        #expect(await !bucket.keys.contains { $0.hasPrefix("docs/doc-2/") })
        #expect(await bucket.keys.contains { $0.hasPrefix("docs/doc-1/") })
    }

    @Test func aDeleteHereAndAnEditThereKeepsTheEdit() async throws {
        let bucket = MemoryBucket()
        let a = Replica("A", bucket, crypto: crypto)
        let b = Replica("B", bucket, crypto: crypto)
        try await a.folder.write("Plan.nexus", NexusPackage.files(for: Fixtures.plan()))
        try await a.sync()
        try await b.sync()
        try await b.editCanvas { _ = try $0.addChild(of: $0.canvas.root, text: "Keep me") }
        await a.folder.set("Plan.nexus", nil)
        try await b.sync()
        #expect(try await a.sync().items.map(\.change) == [.kept])
        #expect(Fixtures.texts(try await a.model()).contains("Keep me"))
        // And when the delete lands first, the edit brings it back.
        await a.folder.set("Plan.nexus", nil)
        try await a.sync()
        try await b.editCanvas { _ = try $0.addChild(of: $0.canvas.root, text: "Me too") }
        #expect(try await b.sync().items.map(\.change).contains(.kept))
        try await a.sync()
        #expect(Fixtures.texts(try await a.model()).isSuperset(of: ["Keep me", "Me too"]))
    }

    /// A save that lands while sync downloads and merges isn't overwritten: sync writes only
    /// over what it read, and the next sync starts from the save.
    @Test func aSaveDuringSyncIsNotOverwritten() async throws {
        let bucket = MemoryBucket()
        let a = Replica("A", bucket, crypto: crypto)
        let b = Replica("B", bucket, crypto: crypto)
        try await a.folder.write("Plan.nexus", NexusPackage.files(for: Fixtures.plan()))
        try await a.sync()
        try await b.sync()
        try await b.editCanvas { _ = try $0.addChild(of: $0.canvas.root, text: "From B") }
        try await b.sync()
        try await a.editCanvas { _ = try $0.addChild(of: $0.canvas.root, text: "From A") }
        await a.folder.saveBeforeNextWrite(to: "Plan.nexus") { files in
            var doc = try! NexusPackage.read(files: files)
            var e = CanvasEditor(doc.canvases["c1"]!)
            _ = try! e.addChild(of: e.canvas.root, text: "Saved meanwhile")
            doc.canvases["c1"] = e.canvas
            return NexusPackage.files(for: doc)
        }
        let first = try await a.sync()
        #expect(first.written.isEmpty && first.errors.isEmpty)
        #expect(Fixtures.texts(try await a.model()).isSuperset(of: ["From A", "Saved meanwhile"]))
        try await a.sync()
        try await b.sync()
        for r in [a, b] {
            #expect(Fixtures.texts(try await r.model()).isSuperset(of: ["From A", "From B", "Saved meanwhile"]))
        }
        let (pa, pb) = (await a.folder.packages, await b.folder.packages)
        #expect(pa == pb)
    }

    @Test func historyListsRevisionsNewestFirst() async throws {
        let bucket = MemoryBucket()
        let a = Replica("A", bucket, crypto: crypto)
        try await a.folder.write("Plan.nexus", NexusPackage.files(for: Fixtures.plan()))
        try await a.sync()
        for t in ["One", "Two"] {
            try await a.editCanvas { _ = try $0.addChild(of: $0.canvas.root, text: t) }
            try await a.sync()
        }
        let h = try await a.engine.history("doc-1")
        #expect(h.count == 3 && h.allSatisfy { $0.device == "A" })
        #expect(h[0].parents == [h[1].revision] && h[2].parents.isEmpty)
        let first = try NexusPackage.read(files: try await a.engine.files("doc-1", h[2]))
        #expect(first == Fixtures.plan())
    }

    /// Providers that ignore `If-Match`: each head write is read back instead.
    @Test(arguments: 0..<10) func bucketsWithoutConditionsStillConverge(seed: Int) async throws {
        let bucket = MemoryBucket(honoursConditions: false)
        let o = try await Convergence.run(seed: UInt64(seed + 100), bucket: bucket, crypto: crypto, conditional: false)
        #expect(o.identical && o.unexplained.isEmpty && o.canvasClashes == 0, "seed \(seed): \(o)")
    }

    /// The race a provider without conditional writes allows: another Mac's head write
    /// lands between this Mac's check and its write, and this Mac overwrites it. The Mac
    /// whose revision was overwritten notices at its next sync and merges it back in.
    @Test func anOverwrittenRevisionIsMergedBackIn() async throws {
        let bucket = MemoryBucket(honoursConditions: false)
        let hooked = Hooked(bucket)
        let a = Replica("A", hooked, crypto: crypto, conditional: false)
        let b = Replica("B", bucket, crypto: crypto, conditional: false)
        try await a.folder.write("Plan.nexus", NexusPackage.files(for: Fixtures.plan()))
        try await a.sync()
        try await b.sync()
        try await a.editCanvas { _ = try $0.addChild(of: $0.canvas.root, text: "From A") }
        try await b.editCanvas { _ = try $0.addChild(of: $0.canvas.root, text: "From B") }
        // B's whole sync runs just before A's head write.
        await hooked.beforeHeadWrite { _ = try? await b.sync() }
        try await a.sync()
        #expect(try await b.engine.history("doc-1").first?.device == "A", "A overwrote B's revision")
        try await b.sync()
        try await a.sync()
        for r in [a, b] { #expect(Fixtures.texts(try await r.model()).isSuperset(of: ["From A", "From B"])) }
        let (pa, pb) = (await a.folder.packages, await b.folder.packages)
        #expect(pa == pb)
    }

    /// A package copied in Finder has the same id as its original: the copy gets its own.
    @Test func aFinderDuplicateGetsItsOwnID() async throws {
        let bucket = MemoryBucket()
        let a = Replica("A", bucket, crypto: crypto)
        let b = Replica("B", bucket, crypto: crypto)
        let files = NexusPackage.files(for: Fixtures.plan())
        try await a.folder.write("Plan.nexus", files)
        try await a.sync()
        try await a.folder.write("Plan copy.nexus", files)
        try await a.sync()
        let copyID = SyncFiles.documentID(try #require(try await a.folder.read("Plan copy.nexus")))
        #expect(copyID != nil && copyID != "doc-1")
        try await b.sync()
        #expect(await b.folder.packages.keys.sorted() == ["Plan copy.nexus", "Plan.nexus"])
    }

    /// Documents without an id (made before M45) get one, written into their manifest.
    @Test func documentsWithoutAnIDGetOne() async throws {
        var doc = Fixtures.plan()
        doc.manifestExtra = [:]
        let a = Replica("A", MemoryBucket(), crypto: crypto)
        try await a.folder.write("Old.nexus", NexusPackage.files(for: doc))
        let r = try await a.sync()
        #expect(r.written == ["Old.nexus"])
        #expect(SyncFiles.documentID(try #require(try await a.folder.read("Old.nexus"))) != nil)
    }

    @Test func aRenameOnOneMacMovesItOnTheOthers() async throws {
        let bucket = MemoryBucket()
        let a = Replica("A", bucket, crypto: crypto)
        let b = Replica("B", bucket, crypto: crypto)
        try await a.folder.write("Plan.nexus", NexusPackage.files(for: Fixtures.plan()))
        try await a.sync()
        try await b.sync()
        try await a.folder.move("Plan.nexus", to: "Archive/Launch.nexus")
        try await a.sync()
        try await b.sync()
        #expect(await b.folder.packages.keys.sorted() == ["Archive/Launch.nexus"])
    }

    @Test func diskFoldersSkipWhatTheAppDerives() async throws {
        let root = Fixtures.temp()
        let folder = DiskFolder(root)
        var files = NexusPackage.files(for: Fixtures.plan())
        files["preview.png"] = Data([1, 2, 3])
        files["render/viewer.json"] = Data("{}".utf8)
        try await folder.write("Sub/Plan.nexus", files)
        #expect(try await folder.documents() == ["Sub/Plan.nexus"])
        let read = try #require(try await folder.read("Sub/Plan.nexus"))
        #expect(read == NexusPackage.files(for: Fixtures.plan()))
        try await folder.move("Sub/Plan.nexus", to: "Plan.nexus")
        #expect(try await folder.documents() == ["Plan.nexus"])
        // Sync writes only over what it read.
        let stale = NexusPackage.files(for: Fixtures.plan(id: "other"))
        await #expect(throws: SyncError.changedHere) { try await folder.write("Plan.nexus", stale, replacing: stale) }
        await #expect(throws: SyncError.changedHere) { try await folder.trash("Plan.nexus", replacing: stale) }
        try await folder.write("Plan.nexus", stale, replacing: read)
        #expect(try await folder.read("Plan.nexus") == stale)
    }
}
