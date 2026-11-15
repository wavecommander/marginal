import Foundation

/// A parsed XML element: local name (namespace prefix dropped), direct text and children.
struct S3XMLElement: Sendable, Equatable {
    var name: String
    var text: String = ""
    var children: [S3XMLElement] = []

    func child(_ name: String) -> S3XMLElement? { children.first { $0.name == name } }
    func children(_ name: String) -> [S3XMLElement] { children.filter { $0.name == name } }
    func string(_ name: String) -> String? { child(name)?.text }
}

/// The S3 XML documents S3Kit reads and writes. Parsing goes through Foundation's `XMLParser`
/// with namespaces processed (so `xmlns` and prefixes don't matter), external entities off, and
/// unknown elements ignored.
enum S3XML {
    struct ServiceError: Sendable, Equatable {
        var code: String
        var message: String?
    }

    struct ListPage: Sendable, Equatable {
        var objects: [S3ObjectSummary]
        var isTruncated: Bool
        var nextContinuationToken: String?
    }

    enum CompleteResult: Sendable, Equatable {
        case completed(eTag: String?)
        case failed(ServiceError)
    }

    enum ParseError: Error { case malformed, unexpectedRoot(String) }

    // MARK: Parsing

    /// Parses `data`. Leading whitespace is skipped first: `CompleteMultipartUpload` sends spaces
    /// to keep the connection alive before its XML declaration.
    static func parse(_ data: Data) throws -> S3XMLElement {
        let start = data.firstIndex { ![0x20, 0x09, 0x0A, 0x0D].contains($0) } ?? data.endIndex
        let trimmed = data[start...]
        guard !trimmed.isEmpty else { throw ParseError.malformed }
        let parser = XMLParser(data: Data(trimmed))
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        let builder = TreeBuilder()
        parser.delegate = builder
        guard parser.parse(), let root = builder.root else { throw ParseError.malformed }
        return root
    }

    /// The `<Error>` document in `body`, or `nil` when it isn't one.
    static func serviceError(from body: Data) -> ServiceError? {
        guard let root = try? parse(body) else { return nil }
        return serviceError(in: root)
    }

    static func serviceError(in root: S3XMLElement) -> ServiceError? {
        guard root.name == "Error", let code = root.string("Code")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else { return nil }
        return ServiceError(code: code, message: root.string("Message"))
    }

    /// A `ListBucketResult` (ListObjectsV2) page. Keys are returned as stored (no `encoding-type`).
    static func listPage(from data: Data) throws -> ListPage {
        let root = try parse(data)
        guard root.name == "ListBucketResult" else { throw ParseError.unexpectedRoot(root.name) }
        let objects = try root.children("Contents").map { contents -> S3ObjectSummary in
            guard let key = contents.string("Key"),
                  let size = contents.string("Size").flatMap({ Int64($0.trimmingCharacters(in: .whitespaces)) })
            else { throw ParseError.malformed }
            return S3ObjectSummary(key: key, size: size,
                                   lastModified: contents.string("LastModified").flatMap(parseISO8601),
                                   eTag: contents.string("ETag"))
        }
        let truncated = root.string("IsTruncated")?.trimmingCharacters(in: .whitespaces).lowercased() == "true"
        let token = root.string("NextContinuationToken").flatMap { $0.isEmpty ? nil : $0 }
        return ListPage(objects: objects, isTruncated: truncated, nextContinuationToken: token)
    }

    /// The `UploadId` of an `InitiateMultipartUploadResult`.
    static func uploadID(from data: Data) throws -> String {
        let root = try parse(data)
        guard root.name == "InitiateMultipartUploadResult" else { throw ParseError.unexpectedRoot(root.name) }
        guard let id = root.string("UploadId"), !id.isEmpty else { throw ParseError.malformed }
        return id
    }

    /// A `CompleteMultipartUpload` response body, which may be an `<Error>` despite HTTP 200.
    static func completeResult(from data: Data) throws -> CompleteResult {
        let root = try parse(data)
        if root.name == "Error" {
            return .failed(serviceError(in: root) ?? ServiceError(code: "Error", message: nil))
        }
        guard root.name == "CompleteMultipartUploadResult" else { throw ParseError.unexpectedRoot(root.name) }
        return .completed(eTag: root.string("ETag"))
    }

    // MARK: Building

    /// The `CompleteMultipartUpload` request body, parts in the order given (ascending part number).
    static func completeBody(parts: [(number: Int, eTag: String)]) -> Data {
        var xml = #"<?xml version="1.0" encoding="UTF-8"?>"#
        xml += #"<CompleteMultipartUpload xmlns="http://s3.amazonaws.com/doc/2006-03-01/">"#
        for part in parts {
            xml += "<Part><ETag>\(escape(part.eTag))</ETag><PartNumber>\(part.number)</PartNumber></Part>"
        }
        xml += "</CompleteMultipartUpload>"
        return Data(xml.utf8)
    }

    /// Escapes text content: `&`, `<`, `>`, and both quote characters.
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default: result.append(character)
            }
        }
        return result
    }

    static func parseISO8601(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }

    private final class TreeBuilder: NSObject, XMLParserDelegate {
        var stack: [S3XMLElement] = []
        var root: S3XMLElement?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            stack.append(S3XMLElement(name: local))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard !stack.isEmpty, let string = String(data: CDATABlock, encoding: .utf8) else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            guard let element = stack.popLast() else { return }
            if stack.isEmpty { root = element } else { stack[stack.count - 1].children.append(element) }
        }
    }
}
