import Foundation

/// The part of Foundation's XML tree (`XMLDocument`, `XMLElement`) the importers use,
/// built with `XMLParser`, for platforms without the tree (iOS). The Mac keeps
/// Foundation's; `MiniXMLTests` checks the two read every fixture the same way.
///
/// Like Foundation's, it hides text that is only whitespace from `children` and
/// `stringValue` (but writes it in `xmlString`), and counts comments in `stringValue`.
/// Unlike it, attributes come in name order (the parser reports them unordered) and
/// processing instructions are dropped.
public class MiniXMLNode {
    /// The qualified name (`prefix:local`); nil for text.
    public var name: String?
    public var localName: String?
    /// For attributes: the namespace their prefix maps to.
    var uri: String?
    var text: String
    /// Text from a CDATA section or a comment isn't joined to the text beside it; text
    /// that is only whitespace is `blank`.
    var kind: Kind = .text

    enum Kind { case text, cdata, comment, blank }

    init(name: String?, localName: String?, uri: String? = nil, text: String = "", kind: Kind = .text) {
        self.name = name
        self.localName = localName
        self.uri = uri
        self.text = text
        self.kind = kind
    }

    /// Text, an attribute's value, or an element's text and its descendants'.
    public var stringValue: String? { text }

    /// The node as XML.
    public var xmlString: String {
        switch kind {
        case .text, .cdata, .blank: MiniXML.escape(text, attribute: false)
        case .comment: "<!--\(text)-->"
        }
    }
}

public final class MiniXMLElement: MiniXMLNode {
    var kids: [MiniXMLNode] = []
    var attrs: [MiniXMLNode] = []

    public init(name: String) {
        super.init(name: name, localName: name.split(separator: ":").last.map(String.init) ?? name)
    }

    public var children: [MiniXMLNode]? {
        let shown = kids.filter { $0.kind != .blank }
        return shown.isEmpty ? nil : shown
    }
    public var attributes: [MiniXMLNode]? { attrs.isEmpty ? nil : attrs }

    public func attribute(forName name: String) -> MiniXMLNode? { attrs.first { $0.name == name } }

    public func attribute(forLocalName localName: String, uri: String?) -> MiniXMLNode? {
        attrs.first { $0.localName == localName && $0.uri == uri }
    }

    public override var stringValue: String? {
        kids.map { ($0 as? MiniXMLElement)?.stringValue ?? ($0.kind == .blank ? "" : $0.text) }.joined()
    }

    public override var xmlString: String {
        let n = name ?? ""
        var s = "<" + n
        for a in attrs { s += " \(a.name ?? "")=\"\(MiniXML.escape(a.text, attribute: true))\"" }
        s += ">"
        for k in kids { s += k.xmlString }
        return s + "</\(n)>"
    }
}

public enum MiniXML {
    /// The root element, or nil if the data isn't well-formed XML. External entities are
    /// never fetched.
    public static func parse(_ data: Data) -> MiniXMLElement? {
        let parser = XMLParser(data: data)
        let builder = Builder()
        parser.delegate = builder
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return nil }
        return builder.root
    }

    static func escape(_ s: String, attribute: Bool) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"" where attribute: out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    final class Builder: NSObject, XMLParserDelegate {
        var root: MiniXMLElement?
        var stack: [MiniXMLElement] = []
        /// Prefix → namespace URI, innermost mapping last.
        var prefixes: [String: [String]] = [:]

        func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI uri: String) {
            prefixes[prefix, default: []].append(uri)
        }

        func parser(_ parser: XMLParser, didEndMappingPrefix prefix: String) {
            _ = prefixes[prefix]?.popLast()
        }

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            let e = MiniXMLElement(name: qualifiedName ?? elementName)
            e.localName = elementName
            for (k, v) in attributes.sorted(by: { $0.key < $1.key }) {
                let parts = k.split(separator: ":", maxSplits: 1).map(String.init)
                let local = parts.count == 2 ? parts[1] : k
                let uri = parts.count == 2 ? prefixes[parts[0]]?.last : nil
                e.attrs.append(MiniXMLNode(name: k, localName: local, uri: uri, text: v))
            }
            if let parent = stack.last { parent.kids.append(e) } else { root = e }
            stack.append(e)
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?
        ) {
            // Whitespace-only text is hidden, as in Foundation's tree.
            for n in stack.popLast()?.kids ?? [] where !(n is MiniXMLElement) && n.kind != .comment {
                if n.text.allSatisfy({ " \t\n\r".contains($0) }) { n.kind = .blank }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { append(string, .text) }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            append(String(decoding: CDATABlock, as: UTF8.self), .cdata)
        }

        func parser(_ parser: XMLParser, foundComment comment: String) { append(comment, .comment) }

        /// Text reported in pieces (around entities) joins one node.
        func append(_ s: String, _ kind: MiniXMLNode.Kind) {
            guard let e = stack.last else { return }
            if kind == .text, let last = e.kids.last, !(last is MiniXMLElement), last.kind == .text {
                last.text += s
            } else {
                e.kids.append(MiniXMLNode(name: nil, localName: nil, text: s, kind: kind))
            }
        }
    }
}
