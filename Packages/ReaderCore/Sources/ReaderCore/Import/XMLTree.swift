import Foundation

/// A minimal, namespace-tolerant XML tree built with `XMLParser`. Element and attribute names
/// are matched by local name (the part after any prefix), so `dc:title`, `opf:item` and
/// `title` all match `"title"`. External entities and DTDs are never resolved.
final class XMLNode {
    /// Local name, without any prefix.
    let name: String
    /// Attributes keyed by their name as written (`epub:type`, `href`).
    let attributes: [String: String]
    fileprivate(set) var content: [Content] = []

    enum Content {
        case element(XMLNode)
        case text(String)
    }

    init(qualifiedName: String, attributes: [String: String]) {
        name = XMLNode.localName(qualifiedName)
        self.attributes = attributes
    }

    static func localName(_ qualifiedName: String) -> String {
        guard let colon = qualifiedName.lastIndex(of: ":") else { return qualifiedName }
        return String(qualifiedName[qualifiedName.index(after: colon)...])
    }

    /// The attribute written exactly as `name`, else the first whose local name matches.
    func attribute(_ name: String) -> String? {
        if let value = attributes[name] { return value }
        let local = XMLNode.localName(name)
        return attributes.first { XMLNode.localName($0.key) == local }?.value
    }

    var elements: [XMLNode] {
        content.compactMap { if case let .element(node) = $0 { node } else { nil } }
    }

    func children(_ name: String) -> [XMLNode] { elements.filter { $0.name == name } }

    func child(_ name: String) -> XMLNode? { elements.first { $0.name == name } }

    /// Pre-order descendants with this local name (not including `self`).
    func descendants(_ name: String) -> [XMLNode] {
        var result: [XMLNode] = []
        for element in elements {
            if element.name == name { result.append(element) }
            result += element.descendants(name)
        }
        return result
    }

    /// The first pre-order descendant matching `predicate`, not looking inside elements named
    /// in `skipping`.
    func firstDescendant(where predicate: (XMLNode) -> Bool, skipping: Set<String> = []) -> XMLNode? {
        for element in elements {
            if predicate(element) { return element }
            if skipping.contains(element.name) { continue }
            if let found = element.firstDescendant(where: predicate, skipping: skipping) { return found }
        }
        return nil
    }

    /// All text inside, in document order.
    var text: String {
        content.map {
            switch $0 {
            case let .text(string): string
            case let .element(node): node.text
            }
        }.joined()
    }

    /// `text` with runs of whitespace collapsed to one space and trimmed.
    var collapsedText: String { XMLNode.collapse(text) }

    static func collapse(_ string: String) -> String {
        string.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

enum XMLTree {
    /// Elements nested deeper than this make the document malformed (keeps recursion bounded).
    static let maxDepth = 256

    /// The root element, or `nil` when the data is not well-formed XML.
    static func parse(_ data: Data) -> XMLNode? {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        let builder = Builder()
        parser.delegate = builder
        guard parser.parse(), !builder.failed else { return nil }
        return builder.root
    }

    /// Replaces the HTML named entities most often found in XHTML navigation documents with
    /// numeric references, since an XML parser without the XHTML DTD rejects them.
    static func replacingHTMLEntities(in data: Data) -> Data {
        guard var string = String(data: data, encoding: .utf8), string.contains("&") else { return data }
        let entities: [(String, String)] = [
            ("&nbsp;", "&#160;"), ("&ndash;", "&#8211;"), ("&mdash;", "&#8212;"), ("&hellip;", "&#8230;"),
            ("&lsquo;", "&#8216;"), ("&rsquo;", "&#8217;"), ("&ldquo;", "&#8220;"), ("&rdquo;", "&#8221;"),
            ("&copy;", "&#169;"), ("&shy;", "&#173;"), ("&middot;", "&#183;"), ("&laquo;", "&#171;"),
            ("&raquo;", "&#187;"), ("&thinsp;", "&#8201;"), ("&ensp;", "&#8194;"), ("&emsp;", "&#8195;"),
        ]
        for (name, numeric) in entities { string = string.replacingOccurrences(of: name, with: numeric) }
        return Data(string.utf8)
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: XMLNode?
        var stack: [XMLNode] = []
        var failed = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            guard stack.count < XMLTree.maxDepth else {
                failed = true
                parser.abortParsing()
                return
            }
            let node = XMLNode(qualifiedName: elementName, attributes: attributeDict)
            if let parent = stack.last {
                parent.content.append(.element(node))
            } else if root == nil {
                root = node
            }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.content.append(.text(string))
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if let string = String(data: CDATABlock, encoding: .utf8) { stack.last?.content.append(.text(string)) }
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            failed = true
        }
    }
}
