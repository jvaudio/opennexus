import CryptoKit
import Foundation
import Testing

@testable import NexusCore
@testable import NexusFormat

/// M44: the sealed envelope and the share link's fragment.
@Suite struct SealedTests {
    static let bundle: JSONValue = .object([
        "format": "opennexus-viewer", "version": 1, "title": "Launch plan",
        "canvases": .array([.object(["id": "c1", "title": "Pricing tiers"])]),
    ])

    static let created = Date(timeIntervalSince1970: 1_793_000_000)

    @Test func roundTrips() throws {
        let key = Sealed.newKey()
        let sealed = try Sealed.seal(bundle: Self.bundle, header: Sealed.Header(created: Self.created), key: key)
        let (header, bundle) = try Sealed.openBundle(sealed, key: key)
        #expect(bundle == Self.bundle)
        #expect(header == Sealed.Header(created: Self.created))
        #expect(header.created == "2026-10-26T07:33:20Z")
        #expect(Array(sealed.prefix(4)) == Array("ONX1".utf8))
    }

    /// The header can be read without the key (it says whether a password is needed), and
    /// it holds nothing from the map.
    @Test func theHeaderIsReadableAndHoldsNoContent() throws {
        let expires = Self.created.addingTimeInterval(86_400)
        let kdf = Sealed.KDF.random()
        let h = Sealed.Header(created: Self.created, expires: expires, kdf: kdf)
        let sealed = try Sealed.seal(bundle: Self.bundle, header: h, key: Sealed.newKey())
        let read = try Sealed.header(of: sealed)
        #expect(read == h && read.kdf?.iterations == 600_000 && read.kdf?.salt.count == 16)
        #expect(read.expiryDate == Date(timeIntervalSince1970: 1_793_086_400))
        let text = String(decoding: sealed, as: UTF8.self)
        for s in ["Launch plan", "Pricing tiers", "opennexus-viewer"] { #expect(!text.contains(s)) }
    }

    /// A wrong key and any altered byte fail the same way.
    @Test func aWrongKeyOrAlteredByteIsDamaged() throws {
        let key = Sealed.newKey()
        let sealed = try Sealed.seal(bundle: Self.bundle, header: Sealed.Header(created: Self.created), key: key)
        #expect(throws: Sealed.SealError.damaged) { try Sealed.openBundle(sealed, key: Sealed.newKey()) }
        let headerEnd = 8 + Int(sealed[7])
        for i in [0, 5, 8, headerEnd - 2, headerEnd, headerEnd + 12, sealed.count / 2, sealed.count - 1] {
            var d = sealed
            d[i] ^= 0x01
            #expect(throws: (any Error).self, "byte \(i)") { try Sealed.openBundle(d, key: key) }
        }
        for n in [0, 4, 8, headerEnd + 11, sealed.count - 1] {
            #expect(throws: Sealed.SealError.damaged) { try Sealed.openBundle(sealed.prefix(n), key: key) }
        }
    }

    /// A newer envelope or bundle says so instead of "damaged".
    @Test func newerVersionsSaySo() throws {
        let key = Sealed.newKey()
        var h = Sealed.Header(created: Self.created)
        h.bundle = 2
        let newerBundle = try Sealed.seal(bundle: Self.bundle, header: h, key: key)
        #expect(throws: Sealed.SealError.newer(2)) { try Sealed.openBundle(newerBundle, key: key) }
        h = Sealed.Header(created: Self.created)
        h.version = 3
        let newerEnvelope = try Sealed.seal(Data("x".utf8), header: h, key: key)
        #expect(throws: Sealed.SealError.newer(3)) { try Sealed.header(of: newerEnvelope) }
    }

    /// PBKDF2-HMAC-SHA256's published vectors, and a password that opens what it sealed.
    @Test func passwords() throws {
        func hex(_ k: SymmetricKey) -> String {
            k.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        }
        let salt = Data("salt".utf8)
        #expect(
            hex(Sealed.key(password: "password", kdf: .init(iterations: 1, salt: salt)))
                == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
        #expect(
            hex(Sealed.key(password: "password", kdf: .init(iterations: 4096, salt: salt)))
                == "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a")
        let kdf = Sealed.KDF(iterations: 1000, salt: Sealed.randomBytes(16))
        let sealed = try Sealed.seal(
            bundle: Self.bundle, header: Sealed.Header(created: Self.created, kdf: kdf),
            key: Sealed.key(password: "tiger lily", kdf: kdf))
        let read = try #require(try Sealed.header(of: sealed).kdf)
        #expect(throws: Sealed.SealError.damaged) {
            try Sealed.openBundle(sealed, key: Sealed.key(password: "tiger lilly", kdf: read))
        }
        #expect(try Sealed.openBundle(sealed, key: Sealed.key(password: "tiger lily", kdf: read)).bundle == Self.bundle)
    }

    @Test func inflatingIsBounded() throws {
        let big = Data(repeating: 0x41, count: 1 << 20)
        let packed = try Sealed.deflate(big)
        #expect(packed.count < 4096)
        #expect(try Sealed.inflate(packed) == big)
        #expect(throws: Sealed.SealError.damaged) { try Sealed.inflate(packed, limit: 1 << 19) }
        #expect(throws: Sealed.SealError.damaged) { try Sealed.inflate(Data([0xFF, 0xFF, 0xFF])) }
        #expect(try Sealed.inflate(Sealed.deflate(Data())) == Data())
    }

    /// The browser's code (web/viewer-app) seals these same inputs to the same bytes, and
    /// opens what Swift sealed; Swift opens what the browser sealed and deflated
    /// (`Fixtures/sealed-by-browser.onx`, from `npm run vectors`).
    @Test func sharedVectors() throws {
        let key = SymmetricKey(data: Data(0..<32))
        let nonce = try AES.GCM.Nonce(data: Data(0..<12))
        let h = Sealed.Header(type: "text/plain", encoding: nil, bundle: nil, created: Self.created)
        let sealed = try Sealed.seal(Data("OpenNexus".utf8), header: h, key: key, nonce: nonce)
        #expect(sealed.base64EncodedString() == Self.vector)
        #expect(try Sealed.open(sealed, key: key).content == Data("OpenNexus".utf8))

        // The other direction's file, for web/viewer-app/test/sealed.test.ts.
        if ProcessInfo.processInfo.environment["NEXUS_WRITE_VECTORS"] == "1" {
            let web = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: "web/viewer-app/test/sealed-by-swift.onx")
            try Sealed.seal(bundle: Self.bundle, header: Sealed.Header(created: Self.created), key: key).write(to: web)
        }
        let url = try #require(Bundle.module.url(forResource: "Fixtures/sealed-by-browser", withExtension: "onx"))
        let fromBrowser = try Data(contentsOf: url)
        let (header, bundle) = try Sealed.openBundle(fromBrowser, key: key)
        #expect(header.encoding == Sealed.deflate && header.bundle == 1)
        #expect(bundle == Self.bundle)
    }

    /// `type: text/plain`, no encoding, created 2026-10-26T07:33:20Z, key 0…31, nonce 0…11,
    /// content "OpenNexus".
    static let vector =
        "T05YMQAAAFx7ImFsZ29yaXRobSI6IkFFUy0yNTYtR0NNIiwiY3JlYXRlZCI6IjIwMjYtMTAtMjZUMDc6MzM6MjBaIiwidHlwZSI6InRleHQvcGxhaW4iLCJ2ZXJzaW9uIjoxfQABAgMEBQYHCAkKCwhys3WLgLpu/n3GmuA+D1R71h4hA290CdU="

    // MARK: Links

    @Test func linkFragments() throws {
        let key = Data((0..<32).map { UInt8($0 * 7 & 0xFF) })
        let code = ShareLinkCode(source: .url, locator: "https://pub-1.r2.dev/opennexus/a b?.onx", key: key)
        let f = code.fragment
        #expect(f.hasPrefix("1.u.") && !f.contains("=") && !f.contains("/") && !f.contains("+"))
        #expect(ShareLinkCode(fragment: f) == code)
        let pw = ShareLinkCode(source: .gist, locator: "aa5a315d61ae9438b18d", key: nil)
        #expect(pw.fragment.hasSuffix(".pw") && ShareLinkCode(fragment: pw.fragment) == pw)
        #expect(
            code.link(viewer: "https://jvaudio.github.io/opennexus") == "https://jvaudio.github.io/opennexus/s/#\(f)")
        #expect(code.link(viewer: "https://maps.example/") == "https://maps.example/s/#\(f)")
        #expect(ShareLinkCode.origin("https://jvaudio.github.io/opennexus/") == "https://jvaudio.github.io")
        #expect(ShareLinkCode.origin("http://localhost:4173/") == "http://localhost:4173")
        for bad in [
            "", "1.u", "2.u.YQ.pw", "1.x.YQ.pw", "1.u..pw", "1.u.YQ.short", "1.u.YQ.\(key.base64URL())=",
            "1.u.Y$Q.pw", "1.u.YQ.pw.extra",
        ] {
            #expect(ShareLinkCode(fragment: bad) == nil, "\(bad)")
        }
    }
}
