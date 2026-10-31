import CryptoKit
import Foundation
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat
@testable import NexusInterchange
@testable import NexusScene

/// M47d (D441): Open in OpenNexus. The app reads a share link from the link's own hosts,
/// behind the sharing switches, logs it, and opens the map as a new document with an
/// import report (A6). In `ShareLinkTests`, so they're serialized with its other tests:
/// both use `FakeDestinations`.
extension ShareLinkTests {

    /// A link to the rich launch plan, stored at `destination`.
    func share(_ destination: String, password: String? = nil) async throws -> (ShareRecord, String) {
        let s = try state {
            $0.destination = destination
            if let password {
                $0.usePassword = true
                $0.password = password
            }
        }
        let r = try await center.create(controller.shareBundle(s), record: record(s), password: password)
        return (r, try #require(center.link(r)))
    }

    /// A link to `sealed`, stored on the server as if it had been shared.
    func stored(_ sealed: Data, key: SymmetricKey) -> String {
        let url = "https://share.example/v1/shares/\(Sealed.randomBytes(16).base64URL())"
        FakeDestinations.lock.withLock { FakeDestinations.objects[url] = sealed }
        return ShareLinkCode(source: .url, locator: url, key: key.withUnsafeBytes { Data($0) }).link(
            viewer: ShareCenter.defaultViewer)
    }

    func failure(_ text: String) async -> String? {
        do {
            _ = try await center.openLink(text)
            return nil
        } catch ShareCenter.Failure.failed(let why) {
            return why
        } catch {
            return "\(error)"
        }
    }

    @Test func opensALinkFromItsOwnHosts() async throws {
        for d in ["bucket", "gist", "server"] {
            let (r, link) = try await share(d)
            let before = FakeDestinations.requests.count
            let jobs = transport.jobs.all.count
            let bundle = try await center.openLink(link)
            #expect(bundle == (try open(r)).bundle, "\(d)")
            // The job names no destination's secret or hosts; the service reads the link's.
            let job = try #require(transport.jobs.all.last)
            #expect(transport.jobs.all.count == jobs + 1)
            #expect(job.action == .read && job.secret.isEmpty && job.allowedHosts.isEmpty && job.writeSecret == nil)
            let reads = FakeDestinations.requests.dropFirst(before)
            #expect(
                !reads.isEmpty
                    && reads.allSatisfy { $0.method == "GET" && FakeDestinations.header($0, "Authorization") == nil })
            let code = try #require(ShareCenter.linkCode(link))
            let hosts = Set(reads.compactMap(\.url.host))
            #expect(
                hosts == (code.source == .gist ? ["api.github.com"] : [URL(string: code.locator)?.host ?? ""]), "\(d)")
            // Logged, as every request is.
            let logged = center.log.entries.suffix(reads.count)
            #expect(logged.allSatisfy { $0.purpose == "Open share link" && hosts.contains($0.host) })
            // The app's form of the link opens the same map.
            let app = "opennexus://view#" + (link.split(separator: "#").last.map(String.init) ?? "")
            #expect(try await center.openLink(app) == bundle)
        }
    }

    @Test func refusesWithoutTheSwitchesOrTheKey() async throws {
        let (_, link) = try await share("server")
        let (_, pw) = try await share("server", password: "correct horse")
        let jobs = transport.jobs.all.count
        let fresh = Preferences.isolated()
        center.prefs = fresh
        await #expect(throws: ShareCenter.Failure.networkOff) { try await center.openLink(link) }
        fresh.set("network.enabled", true)
        await #expect(throws: ShareCenter.Failure.networkOff) { try await center.openLink(link) }
        fresh.set("network.sharing", true)
        // A password link carries no key: the browser opens it, then hands the app the key.
        #expect(await failure(pw)?.contains("opens with a password") == true)
        #expect(await failure("https://example.com/not-a-link")?.contains("isn’t a share link") == true)
        #expect(await failure("opennexus://view#1.u.abc") != nil)
        #expect(transport.jobs.all.count == jobs, "nothing reached the service")
    }

    @Test func turnedOffDamagedExpiredAndNewer() async throws {
        let (r, link) = try await share("server")
        let code = try #require(ShareCenter.linkCode(link))
        // A wrong key, then a changed byte.
        let wrong = ShareLinkCode(source: code.source, locator: code.locator, key: Sealed.randomBytes(32))
        #expect(await failure(wrong.link(viewer: ShareCenter.defaultViewer))?.contains("damaged") == true)
        let key = SymmetricKey(size: .bits256)
        var flipped = try Sealed.seal(
            bundle: .object(["format": .string("opennexus-viewer")]), header: Sealed.Header(), key: key)
        flipped[flipped.count / 2] ^= 0x20
        #expect(await failure(stored(flipped, key: key))?.contains("damaged") == true)
        // Expired: by the header's date, whatever the server still serves.
        let past = try Sealed.seal(
            bundle: controller.shareBundle(try state()),
            header: Sealed.Header(
                created: Date(timeIntervalSince1970: 1_700_000_000), expires: Date(timeIntervalSince1970: 1_700_086_400)
            ),
            key: key)
        #expect(await failure(stored(past, key: key))?.contains("expired") == true)
        // From a newer OpenNexus.
        var header = Sealed.Header()
        header.version = 2
        #expect(
            await failure(stored(try Sealed.seal(Data([1, 2, 3]), header: header, key: key), key: key))?.contains(
                "newer version") == true)
        // Revoked: the server answers 404.
        try await center.revoke(r)
        #expect(await failure(link)?.contains("turned off") == true)
    }

    // MARK: The new document

    /// Every topic of the source canvas, root and floating topics first, depth first.
    static func walk(_ c: Canvas) -> [Node] {
        var out: [Node] = []
        func visit(_ id: NodeID) {
            guard let n = c.nodes[id] else { return }
            out.append(n)
            n.children.forEach(visit)
        }
        ([c.root] + c.floating).forEach(visit)
        return out
    }

    @Test func importsTheLinksMap() async throws {
        let (_, link) = try await share("server")
        let imported = try await center.importLink(link)
        let source = try #require(ShareLinkTests.document().canvases["c1"])
        let c = try #require(imported.canvases.first)
        #expect(imported.canvases.count == 1 && c.type == source.type)
        let got = Self.walk(c)
        let want = Self.walk(source)
        // The share masks the email (export.masking) and keeps the rest's text.
        #expect(got.count == want.count)
        #expect(got.map(\.text).filter { !$0.contains("@") } == want.map(\.text).filter { !$0.contains("@") })
        let pricing = try #require(got.first { $0.text == "Pricing" })
        #expect(pricing.note?.text == "Secret pricing note")
        #expect(pricing.comments.map(\.text) == ["Hidden remark"] && pricing.comments.first?.author == "Ana")
        #expect(got.first { $0.text == "Channels" }?.link == "https://example.com/channels")
        #expect(got.first { $0.text == "Timeline" }?.folded == true)
        #expect(imported.report.format == "Share link" && imported.report.canvases == 1)
        #expect(imported.report.skipped.contains { $0.0.hasPrefix("Styles, themes and positions") })
    }

    /// LaunchPlan's bundle, with markers, labels, tasks, links within the canvas and its
    /// attachment, back as a document.
    @Test func importsABundle() throws {
        var doc = ViewerBundleTests.richDocument()
        var c = doc.canvases["c1"]!
        let pricing = ViewerBundleTests.node(c, "Pricing")
        let risks = ViewerBundleTests.node(c, "Risks")
        c.nodes[pricing]?.markers = ["priority-1", "flag-red"]
        c.nodes[pricing]?.labels = ["Q4", "café"]
        c.nodes[pricing]?.link = TopicLink.make(canvas: c.id, node: risks)
        c.nodes[risks]?.todo = Todo(done: true)
        doc.canvases["c1"] = c
        var o = ViewerBundleTests.options()
        o.attachments = true
        let bundle = ViewerBundle.build(doc, o)
        let imported = try ViewerBundleImport.parse(bundle, name: "Launch plan")
        let out = try #require(imported.canvases.first)
        let got = Self.walk(out)
        let want = Self.walk(c)
        #expect(got.map(\.text) == want.map(\.text))
        #expect(got.map { $0.note?.text } == want.map { $0.note?.text })
        #expect(got.map(\.folded) == want.map(\.folded))
        let p = try #require(got.first { $0.text == "Pricing" })
        #expect(p.markers == ["priority-1", "flag-red"] && p.labels == ["Q4", "café"])
        // A link to a topic on the same canvas points at the new document's topic.
        let target = try #require(got.first { $0.text == "Risks" })
        #expect(p.link == TopicLink.make(canvas: out.id, node: ViewerBundleTests.node(out, "Risks")))
        #expect(target.todo?.done == true)
        let attachment = try #require(target.attachments.first)
        #expect(attachment.name == "Brief.pdf" && imported.assets[attachment.asset] == Data("%PDF-1.4 brief".utf8))
        // An attachment the bundle only names (a viewer copy) is reported, not invented.
        var named = ViewerBundleTests.options()
        named.attachments = true
        named.embedAssets = false
        let partial = try ViewerBundleImport.parse(ViewerBundle.build(doc, named), name: "Launch plan")
        #expect(
            partial.assets.isEmpty
                && partial.report.skipped.contains { $0 == ("Attachment the link didn’t include", 1) })
        #expect(throws: ImportError.self) {
            try ViewerBundleImport.parse(.object(["format": .string("other")]), name: "x")
        }
    }

    /// A technical diagram keeps its type and its node types; its flows (connections) are
    /// reported as not carried.
    @Test func importsATechnicalDiagram() throws {
        let source = TechSamples.flowchart()
        let bundle = ViewerBundle.build(DocumentModel(canvases: [source]), ViewerBundleTests.options())
        let imported = try ViewerBundleImport.parse(bundle, name: "Flow")
        let c = try #require(imported.canvases.first)
        #expect(c.type == source.type)
        let got = Self.walk(c)
        let want = Self.walk(source)
        #expect(got.map(\.text) == want.map(\.text))
        #expect(got.map(\.nodeType) == want.map(\.nodeType))
        let flows = imported.report.skipped.first { $0.0 == "Relationship" }?.1 ?? 0
        #expect(flows == source.relationships.count && flows > 0)
    }
}
