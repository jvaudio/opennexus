import Foundation
import Testing

@testable import NexusFormat
@testable import NexusInterchange

/// iOS reads XML with `MiniXML` (it has no `XMLDocument`); these check it reads every
/// XML the importers see exactly as Foundation's tree does (M47a).
@Suite struct MiniXMLTests {
    /// Every XML document among the fixtures, loose or inside a package.
    static func documents() throws -> [(String, Data)] {
        var out: [(String, Data)] = []
        let folder = testDir.appending(path: "Fixtures")
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path()).sorted() {
            let data = try Data(contentsOf: folder.appending(path: name))
            if let files = try? Zip.read(data) {
                for (path, d) in files.sorted(by: { $0.key < $1.key }) where path.hasSuffix(".xml") {
                    out.append(("\(name)/\(path)", d))
                }
            } else if data.prefix(64).contains(UInt8(ascii: "<")),
                name.hasSuffix(".opml") || name.hasSuffix(".mm")
                    || name.hasSuffix(".drawio")
            {
                out.append((name, data))
            }
        }
        // A drawio page compressed inside the file, and namespaced OPML extensions.
        out.append(
            (
                "namespaces",
                Data(
                    """
                    <opml version="2.0" xmlns:nexus="https://opennexus.app/ns/opml"><body>\
                    <outline text="A &amp; B" nexus:id="n1" nexus:note="x &lt; y"><outline text="C"/></outline>\
                    </body></opml>
                    """.utf8)
            ))
        out.append(("cdata", Data("<a>one <b>two</b><![CDATA[ <three> ]]> four<br/>five</a>".utf8)))
        return out
    }

    func same(_ f: XMLElement, _ m: MiniXMLElement, _ path: String) {
        #expect(f.name == m.name, "\(path) name")
        #expect(f.localName == m.localName, "\(path) localName")
        #expect(
            f.stringValue == m.stringValue,
            "\(path) stringValue \(String(reflecting: f.stringValue?.prefix(60))) vs \(String(reflecting: m.stringValue?.prefix(60)))"
        )
        #expect(DrawIOFormat.plain(f.xmlString) == DrawIOFormat.plain(m.xmlString), "\(path) plain text")
        let fa = (f.attributes ?? []).map { "\($0.name ?? "")=\($0.stringValue ?? "")" }.sorted()
        let ma = (m.attributes ?? []).map { "\($0.name ?? "")=\($0.stringValue ?? "")" }.sorted()
        #expect(fa == ma, "\(path) attributes")
        for a in f.attributes ?? [] {
            let local = a.localName ?? ""
            #expect(m.attribute(forName: a.name ?? "")?.stringValue == a.stringValue, "\(path) @\(a.name ?? "")")
            #expect(
                m.attribute(forLocalName: local, uri: a.uri)?.stringValue
                    == f.attribute(forLocalName: local, uri: a.uri)?.stringValue,
                "\(path) @{\(a.uri ?? "")}\(local)")
        }
        let fk = f.kids()
        let mk = (m.children ?? []).compactMap { $0 as? MiniXMLElement }
        #expect(fk.count == mk.count, "\(path) children")
        for (i, (a, b)) in zip(fk, mk).enumerated() { same(a, b, "\(path)/\(i):\(a.name ?? "")") }
    }

    @Test func readsEveryFixtureAsFoundationDoes() throws {
        let docs = try Self.documents()
        #expect(docs.count >= 8)
        for (name, data) in docs {
            let f = try? XMLDocument(data: data, options: [.nodePreserveWhitespace]).rootElement()
            let m = MiniXML.parse(data)
            if f == nil, m == nil { continue }
            guard let f, let m else {
                Issue.record("\(name): Foundation \(f != nil), MiniXML \(m != nil)")
                continue
            }
            same(f, m, name)
        }
    }

    @Test func rejectsWhatFoundationRejects() {
        for bad in ["<a><b></a>", "", "not xml", "<a x=\"1\" x=\"2\"/>"] {
            let data = Data(bad.utf8)
            #expect((try? XMLDocument(data: data, options: [])) == nil, "\(bad)")
            #expect(MiniXML.parse(data) == nil, "\(bad)")
        }
    }
}
