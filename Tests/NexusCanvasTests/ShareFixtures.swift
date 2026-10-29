import CryptoKit
import Foundation
import NexusNet
import Testing

@testable import NexusCanvas
@testable import NexusCore
@testable import NexusFormat

/// M44: share links for the viewer's browser tests (`web/e2e/share.spec.ts`). Each case is
/// a link, the responses its fetches get, and what the page should show. Build products
/// (git-ignored), made by `npm run fixtures` in web/.
///
/// `ShareFixtures` makes links against the in-memory destinations, so Playwright serves the
/// responses itself. `ShareLive` makes them against MinIO and the server in Docker
/// (`scripts/test-share.sh`), so the browser fetches them for real.
enum ShareCases {
    nonisolated static let viewer = "http://127.0.0.1:4310/"
    nonisolated static let web = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "web/fixtures")

    struct Route {
        var url: String
        var file: String?
        var status = 200
        var json = false
    }

    struct Case {
        var name: String
        var link: String
        var expect: String
        var bundle: String?
        var password: String?
        var routes: [Route] = []
        /// After the first visit: these routes, then reload, then `then` and `thenBundle`.
        var after: [Route]?
        var then: String?
        var thenBundle: String?
    }

    static func json(_ c: Case) -> JSONValue {
        func routes(_ rs: [Route]) -> JSONValue {
            .array(
                rs.map { r in
                    var o: [String: JSONValue] = ["url": .string(r.url), "status": .number(Double(r.status))]
                    if let f = r.file { o["file"] = .string(f) }
                    if r.json { o["json"] = .bool(true) }
                    return .object(o)
                })
        }
        var o: [String: JSONValue] = [
            "name": .string(c.name), "link": .string(c.link), "expect": .string(c.expect), "routes": routes(c.routes),
        ]
        if let b = c.bundle { o["bundle"] = .string(b) }
        if let p = c.password { o["password"] = .string(p) }
        if let a = c.after { o["after"] = routes(a) }
        if let t = c.then { o["then"] = .string(t) }
        if let b = c.thenBundle { o["thenBundle"] = .string(b) }
        return .object(o)
    }

    static func write(_ cases: [Case], files: [String: Data], to dir: URL) throws {
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: dir.appending(path: name)) }
        let manifest = JSONValue.object(["viewer": .string(viewer), "cases": .array(cases.map(json))])
        try CanonicalJSON.data(manifest).write(to: dir.appending(path: "manifest.json"))
    }

    static func fragment(_ link: String) -> ShareLinkCode? {
        link.split(separator: "#", maxSplits: 1).last.flatMap { ShareLinkCode(fragment: String($0)) }
    }
}

@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["NEXUS_WRITE_VIEWER_FIXTURES"] == "1"))
struct ShareFixtures {
    /// What GitHub's API answers for a share gist.
    static func gistJSON(_ id: String, _ sealed: Data) -> Data {
        let files: JSONValue = .object([
            GistFile.name: .object([
                "filename": .string(GistFile.name), "content": .string(sealed.base64EncodedString()),
                "truncated": .bool(false),
            ])
        ])
        return Data(CanonicalJSON.compact(.object(["id": .string(id), "public": .bool(false), "files": files])).utf8)
    }

    enum GistFile { static let name = "opennexus-share.b64" }

    @Test func writeShareFixtures() async throws {
        let t = ShareLinkTests()
        t.prefs.set("sharing.viewerAddress", ShareCases.viewer)
        var cases: [ShareCases.Case] = []
        var files: [String: Data] = [:]

        /// The routes that serve a link's object as the destination would.
        func routes(_ name: String, _ r: ShareRecord, _ bytes: Data) -> [ShareCases.Route] {
            switch r.source {
            case .gist:
                files["\(name).json"] = Self.gistJSON(r.locator, bytes)
                return [
                    ShareCases.Route(url: "https://api.github.com/gists/\(r.locator)", file: "\(name).json", json: true)
                ]
            case .url:
                files["\(name).onx"] = bytes
                return [ShareCases.Route(url: r.locator, file: "\(name).onx")]
            }
        }

        func make(_ destination: String, password: String? = nil, edit: (inout ShareState) -> Void = { _ in })
            async throws
            -> (ShareRecord, Data, ShareState)
        {
            let s = try t.state {
                $0.destination = destination
                edit(&$0)
            }
            let r = try await t.center.create(t.controller.shareBundle(s), record: t.record(s), password: password)
            let code = try #require(ShareCases.fragment(t.center.link(r) ?? ""))
            return (r, try #require(FakeDestinations.fetch(code)), s)
        }

        // A2: each destination opens to the export's bundle.
        for d in ["bucket", "gist", "server"] {
            let (r, bytes, s) = try await make(d)
            files["\(d).bundle.json"] = Data(CanonicalJSON.compact(try t.exportBundle(s)).utf8)
            cases.append(
                .init(
                    name: d, link: t.center.link(r)!, expect: "ready", bundle: "\(d).bundle.json",
                    routes: routes(d, r, bytes)))
        }

        // A3: a wrong key, and an altered byte.
        let (good, goodBytes, _) = try await make("bucket")
        let link = t.center.link(good)!
        let wrongKey = ShareLinkCode(source: .url, locator: good.locator, key: Sealed.randomBytes(32)).link(
            viewer: ShareCases.viewer)
        cases.append(
            .init(name: "wrong-key", link: wrongKey, expect: "damaged", routes: routes("wrong-key", good, goodBytes)))
        var flipped = goodBytes
        flipped[flipped.count / 2] ^= 0x20
        cases.append(.init(name: "flipped", link: link, expect: "damaged", routes: routes("flipped", good, flipped)))

        // A4: a password link.
        let (pw, pwBytes, pwState) = try await make("server", password: "correct horse") {
            $0.usePassword = true
            $0.password = "correct horse"
        }
        files["password.bundle.json"] = Data(CanonicalJSON.compact(try t.exportBundle(pwState)).utf8)
        cases.append(
            .init(
                name: "password", link: t.center.link(pw)!, expect: "password", bundle: "password.bundle.json",
                password: "correct horse", routes: routes("password", pw, pwBytes)))

        // A5: Update keeps the link and shows the new map; Revoke and expiry turn it off.
        let (up, v1, upState) = try await make("gist")
        files["update-1.bundle.json"] = Data(CanonicalJSON.compact(try t.exportBundle(upState)).utf8)
        t.controller.store.updateDocument { $0.canvases["c1"]?.title = "Launch plan, updated" }
        try await t.center.update(up, bundle: try #require(t.controller.shareBundle(for: up)))
        let upCode = try #require(ShareCases.fragment(t.center.link(up)!))
        let v2 = try #require(FakeDestinations.fetch(upCode))
        files["update-2.bundle.json"] = Data(CanonicalJSON.compact(try t.exportBundle(upState)).utf8)
        let first = routes("update-1", up, v1)
        let second = routes("update-2", up, v2)
        cases.append(
            .init(
                name: "update", link: t.center.link(up)!, expect: "ready", bundle: "update-1.bundle.json",
                routes: first,
                after: second, then: "ready", thenBundle: "update-2.bundle.json"))
        let (gone, goneBytes, _) = try await make("server")
        cases.append(
            .init(
                name: "revoke", link: t.center.link(gone)!, expect: "ready", routes: routes("revoke", gone, goneBytes),
                after: [ShareCases.Route(url: gone.locator, status: 404)], then: "off"))
        let expiredKey = SymmetricKey(size: .bits256)
        let expiredBytes = try Sealed.seal(
            bundle: t.controller.shareBundle(try t.state()),
            header: Sealed.Header(
                created: Date(timeIntervalSince1970: 1_700_000_000), expires: Date(timeIntervalSince1970: 1_700_086_400)
            ),
            key: expiredKey)
        files["expired.onx"] = expiredBytes
        let expiredURL = "https://s3.example/maps/opennexus/expired.onx"
        cases.append(
            .init(
                name: "expired",
                link: ShareLinkCode(source: .url, locator: expiredURL, key: expiredKey.withUnsafeBytes { Data($0) })
                    .link(
                        viewer: ShareCases.viewer), expect: "expired",
                routes: [ShareCases.Route(url: expiredURL, file: "expired.onx")]))

        // A map from a newer OpenNexus: a newer envelope, and a newer bundle inside one.
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        var header = Sealed.Header()
        header.version = 2
        let newerEnvelope = try Sealed.seal(Data([1, 2, 3]), header: header, key: key)
        let newerBundle = try Sealed.seal(
            bundle: t.controller.shareBundle(try t.state()), header: Sealed.Header(bundle: 2), key: key)
        for (name, bytes) in [("newer-envelope", newerEnvelope), ("newer-bundle", newerBundle)] {
            let url = "https://s3.example/maps/opennexus/\(name).onx"
            files["\(name).onx"] = bytes
            cases.append(
                .init(
                    name: name,
                    link: ShareLinkCode(source: .url, locator: url, key: raw).link(viewer: ShareCases.viewer),
                    expect: "newer", routes: [ShareCases.Route(url: url, file: "\(name).onx")]))
        }
        // An unreachable destination offers Try Again.
        cases.append(
            .init(
                name: "unreachable",
                link: ShareLinkCode(source: .url, locator: "https://s3.example/maps/x.onx", key: raw)
                    .link(viewer: ShareCases.viewer), expect: "unreachable",
                routes: [ShareCases.Route(url: "https://s3.example/maps/x.onx", status: 503)]))

        try ShareCases.write(cases, files: files, to: ShareCases.web.appending(path: "share"))
        #expect(cases.count == 12)
    }
}

/// Real links against MinIO and the server in Docker (scripts/test-share.sh sets the
/// addresses). Writes `web/fixtures/share-live/` for Playwright, which fetches for real.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["OPENNEXUS_LIVE_SHARE"] == "1"))
struct ShareLive {
    struct RealNetwork: ShareTransport {
        func perform(_ job: NetJob, body: Data) async -> NetReply { await NetService().perform(job, body: body) }
    }

    static let env = ProcessInfo.processInfo.environment

    @Test func makeRealLinks() async throws {
        let t = ShareLinkTests()
        t.prefs.set("sharing.viewerAddress", ShareCases.viewer)
        t.center.transport = RealNetwork()
        for id in ["bucket", "gist", "server"] { t.center.removeDestination(id) }
        var minio = ShareDestination(id: "minio", kind: .s3, name: "MinIO")
        minio.endpoint = Self.env["OPENNEXUS_LIVE_S3"] ?? "http://127.0.0.1:19000"
        minio.bucket = "maps"
        minio.accessKey = "onxtest"
        t.center.saveDestination(minio, secret: "onxtest-secret-key")
        var disk = ShareDestination(id: "server", kind: .server, name: "Server (disk)")
        disk.server = Self.env["OPENNEXUS_LIVE_SERVER"] ?? "http://127.0.0.1:18787"
        t.center.saveDestination(disk, secret: "test-upload-token-0123456789")
        var s3 = ShareDestination(id: "server-s3", kind: .server, name: "Server (MinIO)")
        s3.server = Self.env["OPENNEXUS_LIVE_SERVER_S3"] ?? "http://127.0.0.1:18788"
        t.center.saveDestination(s3, secret: "test-upload-token-0123456789")

        // Each destination's Test works for real.
        for d in t.center.store.destinations {
            let r = await t.center.test(d)
            #expect(r.ok, "\(d.name): \(r.error ?? "")")
            #expect(r.detail?.contains("can’t") != true, "\(d.name): \(r.detail ?? "")")
        }

        var cases: [ShareCases.Case] = []
        var files: [String: Data] = [:]
        for id in ["minio", "server", "server-s3"] {
            let s = try t.state { $0.destination = id }
            let r = try await t.center.create(t.controller.shareBundle(s), record: t.record(s), password: nil)
            files["\(id).bundle.json"] = Data(CanonicalJSON.compact(try t.exportBundle(s)).utf8)
            cases.append(.init(name: id, link: t.center.link(r)!, expect: "ready", bundle: "\(id).bundle.json"))

            // Updated: the same link, the new map.
            let u = try await t.center.create(t.controller.shareBundle(s), record: t.record(s), password: nil)
            let link = t.center.link(u)!
            t.controller.store.updateDocument { $0.canvases["c1"]?.title = "Updated on \(id)" }
            try await t.center.update(u, bundle: try #require(t.controller.shareBundle(for: u)))
            #expect(t.center.link(u) == link)
            files["\(id)-updated.bundle.json"] = Data(CanonicalJSON.compact(try t.exportBundle(s)).utf8)
            cases.append(
                .init(name: "\(id)-updated", link: link, expect: "ready", bundle: "\(id)-updated.bundle.json"))

            // A password link.
            let p = try await t.center.create(
                t.controller.shareBundle(s), record: t.record(s), password: "correct horse")
            cases.append(
                .init(
                    name: "\(id)-password", link: t.center.link(p)!, expect: "password",
                    bundle: "\(id)-updated.bundle.json", password: "correct horse"))

            // Revoked, and expired.
            let v = try await t.center.create(t.controller.shareBundle(s), record: t.record(s), password: nil)
            let revoked = t.center.link(v)!
            try await t.center.revoke(v)
            cases.append(.init(name: "\(id)-revoked", link: revoked, expect: "off"))
            var e = t.record(s)
            e.expires = Date().addingTimeInterval(2)
            let x = try await t.center.create(t.controller.shareBundle(s), record: e, password: nil)
            // A bucket keeps the object (the viewer refuses it from the header); the server
            // refuses it itself. Either way the reader sees the link turned off.
            cases.append(
                .init(name: "\(id)-expired", link: t.center.link(x)!, expect: id == "minio" ? "expired" : "off"))
        }
        try await Task.sleep(for: .seconds(3))
        // Every request went where a destination is, and was logged.
        let hosts = Set(t.center.log.entries.map(\.host))
        #expect(hosts == ["127.0.0.1"])
        #expect(t.center.log.entries.allSatisfy { $0.status > 0 })
        try ShareCases.write(cases, files: files, to: ShareCases.web.appending(path: "share-live"))
    }
}
