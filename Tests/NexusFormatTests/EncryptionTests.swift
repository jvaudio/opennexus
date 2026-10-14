import Foundation
import Testing

@testable import NexusCore
@testable import NexusFormat

@Suite struct EncryptionTests {
    @Test func roundTripWrongPasswordAndNoPlaintext() throws {
        var doc = launchPlanDocument()
        doc.assets["abc.png"] = Data("PNGDATA-secret".utf8)
        let files = NexusPackage.files(for: doc)
        let key = PackageCrypto.derive(password: "correct horse", info: PackageCrypto.newInfo(hint: "the battery one"))
        let sealed = try PackageCrypto.encrypt(files, with: key)
        #expect(Set(sealed.keys) == ["manifest.json", "encrypted.bin"])
        #expect(PackageCrypto.isEncrypted(sealed))
        #expect(PackageCrypto.info(sealed)?.hint == "the battery one", "the hint is readable without the password")
        #expect(SchemaValidator.bundled.validate(package: sealed).isEmpty, "the outer manifest is schema-valid")
        let all = sealed.values.reduce(Data(), +)
        for secret in ["Pricing", "Launch plan", "Competitor", "PNGDATA"] {
            #expect(all.range(of: Data(secret.utf8)) == nil, "\(secret) must not appear in the encrypted package")
        }
        #expect(throws: PackageCrypto.CryptoError.wrongPassword) {
            try PackageCrypto.decrypt(sealed, password: "wrong")
        }
        let opened = try PackageCrypto.decrypt(sealed, password: "correct horse")
        #expect(opened == files)
        #expect(try NexusPackage.read(files: opened).orderedCanvases == doc.orderedCanvases)
    }

    @Test func snapshotsWritePruneAndRestore() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "nexus-snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let files = NexusPackage.files(for: launchPlanDocument())
        for i in 0..<23 {
            try SnapshotStore.write(
                files, documentID: "doc1", topics: 16 + i,
                date: Date(timeIntervalSince1970: 1_800_000_000 + Double(i) * 300), base: base)
        }
        let list = SnapshotStore.list(documentID: "doc1", base: base)
        #expect(list.count == SnapshotStore.keep)
        #expect(list.first!.topics == 38 && list.first!.date > list.last!.date, "newest first")
        #expect(try SnapshotStore.read(list[0]) == files)
        // Encrypted documents keep encrypted snapshots.
        let key = PackageCrypto.derive(password: "pw12", info: PackageCrypto.newInfo(hint: nil))
        let url = try SnapshotStore.write(files, documentID: "doc2", topics: 16, key: key, base: base)
        let raw = try Data(contentsOf: url)
        #expect(raw.range(of: Data("Pricing".utf8)) == nil)
        let s = SnapshotStore.list(documentID: "doc2", base: base)[0]
        #expect(s.encrypted)
        #expect(try SnapshotStore.read(s, key: key) == files)
        #expect(throws: PackageCrypto.CryptoError.self) { try SnapshotStore.read(s) }
    }

    /// Settings › Files & Backup: usage, the most recent document, keep-for and delete all.
    @Test func snapshotHousekeeping() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "nexus-snap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let files = NexusPackage.files(for: launchPlanDocument())
        let now = Date()
        try SnapshotStore.write(
            files, documentID: "old", topics: 10, date: now.addingTimeInterval(-40 * 86_400), base: base)
        try SnapshotStore.write(
            files, documentID: "old", topics: 11, date: now.addingTimeInterval(-2 * 86_400), base: base)
        try SnapshotStore.write(files, documentID: "new", topics: 12, date: now.addingTimeInterval(-60), base: base)
        #expect(SnapshotStore.usage(base: base) > 0)
        #expect(SnapshotStore.allRecent(base: base).map(\.topics) == [12])
        SnapshotStore.prune(olderThan: 30, base: base)
        #expect(SnapshotStore.list(documentID: "old", base: base).map(\.topics) == [11])
        SnapshotStore.deleteAll(base: base)
        #expect(SnapshotStore.usage(base: base) == 0 && SnapshotStore.allRecent(base: base).isEmpty)
    }
}
