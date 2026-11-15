import Foundation

// Plain text for the text-family converters: finding the encoding, and turning text into HTML
// the web renderer can lay out on the app's page. See docs/FORMAT_IMPORT_PLAN.md, "Text,
// Markdown, HTML".

nonisolated enum WebTextDecoding {
    /// The text of `data` and the encoding it was read as, or `nil` when the bytes are not text
    /// (NUL bytes outside UTF-16/32). Order: a byte-order mark; strict UTF-8; UTF-16 without a
    /// mark (every other byte zero, the way ASCII looks in UTF-16); Windows-1252, then Latin-1,
    /// which accept any byte.
    static func decode(_ data: Data) -> (text: String, encoding: String.Encoding)? {
        let bytes = [UInt8](data.prefix(4))
        func starts(_ prefix: [UInt8]) -> Bool { bytes.starts(with: prefix) }
        if starts([0xEF, 0xBB, 0xBF]), let text = String(data: data.dropFirst(3), encoding: .utf8) { return (text, .utf8) }
        if starts([0xFF, 0xFE, 0x00, 0x00]), let text = String(data: data.dropFirst(4), encoding: .utf32LittleEndian) { return (text, .utf32LittleEndian) }
        if starts([0x00, 0x00, 0xFE, 0xFF]), let text = String(data: data.dropFirst(4), encoding: .utf32BigEndian) { return (text, .utf32BigEndian) }
        if starts([0xFF, 0xFE]), let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) { return (text, .utf16LittleEndian) }
        if starts([0xFE, 0xFF]), let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) { return (text, .utf16BigEndian) }
        let hasNUL = data.contains(0)
        if !hasNUL, let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        if hasNUL {
            guard let order = utf16ByteOrder(data),
                  let text = String(data: data, encoding: order), !text.contains("\u{0}") else { return nil }
            return (text, order)
        }
        if let text = String(data: data, encoding: .windowsCP1252) { return (text, .windowsCP1252) }
        if let text = String(data: data, encoding: .isoLatin1) { return (text, .isoLatin1) }
        return nil
    }

    /// UTF-16 without a byte-order mark: mostly-ASCII text has a zero in every other byte.
    static func utf16ByteOrder(_ data: Data) -> String.Encoding? {
        let sample = [UInt8](data.prefix(4096))
        let pairs = sample.count / 2
        guard pairs >= 2 else { return nil }
        var evenZeros = 0, oddZeros = 0
        for index in 0..<pairs {
            let (even, odd) = (sample[2 * index], sample[2 * index + 1])
            if even == 0, odd == 0 { return nil }
            if even == 0 { evenZeros += 1 }
            if odd == 0 { oddZeros += 1 }
        }
        if oddZeros * 10 >= pairs * 7, evenZeros == 0 { return .utf16LittleEndian }
        if evenZeros * 10 >= pairs * 7, oddZeros == 0 { return .utf16BigEndian }
        return nil
    }

    /// Whether `data` declares its own character set near the start (an HTML `<meta charset>`
    /// or `http-equiv` content type, or an XML declaration with an encoding).
    static func declaresCharset(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        return head.contains("charset=") || head.contains("charset =") || head.range(of: #"<\?xml[^>]*encoding="#, options: .regularExpression) != nil
    }

    static func escapeHTML(_ text: some StringProtocol) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }
}

/// Plain text as HTML. Decisions the plan left open:
/// - Paragraphs are separated by blank lines. Inside a paragraph, a line break is kept unless
///   the text is hard-wrapped (most lines end near the same column, 50–100 characters) and the
///   line reached that column: such breaks only wrapped the text, so the line is joined to the
///   next and the paragraph flows on the page. Short lines (verse, addresses, lists) keep their
///   breaks.
/// - Text laid out with spaces (tables, ASCII art, code: runs of three spaces inside lines, tabs
///   or box-drawing characters on a fifth of the lines) is set in a monospaced face with every
///   line and space kept.
/// - Long paragraphs are emitted in blocks of at most 40 lines so that a long document can be
///   printed in segments (`WebPDFRenderer.planSegments` cuts only between blocks).
nonisolated enum PlainTextHTML {
    static let blockLines = 40

    static func html(_ text: String, title: String?) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n").map { line in
            // Trailing spaces never matter; a form feed is a page break in old text files.
            String(line.replacingOccurrences(of: "\u{0C}", with: "").reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
        }
        let body = isPreformatted(lines) ? preformatted(lines) : prose(lines)
        return document(body: body, title: title, bodyClass: "tt-plain")
    }

    static func document(body: String, title: String?, bodyClass: String) -> String {
        let titleTag = title.map { "<title>\(WebTextDecoding.escapeHTML($0))</title>" } ?? ""
        return """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8">\(titleTag)</head>
            <body class="\(bodyClass)">
            \(body)
            </body></html>
            """
    }

    static func isPreformatted(_ lines: [String]) -> Bool {
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !content.isEmpty else { return false }
        let laidOut = content.filter { line in
            line.contains("\t")
                || line.unicodeScalars.contains { (0x2500...0x257F).contains($0.value) }
                || line.trimmingCharacters(in: .whitespaces).contains("   ")
        }
        return laidOut.count * 5 >= content.count
    }

    /// The column most lines were wrapped at, or `nil` when the text is not hard-wrapped.
    static func wrapColumn(_ lines: [String]) -> Int? {
        let lengths = lines.map(\.count).filter { $0 > 0 }.sorted()
        guard lengths.count >= 8 else { return nil }
        let column = lengths[Int(Double(lengths.count - 1) * 0.9)]
        guard (50...100).contains(column) else { return nil }
        // Most non-final lines of paragraphs reach near the column in wrapped text.
        let near = lengths.filter { $0 >= column - 15 }.count
        return near * 3 >= lengths.count ? column : nil
    }

    static func prose(_ lines: [String]) -> String {
        let column = wrapColumn(lines)
        var paragraphs: [[String]] = []
        var current: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { paragraphs.append(current); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        var out: [String] = []
        for paragraph in paragraphs {
            var chunks: [[String]] = []
            var index = 0
            while index < paragraph.count {
                chunks.append(Array(paragraph[index..<min(paragraph.count, index + blockLines)]))
                index += blockLines
            }
            for (number, chunk) in chunks.enumerated() {
                var html = ""
                for (offset, line) in chunk.enumerated() {
                    html += WebTextDecoding.escapeHTML(line.trimmingCharacters(in: .whitespaces))
                    guard offset < chunk.count - 1 else { break }
                    let next = chunk[offset + 1]
                    let soft = column.map { line.count >= $0 - 15 && !next.hasPrefix(" ") && !next.hasPrefix("\t") } ?? false
                    html += soft ? " " : "<br>"
                }
                let cls = number < chunks.count - 1 ? " class=\"tt-cont\"" : ""
                out.append("<p\(cls)>\(html)</p>")
            }
        }
        return out.joined(separator: "\n")
    }

    static func preformatted(_ lines: [String]) -> String {
        var out: [String] = []
        var index = 0
        // Trailing blank lines would print an empty page.
        var end = lines.count
        while end > 0, lines[end - 1].isEmpty { end -= 1 }
        while index < end {
            let chunk = lines[index..<min(end, index + blockLines)]
            out.append("<pre class=\"tt-pre\">" + chunk.map(WebTextDecoding.escapeHTML).joined(separator: "\n") + "</pre>")
            index += blockLines
        }
        return out.joined(separator: "\n")
    }
}
