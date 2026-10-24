import Foundation

/// A light XML tree for Word parts: element names without their prefix, attributes by local name
/// (relationship attributes keep theirs: `r:id`, `r:embed`), text gathered per element.
final class ConverterXMLNode {
    let name: String
    let attrs: [String: String]
    var children: [ConverterXMLNode] = []
    var text = ""

    init(name: String, attrs: [String: String]) {
        self.name = name
        self.attrs = attrs
    }

    subscript(_ attribute: String) -> String? { attrs[attribute] }
    var val: String? { attrs["val"] }

    func child(_ n: String) -> ConverterXMLNode? { children.first { $0.name == n } }
    func all(_ n: String) -> [ConverterXMLNode] { children.filter { $0.name == n } }

    /// First descendant with this name, depth first.
    func find(_ n: String) -> ConverterXMLNode? {
        for c in children {
            if c.name == n { return c }
            if let found = c.find(n) { return found }
        }
        return nil
    }

    /// A Word on/off property (`<w:b/>`, `<w:b w:val="0"/>`), nil when absent.
    func flag(_ n: String) -> Bool? {
        guard let c = child(n) else { return nil }
        guard let v = c.val else { return true }
        return !["0", "false", "off", "none"].contains(v)
    }

    static func parse(_ data: Data) -> ConverterXMLNode? {
        let reader = ConverterXMLReader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        return parser.parse() ? reader.root : nil
    }
}

private final class ConverterXMLReader: NSObject, XMLParserDelegate {
    var root: ConverterXMLNode?
    private var stack: [ConverterXMLNode] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        var attrs: [String: String] = [:]
        for (key, value) in attributes {
            if key.hasPrefix("xmlns") { continue }
            if key.hasPrefix("r:") { attrs[key] = value; continue }
            attrs[key.firstIndex(of: ":").map { String(key[key.index(after: $0)...]) } ?? key] = value
        }
        let local = elementName.firstIndex(of: ":").map { String(elementName[elementName.index(after: $0)...]) } ?? elementName
        let node = ConverterXMLNode(name: local, attrs: attrs)
        stack.last?.children.append(node)
        if root == nil { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        _ = stack.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }
}
