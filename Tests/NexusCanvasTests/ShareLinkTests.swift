import CryptoKit
import Foundation
import NexusKeys
import NexusNet
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusScene

/// The three kinds of destination, in memory: a bucket, GitHub's gist API and an OpenNexus
/// Server. Requests arrive through `NetService`, exactly as the XPC service makes them.
final class FakeDestinations: URLProtocol, @unchecked Sendable {
    struct Seen: Sendable {
        var method: String
        var url: URL
        var headers: [String: String]
        var body: Data
    }

    nonisolated(unsafe) static var objects: [String: Data] = [:]
    nonisolated(unsafe) static var writeSecrets: [String: String] = [:]
    nonisolated(unsafe) static var expiries: [String: String] = [:]
    nonisolated(unsafe) static var seen: [Seen] = []
    static let lock = NSLock()
    static let uploadToken = "upload-token"
    static let gistToken = "ghp_test"

    static func reset() {
        lock.withLock {
            objects = [:]
            writeSecrets = [:]
            expiries = [:]
            seen = []
        }
    }

    static var requests: [Seen] { lock.withLock { seen } }

    /// What a reader's browser fetches for a link's locator.
    static func fetch(_ code: ShareLinkCode) -> Data? {
        lock.withLock {
            switch code.source {
            case .url: objects[code.locator]
            case .gist:
                objects["https://api.github.com/gists/\(code.locator)"].flatMap {
                    Data(base64Encoded: String(decoding: $0, as: UTF8.self))
                }
            }
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let s = request.httpBodyStream {
            s.open()
            var buf = [UInt8](repeating: 0, count: 65_536)
            while s.hasBytesAvailable {
                let n = s.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            s.close()
        }
        let url = request.url!
        let seen = Seen(
            method: request.httpMethod ?? "GET", url: url, headers: request.allHTTPHeaderFields ?? [:], body: body)
        let (status, out) = Self.lock.withLock {
            Self.seen.append(seen)
            return Self.answer(seen)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: out)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func header(_ s: Seen, _ name: String) -> String? {
        s.headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    /// Called with the lock held.
    static func answer(_ s: Seen) -> (Int, Data) {
        let key = s.url.absoluteString
        switch s.url.host {
        case "s3.example":
            // A public-read bucket, as a reader's browser or the app opening a link reads it
            // (M47d): an object without signing, 403 for one that isn't there.
            if s.method == "GET", header(s, "Authorization") == nil {
                return objects[key].map { (200, $0) } ?? (403, Data())
            }
            guard header(s, "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDTEST/") == true else {
                return (403, Data("<Error><Message>Bad signature</Message></Error>".utf8))
            }
            switch s.method {
            case "PUT":
                objects[key] = s.body
                return (200, Data())
            case "DELETE":
                objects[key] = nil
                return (204, Data())
            default: return objects[key].map { (200, $0) } ?? (404, Data())
            }
        case "api.github.com":
            // A secret gist is anyone's to read who has its id (a link opened in the app, M47d).
            if s.method == "GET", header(s, "Authorization") == nil, let stored = objects[key] {
                let file: JSONValue = .object([
                    "content": .string(String(decoding: stored, as: UTF8.self)), "truncated": .bool(false),
                ])
                return (
                    200, Data(CanonicalJSON.compact(.object(["files": .object(["opennexus-share.b64": file])])).utf8)
                )
            }
            guard header(s, "Authorization") == "Bearer \(gistToken)" else {
                return (401, Data(#"{"message":"Bad credentials"}"#.utf8))
            }
            func content(_ body: Data) -> Data? {
                guard let j = try? CanonicalJSON.parse(body),
                    let c = j["files"]?["opennexus-share.b64"]?["content"]?.stringValue
                else { return nil }
                return Data(c.utf8)
            }
            switch (s.method, s.url.path) {
            case ("POST", "/gists"):
                let id = Sealed.randomBytes(10).map { String(format: "%02x", $0) }.joined()
                objects["https://api.github.com/gists/\(id)"] = content(s.body)
                return (201, Data(#"{"id":"\#(id)","public":false}"#.utf8))
            case ("PATCH", _):
                guard objects[key] != nil else { return (404, Data()) }
                objects[key] = content(s.body)
                return (200, Data("{}".utf8))
            case ("DELETE", _):
                return objects.removeValue(forKey: key) == nil ? (404, Data()) : (204, Data())
            default: return (404, Data())
            }
        case "share.example":
            let path = s.url.path
            if path == "/v1/health" { return (200, Data(#"{"service":"opennexus-server","version":1}"#.utf8)) }
            if s.method == "POST", path == "/v1/shares" {
                guard header(s, "Authorization") == "Bearer \(uploadToken)" else { return (401, Data()) }
                // As the real server: only sealed envelopes.
                guard (try? Sealed.header(of: s.body)) != nil else { return (415, Data()) }
                let id = Sealed.randomBytes(16).base64URL()
                let secret = Sealed.randomBytes(32).base64URL()
                let url = "https://share.example/v1/shares/\(id)"
                objects[url] = s.body
                writeSecrets[url] = secret
                expiries[url] = header(s, "X-OpenNexus-Expires")
                return (201, Data(#"{"id":"\#(id)","secret":"\#(secret)"}"#.utf8))
            }
            guard objects[key] != nil else { return (404, Data()) }
            switch s.method {
            case "GET": return (200, objects[key]!)
            case "PUT", "DELETE":
                guard header(s, "Authorization") == "Bearer \(writeSecrets[key] ?? "-")" else { return (403, Data()) }
                if s.method == "PUT" {
                    guard (try? Sealed.header(of: s.body)) != nil else { return (415, Data()) }
                    objects[key] = s.body
                } else {
                    objects[key] = nil
                }
                return (204, Data())
            default: return (405, Data())
            }
        default: return (599, Data())
        }
    }
}

/// `OpenNexusNet.xpc` in this process: the same `NetService`, without XPC.
struct LocalTransport: ShareTransport {
    final class Jobs: @unchecked Sendable {
        var all: [NetJob] = []
        let lock = NSLock()
    }
    let jobs = Jobs()

    func perform(_ job: NetJob, body: Data) async -> NetReply {
        await exchange(job, body: body).reply
    }

    func exchange(_ job: NetJob, body: Data) async -> (reply: NetReply, body: Data) {
        jobs.lock.withLock { jobs.all.append(job) }
        return await NetService(protocolClasses: [FakeDestinations.self]).exchange(job, body: body)
    }
}

/// M44: share links, from the sheet to the bytes a reader's browser fetches (A1, A3–A6).
@MainActor
@Suite(.serialized) struct ShareLinkTests {
    let prefs: Preferences
    let secrets = MemorySecrets()
    let transport = LocalTransport()
    let center: ShareCenter
    let controller: CanvasController
    let file: URL

    static let bucket: ShareDestination = {
        var d = ShareDestination(id: "bucket", kind: .s3, name: "Bucket")
        d.endpoint = "https://s3.example"
        d.bucket = "maps"
        d.accessKey = "AKIDTEST"
        return d
    }()
    static let gist = ShareDestination(id: "gist", kind: .gist, name: "Gist")
    static let server: ShareDestination = {
        var d = ShareDestination(id: "server", kind: .server, name: "Server")
        d.server = "https://share.example/"
        return d
    }()

    init() {
        FakeDestinations.reset()
        prefs = Preferences.isolated()
        prefs.set("network.enabled", true)
        prefs.set("network.sharing", true)
        file = FileManager.default.temporaryDirectory.appending(path: "sharing-\(UUID().uuidString).json")
        center = ShareCenter(
            store: ShareStore(file: file), log: NetworkLog(file: nil), secrets: secrets, transport: transport,
            prefs: prefs)
        center.saveDestination(Self.bucket, secret: "s3-secret")
        center.saveDestination(Self.gist, secret: FakeDestinations.gistToken)
        center.saveDestination(Self.server, secret: FakeDestinations.uploadToken)
        controller = CanvasController(store: DocumentStore(model: Self.document()))
        controller.prefs = prefs
        controller.shareCenter = center
        controller.documentPath = "/Users/someone/Payments threat model.nexus"
    }

    /// The launch plan, with an email to mask and an AI-suggested topic.
    static func document() -> DocumentModel {
        var doc = ViewerBundleTests.richDocument()
        var c = doc.canvases["c1"]!
        let pro = ViewerBundleTests.node(c, "Pro")
        c.nodes[pro]?.text = "Pro · ask dana.ruiz@example.com"
        c.nodes[ViewerBundleTests.node(c, "Teams")]?.ai = true
        doc.canvases["c1"] = c
        return doc
    }

    /// The Share Link sheet as it opens, with `edit` applied.
    func state(_ edit: (inout ShareState) -> Void = { _ in }) throws -> ShareState {
        controller.openShareLink()
        var s = try #require(controller.shareState)
        edit(&s)
        return s
    }

    func record(_ s: ShareState) -> ShareRecord {
        var r = ShareRecord(
            document: controller.shareDocumentName, path: controller.documentPath,
            scope: controller.shareScope(s.export), destination: s.destination ?? "")
        r.mask = s.export.mask
        r.expires = s.expires()
        r.autoUpdate = s.autoUpdate
        return r
    }

    /// What a reader gets: the link's bytes, opened with its key (or the password).
    func open(_ r: ShareRecord, password: String? = nil) throws -> (header: Sealed.Header, bundle: JSONValue) {
        let link = try #require(center.link(r))
        #expect(link.hasPrefix(ShareCenter.defaultViewer + "s/#1."))
        let code = try #require(ShareLinkCode(fragment: String(link.split(separator: "#")[1])))
        let bytes = try #require(FakeDestinations.fetch(code), "nothing stored at \(code.locator)")
        let header = try Sealed.header(of: bytes)
        let key: SymmetricKey
        if let password {
            #expect(code.key == nil)
            key = Sealed.key(password: password, kdf: try #require(header.kdf))
        } else {
            key = SymmetricKey(data: try #require(code.key))
        }
        return try Sealed.openBundle(bytes, key: key)
    }

    /// The bundle the Interactive HTML export embeds for the same options.
    func exportBundle(_ s: ShareState) throws -> JSONValue {
        let html = controller.exportHTML(s.export)
        let data = try #require(
            HTMLExportTests.between(html, "<script type=\"application/json\" id=\"opennexus-bundle\">", "</script>"))
        return try CanonicalJSON.parse(Data(data.utf8))
    }

    // MARK: A1 · off until turned on

    @Test func theNetworkIsOffUntilTurnedOn() async throws {
        let fresh = Preferences.isolated()
        let rows = SettingsSchema.allRows.map(\.2).filter { $0.key.hasPrefix("network.") }
        #expect(rows.map(\.key).sorted() == ["network.collab", "network.enabled", "network.sharing", "network.sync"])
        for r in rows { #expect(r.defaultValue == .bool(false), "\(r.key)") }
        center.prefs = fresh
        controller.prefs = fresh
        #expect(!center.networkOn)
        controller.openShareLink()
        #expect(controller.shareNotice == .networkOff && controller.shareState == nil)
        // Nothing reaches the service while it's off, whatever asks.
        let r = ShareRecord(
            document: "x", path: nil, scope: ShareScope(kind: .document, title: "x"), destination: "bucket")
        await #expect(throws: ShareCenter.Failure.networkOff) {
            try await center.create(.object([:]), record: r, password: nil)
        }
        #expect(await !center.test(Self.bucket).ok)
        // The master switch alone isn't enough: each feature has its own.
        fresh.set("network.enabled", true)
        #expect(!center.networkOn)
        fresh.set("network.sharing", true)
        #expect(center.networkOn)
        #expect(transport.jobs.all.isEmpty && FakeDestinations.requests.isEmpty)
    }

    @Test func withNowhereToStoreLinksTheSheetSaysSo() {
        for id in ["bucket", "gist", "server"] { center.removeDestination(id) }
        controller.openShareLink()
        #expect(controller.shareNotice == .noDestination && controller.shareState == nil)
        #expect(secrets.accounts.isEmpty, "removing a destination removes its credential")
    }

    /// The service gets the destinations' hosts as its allow-list, and every request it
    /// made is logged with its bytes.
    @Test func everyRequestIsAllowedAndLogged() async throws {
        let s = try state { $0.destination = "server" }
        let r = try await center.create(controller.shareBundle(s), record: record(s), password: nil)
        let job = try #require(transport.jobs.all.last)
        #expect(job.allowedHosts == ["api.github.com", "s3.example", "share.example"])
        #expect(job.secret == FakeDestinations.uploadToken)
        let log = center.log.entries
        #expect(log.count == FakeDestinations.requests.count && log.count == 1)
        let e = try #require(log.first)
        #expect(e.host == "share.example" && e.method == "POST" && e.status == 201 && e.purpose == "Share link")
        #expect(e.sent == FakeDestinations.objects[r.locator]?.count && e.received > 0)
        #expect(center.log.csv().hasPrefix("time,host,method,purpose,status,bytes sent,bytes received\n"))
    }

    // MARK: A2 · each destination, the export's bundle

    @Test(arguments: ["bucket", "gist", "server"]) func aLinkOpensToTheExportsBundle(_ destination: String) async throws
    {
        let s = try state { $0.destination = destination }
        #expect(s.export.format == .html)
        let r = try await center.create(controller.shareBundle(s), record: record(s), password: nil)
        #expect(r.source == (destination == "gist" ? .gist : .url))
        let (header, bundle) = try open(r)
        #expect(header.type == Sealed.viewerType && header.encoding == Sealed.deflate && header.expires == nil)
        #expect(bundle == (try exportBundle(s)))
        #expect(SchemaValidator.viewer.validate(bundle).isEmpty)
        #expect(center.store.links.first == r && r.document == "Payments threat model")
    }

    // MARK: A3 · nothing readable leaves the Mac

    @Test func theStoredObjectNamesNothing() async throws {
        for destination in ["bucket", "gist", "server"] {
            let s = try state { $0.destination = destination }
            _ = try await center.create(controller.shareBundle(s), record: record(s), password: nil)
        }
        let doc = Self.document()
        let words =
            ["Payments threat model", "threat", "Launch plan", "Pricing", "Secret pricing note", "Hidden remark"]
            + doc.canvases["c1"]!.nodes.values.map(\.text).filter { $0.count > 3 }
        for seen in FakeDestinations.requests {
            // The gist's JSON carries the sealed bytes as base64; decode it to look inside too.
            var texts = [seen.url.absoluteString, String(decoding: seen.body, as: UTF8.self)]
            texts += seen.headers.map { "\($0.key): \($0.value)" }
            if let b64 = (try? CanonicalJSON.parse(seen.body))?["files"]?["opennexus-share.b64"]?["content"]?
                .stringValue,
                let raw = Data(base64Encoded: b64)
            {
                texts.append(String(decoding: raw, as: UTF8.self))
            }
            for t in texts {
                for w in words { #expect(!t.contains(w), "“\(w)” in \(seen.method) \(seen.url)") }
            }
        }
    }

    @Test func aWrongKeyOrAnAlteredByteIsDamaged() async throws {
        let s = try state { $0.destination = "bucket" }
        let r = try await center.create(controller.shareBundle(s), record: record(s), password: nil)
        let link = try #require(center.link(r))
        let code = try #require(ShareLinkCode(fragment: String(link.split(separator: "#")[1])))
        let bytes = try #require(FakeDestinations.fetch(code))
        #expect(throws: Sealed.SealError.damaged) { try Sealed.openBundle(bytes, key: SymmetricKey(size: .bits256)) }
        for i in [0, 6, 20, bytes.count / 2, bytes.count - 1] {
            var b = bytes
            b[i] ^= 0x01
            #expect(throws: Sealed.SealError.self) { try Sealed.openBundle(b, key: SymmetricKey(data: code.key!)) }
        }
        // The key is only in the link: not in the record file, not at the destination.
        let saved = try String(contentsOf: file, encoding: .utf8)
        let key = code.key!.base64URL()
        #expect(!saved.contains(key) && !saved.contains(code.key!.base64EncodedString()))
        #expect(!saved.contains("s3-secret") && !saved.contains(FakeDestinations.uploadToken))
        #expect(FakeDestinations.requests.allSatisfy { !$0.url.absoluteString.contains(key) })
        #expect(secrets.accounts.contains("link:\(r.id)") && secrets.accounts.contains("dest:bucket"))
    }

    // MARK: A4 · passwords

    @Test func aPasswordLinkNeedsThePassword() async throws {
        let s = try state {
            $0.destination = "server"
            $0.usePassword = true
            $0.password = "correct horse"
        }
        let r = try await center.create(controller.shareBundle(s), record: record(s), password: s.password)
        #expect(r.password)
        let link = try #require(center.link(r))
        #expect(link.hasSuffix(".pw"), "no key in the link")
        let (header, bundle) = try open(r, password: "correct horse")
        #expect(header.kdf?.iterations == Sealed.iterations && header.kdf?.salt.count == 16)
        #expect(bundle == (try exportBundle(s)))
        let code = try #require(ShareLinkCode(fragment: String(link.split(separator: "#")[1])))
        let bytes = try #require(FakeDestinations.fetch(code))
        #expect(throws: Sealed.SealError.damaged) {
            try Sealed.openBundle(bytes, key: Sealed.key(password: "Correct horse", kdf: header.kdf!))
        }
        // Updating keeps the password (the derived key is in the Keychain, not the password).
        controller.store.updateDocument { $0.canvases["c1"]?.title = "Launch plan v2" }
        try await center.update(r, bundle: try #require(controller.shareBundle(for: r)))
        let after = try open(r, password: "correct horse")
        #expect(after.header.kdf == header.kdf)
        #expect(center.link(r) == link)
        let saved = try String(contentsOf: file, encoding: .utf8)
        #expect(!saved.contains("correct horse"))
    }

    // MARK: A5 · update, revoke, expiry

    @Test(arguments: ["bucket", "gist", "server"]) func updateKeepsTheLinkAndRevokeEndsIt(_ destination: String)
        async throws
    {
        let s = try state { $0.destination = destination }
        let r = try await center.create(controller.shareBundle(s), record: record(s), password: nil)
        let link = center.link(r)
        controller.store.updateDocument { m in
            let root = m.canvases["c1"]!.root
            var undo = UndoStack()
            m.canvases["c1"]!.edit("Add", undo: &undo) { e in _ = try? e.addChild(of: root, text: "Added after sharing")
            }
        }
        try await center.update(r, bundle: try #require(controller.shareBundle(for: r)))
        #expect(center.link(r) == link)
        let text = CanonicalJSON.compact(try open(r).bundle)
        #expect(text.contains("Added after sharing"))
        #expect(center.store.links.first?.updated ?? .distantPast >= r.updated)

        try await center.revoke(r)
        let code = try #require(ShareLinkCode(fragment: String(link!.split(separator: "#")[1])))
        #expect(FakeDestinations.fetch(code) == nil, "the object is deleted")
        #expect(center.store.links.isEmpty && !secrets.accounts.contains("link:\(r.id)"))
    }

    @Test func expiredLinksAreRefusedAndSwept() async throws {
        let now = Date()
        let s = try state {
            $0.destination = "server"
            $0.expiry = .week
        }
        let r = try await center.create(controller.shareBundle(s), record: record(s), password: nil)
        let expires = try #require(r.expires)
        #expect(abs(expires.timeIntervalSince(now) - 7 * 86_400) < 60)
        // The header says when (the viewer refuses it after), and so does the server's header.
        let (header, _) = try open(r)
        #expect(header.expires == Sealed.timestamp(expires))
        #expect(FakeDestinations.expiries[r.locator] == Sealed.timestamp(expires))
        await center.sweepExpired(now: now.addingTimeInterval(86_400))
        #expect(center.store.links.count == 1, "not yet")
        await center.sweepExpired(now: expires.addingTimeInterval(1))
        #expect(center.store.links.isEmpty && FakeDestinations.objects[r.locator] == nil)
    }

    @Test func savingRepublishesLinksMarkedUpdateWhenISave() async throws {
        let s = try state {
            $0.destination = "bucket"
            $0.autoUpdate = true
        }
        let r = try await center.create(controller.shareBundle(s), record: record(s), password: nil)
        let other = try await center.create(controller.shareBundle(s), record: record(try state()), password: nil)
        controller.store.updateDocument { $0.canvases["c1"]?.title = "Renamed before save" }
        controller.republishShareLinks()
        await controller.shareRepublish?.value
        #expect(CanonicalJSON.compact(try open(r).bundle).contains("Renamed before save"))
        #expect(!CanonicalJSON.compact(try open(other).bundle).contains("Renamed before save"))
        // Autosaves wait, and a later one replaces the earlier.
        controller.store.updateDocument { $0.canvases["c1"]?.title = "Renamed again" }
        controller.republishShareLinks(after: .seconds(30))
        controller.republishShareLinks(after: .milliseconds(10))
        await controller.shareRepublish?.value
        #expect(CanonicalJSON.compact(try open(r).bundle).contains("Renamed again"))
    }

    // MARK: A6 · masking and Strip AI, as in Export

    @Test func maskingAndStrippingAIMatchTheExport() async throws {
        prefs.set("export.masking", "always")
        prefs.set("export.stripAI", true)
        prefs.set("privacy.maskEmails", true)
        let s = try state { $0.destination = "gist" }
        #expect(s.export.mask)
        let r = try await center.create(controller.shareBundle(s), record: record(s), password: nil)
        #expect(r.mask)
        let bundle = try open(r).bundle
        #expect(bundle == (try exportBundle(s)))
        #expect(!CanonicalJSON.compact(bundle).contains("dana.ruiz@example.com"))
        // Unmasked, the same link would carry it.
        var plain = s
        plain.export.mask = false
        #expect(CanonicalJSON.compact(controller.shareBundle(plain)).contains("dana.ruiz@example.com"))
        // The AI topic's mark is gone too, and comes back without Strip AI.
        #expect(controller.store.model.canvases.values.contains { $0.nodes.values.contains(where: \.ai) })
        #expect(!controller.exportModel(s.export).canvases.values.contains { $0.nodes.values.contains(where: \.ai) })
        prefs.set("export.stripAI", false)
        #expect(controller.shareBundle(s) != bundle)
    }

    // MARK: Commands

    @Test func shareLinkHasAShortcutAndAMenu() throws {
        let c = try #require(DefaultCommands.all.first { $0.id == .shareLink })
        #expect(c.title == "Share Link…" && c.menu == .file)
        #expect(c.keys.map(\.description) == ["⌃⌘S"])
        #expect(DefaultCommands.all.contains { $0.id == .manageShareLinks && $0.menu == .file })
        for profile in KeyProfile.all {
            #expect(
                CommandRegistry.standard.bindings(for: .shareLink, profile: profile).map(\.description) == ["⌃⌘S"],
                "\(profile.name)")
        }
        // Settings › Sharing is found by what people call its parts.
        #expect(SettingsSchema.search("gist").first?.2.key == "sharing.destinations")
        #expect(SettingsSchema.search("minio").first?.2.key == "sharing.destinations")
        #expect(SettingsSchema.search("revoke").contains { $0.2.key == "sharing.links" })
        #expect(SettingsSchema.search("viewer address").first?.2.key == "sharing.viewerAddress")
        #expect(SettingsSchema.search("share links").contains { $0.2.key == "network.sharing" })
        _ = controller.perform(.manageShareLinks)
        #expect(controller.manageLinks)
        controller.closeManageLinks()
        _ = controller.perform(.shareLink)
        #expect(controller.shareState?.destination == "bucket")
    }
}
