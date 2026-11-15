// Deterministic fixture PDF generator (macOS). Usage:
//   swiftc -O -o /tmp/make-fixtures Fixtures/make-fixtures.swift && /tmp/make-fixtures <outdir>
// (scripts/fixtures.sh wraps this.) Writes small.pdf, links.pdf, large.pdf, no-outline.pdf, then verifies
// them with PDFKit and exits non-zero on any mismatch.
import CoreGraphics
import CoreText
import Foundation
import PDFKit

struct Entry {
    var title: String
    var level: Int  // 0 = chapter
    var page: Int  // 1-based
}

/// A link inside the PDF: a labelled box on `page` that goes to `target`'s page-space `targetY`.
struct Link {
    var page: Int  // 1-based
    var y: CGFloat  // page-space y of the box's bottom edge
    var label: String
    var target: Int  // 1-based
    var targetY: CGFloat
    /// A GoTo action (`/A`) instead of a plain destination (`/Dest`); real PDFs use both.
    var asAction = false

    var rect: CGRect { CGRect(x: margin, y: y, width: 260, height: 24) }
}

struct Spec {
    var file: String
    var pages: Int
    var entries: [Entry]
    var runningHeader: String
    /// page -> extra sentence appended to that page's first paragraph
    var specials: [Int: String] = [:]
    var links: [Link] = []
}

// MARK: deterministic text

struct LCG {
    var state: UInt64
    mutating func next() -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int(truncatingIfNeeded: state >> 33)
    }
}

let words = """
the of a matrix vector space linear basis dimension kernel image rank transformation \
eigenvalue characteristic polynomial determinant orthogonal projection inner product norm \
theorem lemma proof corollary definition example consider suppose then therefore hence \
every each some any if only whenever whose which where that this these those such \
function map set subset field scalar sum product inverse transpose diagonal symmetric \
solution equation system variable coefficient row column pivot reduction elimination \
independent spanning subspace complement decomposition factorization similar invariant \
we show prove compute verify observe note recall define denote assume obtain conclude
""".split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\\" }).map(String.init).filter { !$0.isEmpty }

func sentence(_ rng: inout LCG) -> String {
    let n = 8 + rng.next() % 9
    var parts: [String] = []
    for _ in 0..<n { parts.append(words[rng.next() % words.count]) }
    var s = parts.joined(separator: " ")
    s = s.prefix(1).uppercased() + s.dropFirst() + "."
    return s
}

func paragraph(_ rng: inout LCG, sentences: Int) -> String {
    (0..<sentences).map { _ in sentence(&rng) }.joined(separator: " ")
}

// MARK: drawing

let pageW: CGFloat = 612, pageH: CGFloat = 792
let margin: CGFloat = 72

func font(_ name: String, _ size: CGFloat) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }

func drawLine(_ ctx: CGContext, _ text: String, font f: CTFont, at p: CGPoint) {
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): f,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    ctx.textPosition = p
    CTLineDraw(line, ctx)
}

func drawBody(_ ctx: CGContext, _ text: String, in rect: CGRect) {
    var spacing = CGFloat(9)
    var lineAdj = CGFloat(2)
    let style = withUnsafeBytes(of: &spacing) { sp in
        withUnsafeBytes(of: &lineAdj) { la in
            CTParagraphStyleCreate(
                [
                    CTParagraphStyleSetting(
                        spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size, value: sp.baseAddress!),
                    CTParagraphStyleSetting(
                        spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: la.baseAddress!),
                ], 2)
        }
    }
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font("Times-Roman", 11),
        NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]
    let fs = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    let path = CGPath(rect: rect, transform: nil)
    CTFrameDraw(CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), path, nil), ctx)
}

func chapterTitle(of page: Int, entries: [Entry]) -> String? {
    entries.last(where: { $0.level == 0 && $0.page <= page })?.title
}

func render(_ spec: Spec) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: pageW, height: pageH)
    let consumer = CGDataConsumer(data: data as CFMutableData)!
    let info = [kCGPDFContextTitle as String: spec.file] as CFDictionary
    let ctx = CGContext(consumer: consumer, mediaBox: &box, info)!
    for page in 1...spec.pages {
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 0.6, alpha: 1))
        // Running header and rule.
        let header = chapterTitle(of: page, entries: spec.entries).map { "\(spec.runningHeader)  |  \($0)" }
            ?? spec.runningHeader
        drawLine(ctx, header, font: font("Helvetica", 9), at: CGPoint(x: margin, y: pageH - 44))
        ctx.move(to: CGPoint(x: margin, y: pageH - 50))
        ctx.addLine(to: CGPoint(x: pageW - margin, y: pageH - 50))
        ctx.strokePath()
        // Headings that start on this page.
        var y = pageH - 96
        for e in spec.entries where e.page == page {
            let size: CGFloat = e.level == 0 ? 24 : (e.level == 1 ? 17 : 13)
            drawLine(ctx, e.title, font: font("Helvetica-Bold", size), at: CGPoint(x: margin, y: y))
            y -= size + 14
        }
        // Body text.
        var rng = LCG(state: UInt64(page) &* 2654435761 &+ 12345)
        var paras: [String] = []
        for i in 0..<4 {
            var p = paragraph(&rng, sentences: 5 + rng.next() % 3)
            if i == 0, let extra = spec.specials[page] { p = extra + "\n" + p }
            paras.append(p)
        }
        drawBody(ctx, paras.joined(separator: "\n"),
                 in: CGRect(x: margin, y: 90, width: pageW - 2 * margin, height: y - 90))
        // Link boxes, over the body text.
        for link in spec.links where link.page == page {
            ctx.setFillColor(CGColor(red: 0.9, green: 0.94, blue: 1, alpha: 1))
            ctx.fill(link.rect)
            ctx.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1))
            drawLine(ctx, link.label, font: font("Helvetica", 12), at: CGPoint(x: link.rect.minX + 6, y: link.rect.minY + 7))
        }
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
        // Footer.
        drawLine(ctx, "Fixture page \(page)", font: font("Helvetica", 9),
                 at: CGPoint(x: margin, y: 54))
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return data as Data
}

// MARK: outline + output

func write(_ spec: Spec, to dir: URL) throws {
    let doc = PDFDocument(data: render(spec))!
    if !spec.entries.isEmpty {
        let root = PDFOutline()
        var stack: [PDFOutline] = [root]  // stack[level] is the parent for level
        var counts: [ObjectIdentifier: Int] = [:]
        for e in spec.entries {
            let node = PDFOutline()
            node.label = e.title
            node.destination = PDFDestination(
                page: doc.page(at: e.page - 1)!, at: CGPoint(x: 0, y: pageH))
            let parent = stack[e.level]
            parent.insertChild(node, at: counts[ObjectIdentifier(parent), default: 0])
            counts[ObjectIdentifier(parent), default: 0] += 1
            stack = Array(stack.prefix(e.level + 1)) + [node]
        }
        doc.outlineRoot = root
    }
    for link in spec.links {
        let annotation = PDFAnnotation(bounds: link.rect, forType: .link, withProperties: nil)
        let destination = PDFDestination(page: doc.page(at: link.target - 1)!, at: CGPoint(x: 0, y: link.targetY))
        if link.asAction {
            annotation.action = PDFActionGoTo(destination: destination)
        } else {
            annotation.destination = destination
        }
        doc.page(at: link.page - 1)!.addAnnotation(annotation)
    }
    let url = dir.appendingPathComponent(spec.file)
    guard doc.write(to: url) else { throw NSError(domain: "fixtures", code: 1) }
}

// MARK: specs

let smallSpec: Spec = {
    var e: [Entry] = []
    let chapters = [(1, "Linear Systems"), (5, "Vector Spaces"), (9, "Eigenvalues")]
    for (i, c) in chapters.enumerated() {
        e.append(Entry(title: "\(i + 1) \(c.1)", level: 0, page: c.0))
        e.append(Entry(title: "\(i + 1).1 Foundations", level: 1, page: c.0 + 1))
        e.append(Entry(title: "\(i + 1).2 Exercises", level: 1, page: c.0 + 3))
    }
    return Spec(file: "small.pdf", pages: 12, entries: e, runningHeader: "Small Fixture Textbook",
                specials: [3: "Remember that the quick amber fox annotates margins."])
}()

/// `small.pdf`'s pages and outline plus links between sections (section history tests).
let linksSpec: Spec = {
    var spec = smallSpec
    spec.file = "links.pdf"
    spec.runningHeader = "Linked Fixture Textbook"
    spec.specials = [:]
    spec.links = [
        Link(page: 7, y: 120, label: "Link: start of 2.1 Foundations", target: 6, targetY: pageH, asAction: true),
        Link(page: 7, y: 200, label: "Link: 3.2 Exercises", target: 12, targetY: pageH),
        Link(page: 3, y: 400, label: "Link: middle of page 7", target: 7, targetY: 450, asAction: true),
    ]
    return spec
}()

let largeSpec: Spec = {
    var e: [Entry] = []
    let chapterNames = ["Linear Systems", "Vector Spaces", "Linear Maps", "Determinants", "Eigenvalues",
                        "Inner Products", "Orthogonality", "Decompositions", "Quadratic Forms",
                        "Jordan Form", "Tensors", "Duality", "Modules", "Numerical Methods", "Applications"]
    let sectionNames = ["Foundations", "Key Results", "Computation", "Structure", "Further Topics"]
    let subNames = ["Definitions", "Worked Examples", "Summary"]
    let pagesPerChapter = 100
    for (c, name) in chapterNames.enumerated() {
        let cStart = c * pagesPerChapter + 1
        e.append(Entry(title: "\(c + 1) \(name)", level: 0, page: cStart))
        let sectionCount = 6  // five named plus a final "Exercises"
        let secLen = pagesPerChapter / sectionCount
        for s in 0..<sectionCount {
            let sStart = cStart + s * secLen + 1
            let sTitle = s == sectionCount - 1 ? "Exercises" : "\(c + 1).\(s + 1) \(sectionNames[s])"
            e.append(Entry(title: sTitle, level: 1, page: sStart))
            for u in 0..<3 {
                let uTitle = s == sectionCount - 1 ? "Set \(u + 1)" : "\(c + 1).\(s + 1).\(u + 1) \(subNames[u])"
                e.append(Entry(title: uTitle, level: 2, page: sStart + u * 4 + 1))
            }
        }
    }
    return Spec(file: "large.pdf", pages: 1500, entries: e, runningHeader: "Large Fixture Textbook",
                specials: [1400: "This is the zygomorphic lighthouse theorem."])
}()

let noOutlineSpec = Spec(file: "no-outline.pdf", pages: 40, entries: [], runningHeader: "Unstructured Fixture Notes")

// MARK: link-forms.pdf (hand-written bytes)
//
// Real textbooks encode links in ways PDFKit's writer normalises away (LaTeX hyperref's named
// destinations, InDesign's name tree, /Fit and null-coordinate /XYZ views, named actions), so
// this file is written byte by byte. Same pages and outline as `small.pdf`; the outline items
// themselves use hyperref's `/A << /S /GoTo /D (name) >>`. Section-history tests follow these
// links (`linkFormsLinks` lists them with the page each one lands on).

/// A link of `link-forms.pdf`: a labelled box on `page` whose annotation carries `entry`
/// (`/Dest …` or `/A …`, with `P<n>` standing for page n's object reference).
struct RawLink {
    var page: Int  // 1-based
    var y: CGFloat  // page-space y of the box's bottom edge
    var label: String
    var entry: String
    var target: Int?  // 1-based page it lands on; nil for an external link

    var rect: CGRect { CGRect(x: margin, y: y, width: 300, height: 24) }
}

/// Named destinations: name -> (page, view, written as `<< /D [...] >>` rather than `[...]`).
let linkFormsCatalogDests: [String: (page: Int, view: String)] = [
    "sec22": (8, "/XYZ 0 600 null"),
    "ch2": (5, "/XYZ null null null"),
]
let linkFormsNameTreeDests: [String: (page: Int, view: String, asDict: Bool)] = {
    var dests: [String: (page: Int, view: String, asDict: Bool)] = [
        "sec31": (10, "/FitH 792", false),
        "section.3.2": (12, "/XYZ 72 792 null", true),
        "section.1.2": (4, "/XYZ 72 720 null", false),
    ]
    for (i, e) in smallSpec.entries.enumerated() { dests["toc.\(i)"] = (e.page, "/XYZ 0 792 null", false) }
    return dests
}()

let linkFormsLinks: [RawLink] = [
    RawLink(page: 3, y: 610, label: "Dest array -> 2.1 Foundations", entry: "/Dest [P6 /XYZ 0 792 0]", target: 6),
    RawLink(page: 3, y: 570, label: "Dest name, catalog Dests -> 2.2 Exercises", entry: "/Dest /sec22", target: 8),
    RawLink(page: 3, y: 530, label: "Dest string, name tree -> 3.1 Foundations", entry: "/Dest (sec31)", target: 10),
    RawLink(page: 3, y: 490, label: "GoTo named (hyperref) -> 3.2 Exercises", entry: "/A << /S /GoTo /D (section.3.2) >>", target: 12),
    RawLink(page: 3, y: 450, label: "GoTo array /Fit -> 3 Eigenvalues", entry: "/A << /S /GoTo /D [P9 /Fit] >>", target: 9),
    RawLink(page: 3, y: 410, label: "GoTo array XYZ null -> page 11", entry: "/A << /S /GoTo /D [P11 /XYZ null null null] >>", target: 11),
    RawLink(page: 3, y: 370, label: "GoTo name object -> 2 Vector Spaces", entry: "/A << /S /GoTo /D /ch2 >>", target: 5),
    RawLink(page: 3, y: 330, label: "Named NextPage -> 1.2 Exercises", entry: "/A << /S /Named /N /NextPage >>", target: 4),
    RawLink(page: 3, y: 290, label: "URL (external, example.com)", entry: "/A << /S /URI /URI (https://example.com/) >>", target: nil),
    // On the targets, for link -> link chains.
    RawLink(page: 6, y: 640, label: "GoTo named (hyperref) -> 3.2 Exercises", entry: "/A << /S /GoTo /D (section.3.2) >>", target: 12),
    RawLink(page: 12, y: 640, label: "Dest string, name tree -> 1.2 Exercises", entry: "/Dest (section.1.2)", target: 4),
]

/// Builds a PDF from numbered object bodies (1-based) with a classic xref table.
struct RawPDF {
    private(set) var bodies: [String] = []
    mutating func reserve() -> Int { bodies.append(""); return bodies.count }
    mutating func set(_ number: Int, _ body: String) { bodies[number - 1] = body }
    mutating func add(_ body: String) -> Int { let n = reserve(); set(n, body); return n }
    mutating func addStream(_ content: String) -> Int {
        add("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
    }
    func data(root: Int, info: Int) -> Data {
        var out = Data("%PDF-1.7\n%".utf8) + Data([0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        var offsets: [Int] = []
        for (i, body) in bodies.enumerated() {
            offsets.append(out.count)
            out += Data("\(i + 1) 0 obj\n\(body)\nendobj\n".utf8)
        }
        let xref = out.count
        var table = "xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(bodies.count + 1) /Root \(root) 0 R /Info \(info) 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return out + Data(table.utf8)
    }
}

func pdfString(_ s: String) -> String {
    "(" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "(", with: "\\(")
        .replacingOccurrences(of: ")", with: "\\)") + ")"
}

func writeLinkForms(to dir: URL) throws {
    let spec = smallSpec
    var pdf = RawPDF()
    let catalog = pdf.reserve(), pages = pdf.reserve(), outlines = pdf.reserve()
    let regular = pdf.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    let bold = pdf.add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>")
    let serif = pdf.add("<< /Type /Font /Subtype /Type1 /BaseFont /Times-Roman /Encoding /WinAnsiEncoding >>")
    let pageObjects = (1...spec.pages).map { _ in pdf.reserve() }
    func ref(_ page: Int) -> String { "\(pageObjects[page - 1]) 0 R" }
    func resolve(_ entry: String) -> String {
        var s = entry
        for page in stride(from: spec.pages, through: 1, by: -1) { s = s.replacingOccurrences(of: "P\(page) ", with: "\(ref(page)) ") }
        return s
    }

    for page in 1...spec.pages {
        var c = "0.6 G 72 742 m 540 742 l S\n"
        let header = chapterTitle(of: page, entries: spec.entries).map { "Link Forms Fixture  |  \($0)" } ?? "Link Forms Fixture"
        c += "BT /F1 9 Tf 0.08 g 72 748 Td \(pdfString(header)) Tj ET\n"
        var y: CGFloat = pageH - 96
        for e in spec.entries where e.page == page {
            let size: CGFloat = e.level == 0 ? 24 : (e.level == 1 ? 17 : 13)
            c += "BT /F2 \(Int(size)) Tf 72 \(Int(y)) Td \(pdfString(e.title)) Tj ET\n"
            y -= size + 14
        }
        var rng = LCG(state: UInt64(page) &* 2654435761 &+ 777)
        var lines: [String] = []
        var line = ""
        while lines.count < Int((y - 100) / 14) {
            for word in sentence(&rng).split(separator: " ") {
                if line.count + word.count + 1 > 88 { lines.append(line); line = "" }
                line += line.isEmpty ? String(word) : " " + word
            }
        }
        c += "BT /F3 11 Tf 14 TL 72 \(Int(y)) Td\n"
        for l in lines { c += "\(pdfString(l)) Tj T*\n" }
        c += "ET\n"
        for link in linkFormsLinks where link.page == page {
            let r = link.rect
            c += "0.9 0.94 1 rg \(Int(r.minX)) \(Int(r.minY)) \(Int(r.width)) \(Int(r.height)) re f\n"
            c += "BT /F1 12 Tf 0.1 0.3 0.8 rg \(Int(r.minX) + 6) \(Int(r.minY) + 7) Td \(pdfString(link.label)) Tj ET 0.08 g\n"
        }
        c += "BT /F1 9 Tf 72 54 Td \(pdfString("Fixture page \(page)")) Tj ET\n"
        let content = pdf.addStream(c)
        let annots = linkFormsLinks.filter { $0.page == page }.map { link -> Int in
            let r = link.rect
            return pdf.add("<< /Type /Annot /Subtype /Link /Rect [\(Int(r.minX)) \(Int(r.minY)) \(Int(r.maxX)) \(Int(r.maxY))] "
                + "/Border [0 0 0] /H /I \(resolve(link.entry)) >>")
        }
        let annotsEntry = annots.isEmpty ? "" : " /Annots [\(annots.map { "\($0) 0 R" }.joined(separator: " "))]"
        pdf.set(pageObjects[page - 1], "<< /Type /Page /Parent \(pages) 0 R /MediaBox [0 0 612 792] "
            + "/Resources << /Font << /F1 \(regular) 0 R /F2 \(bold) 0 R /F3 \(serif) 0 R >> >> /Contents \(content) 0 R\(annotsEntry) >>")
    }
    pdf.set(pages, "<< /Type /Pages /Kids [\(pageObjects.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(spec.pages) >>")

    // Outline (hyperref style: each item is a GoTo action to a named destination).
    let items = spec.entries.map { _ in pdf.reserve() }
    func children(of parent: Int?) -> [Int] {
        spec.entries.indices.filter { i in
            let level = spec.entries[i].level
            guard let parent else { return level == 0 }
            guard level == spec.entries[parent].level + 1, i > parent else { return false }
            return !spec.entries[(parent + 1)..<i].contains { $0.level <= spec.entries[parent].level }
        }
    }
    func descendants(of i: Int?) -> Int { children(of: i).reduce(0) { $0 + 1 + descendants(of: $1) } }
    for i in spec.entries.indices {
        let parentIndex = spec.entries[..<i].lastIndex { $0.level == spec.entries[i].level - 1 }
        let siblings = children(of: spec.entries[i].level == 0 ? nil : parentIndex)
        let pos = siblings.firstIndex(of: i)!
        var d = "<< /Title \(pdfString(spec.entries[i].title)) /Parent \(spec.entries[i].level == 0 ? outlines : items[parentIndex!]) 0 R"
        if pos > 0 { d += " /Prev \(items[siblings[pos - 1]]) 0 R" }
        if pos + 1 < siblings.count { d += " /Next \(items[siblings[pos + 1]]) 0 R" }
        let kids = children(of: i)
        if let first = kids.first, let last = kids.last {
            d += " /First \(items[first]) 0 R /Last \(items[last]) 0 R /Count \(descendants(of: i))"
        }
        d += " /A << /S /GoTo /D (toc.\(i)) >> >>"
        pdf.set(items[i], d)
    }
    let top = children(of: nil)
    pdf.set(outlines, "<< /Type /Outlines /First \(items[top.first!]) 0 R /Last \(items[top.last!]) 0 R /Count \(descendants(of: nil)) >>")

    // Named destinations: a /Names /Dests name tree (one intermediate node, as hyperref writes
    // for larger books) and the older catalog /Dests dictionary.
    let names = linkFormsNameTreeDests.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    let pairs = names.map { name -> String in
        let d = linkFormsNameTreeDests[name]!
        let array = "[\(ref(d.page)) \(d.view)]"
        return "\(pdfString(name)) \(d.asDict ? "<< /D \(array) >>" : array)"
    }
    let leaf = pdf.add("<< /Limits [\(pdfString(names.first!)) \(pdfString(names.last!))] /Names [\(pairs.joined(separator: " "))] >>")
    let tree = pdf.add("<< /Kids [\(leaf) 0 R] >>")
    let catalogDests = linkFormsCatalogDests.keys.sorted().map { "/\($0) [\(ref(linkFormsCatalogDests[$0]!.page)) \(linkFormsCatalogDests[$0]!.view)]" }
    let dests = pdf.add("<< \(catalogDests.joined(separator: " ")) >>")
    pdf.set(catalog, "<< /Type /Catalog /Pages \(pages) 0 R /Outlines \(outlines) 0 R /PageMode /UseOutlines "
        + "/Names << /Dests \(tree) 0 R >> /Dests \(dests) 0 R >>")
    let info = pdf.add("<< /Title (link-forms.pdf) /Producer (make-fixtures) >>")
    try pdf.data(root: catalog, info: info).write(to: dir.appendingPathComponent("link-forms.pdf"))
}

// MARK: verification

var failures: [String] = []
func check(_ ok: Bool, _ message: @autoclosure () -> String) {
    if !ok { failures.append(message()) }
}

func depth(_ o: PDFOutline) -> Int {
    (0..<o.numberOfChildren).map { 1 + depth(o.child(at: $0)!) }.max() ?? 0
}
func count(_ o: PDFOutline) -> Int {
    (0..<o.numberOfChildren).reduce(0) { $0 + 1 + count(o.child(at: $1)!) }
}
func titles(_ o: PDFOutline, into out: inout [String]) {
    for i in 0..<o.numberOfChildren {
        out.append(o.child(at: i)!.label ?? "")
        titles(o.child(at: i)!, into: &out)
    }
}

func verify(_ spec: Spec, dir: URL, expectedDepth: Int) {
    let url = dir.appendingPathComponent(spec.file)
    guard let doc = PDFDocument(url: url) else { failures.append("\(spec.file): cannot open"); return }
    check(doc.pageCount == spec.pages, "\(spec.file): page count \(doc.pageCount)")
    for i in 0..<doc.pageCount {
        if !(doc.page(at: i)?.string ?? "").contains("Fixture page \(i + 1)") {
            failures.append("\(spec.file): page \(i + 1) lacks 'Fixture page \(i + 1)'")
            break
        }
    }
    if let root = doc.outlineRoot {
        check(depth(root) == expectedDepth, "\(spec.file): outline depth \(depth(root)) != \(expectedDepth)")
        check(count(root) == spec.entries.count, "\(spec.file): outline entries \(count(root)) != \(spec.entries.count)")
        var all: [String] = []
        titles(root, into: &all)
        print("  \(spec.file): outline entries=\(count(root)) depth=\(depth(root)) 'Exercises' x\(all.filter { $0 == "Exercises" }.count)")
    } else {
        check(expectedDepth == 0, "\(spec.file): missing outline")
    }
    for link in spec.links {
        let target = doc.page(at: link.page - 1)?.annotations.first { $0.bounds == link.rect }
            .flatMap { $0.destination ?? ($0.action as? PDFActionGoTo)?.destination }?.page
        check(target.map { doc.index(for: $0) } == link.target - 1,
              "\(spec.file): link on page \(link.page) does not go to page \(link.target)")
    }
    for (page, _) in spec.specials {
        let key = spec.file == "small.pdf" ? "the quick amber fox annotates margins" : "zygomorphic lighthouse theorem"
        let hits = doc.findString(key, withOptions: [.caseInsensitive]).compactMap { $0.pages.first }
            .map { doc.index(for: $0) + 1 }
        check(hits == [page], "\(spec.file): '\(key)' found on pages \(hits), expected [\(page)]")
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("  \(spec.file): pages=\(doc.pageCount) size=\(size / 1024) KB")
}

/// `link-forms.pdf` opens with its pages, outline and links. Prints what PDFKit makes of each
/// link (its action and destination), which is what the reader has to work with.
func verifyLinkForms(dir: URL) {
    let url = dir.appendingPathComponent("link-forms.pdf")
    guard let doc = PDFDocument(url: url) else { failures.append("link-forms.pdf: cannot open"); return }
    check(doc.pageCount == smallSpec.pages, "link-forms.pdf: page count \(doc.pageCount)")
    for i in 0..<doc.pageCount where !(doc.page(at: i)?.string ?? "").contains("Fixture page \(i + 1)") {
        failures.append("link-forms.pdf: page \(i + 1) lacks 'Fixture page \(i + 1)'")
        break
    }
    if let root = doc.outlineRoot {
        check(depth(root) == 2 && count(root) == smallSpec.entries.count,
              "link-forms.pdf: outline depth \(depth(root)) entries \(count(root))")
    } else {
        failures.append("link-forms.pdf: missing outline")
    }
    for link in linkFormsLinks {
        let annotation = doc.page(at: link.page - 1)?.annotations.first { $0.bounds == link.rect }
        check(annotation != nil, "link-forms.pdf: no link '\(link.label)' on page \(link.page)")
        guard let annotation else { continue }
        let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination
        let page = destination?.page.map { doc.index(for: $0) + 1 }
        let action = annotation.action.map { String(describing: type(of: $0)) } ?? "none"
        print("  link-forms.pdf: '\(link.label)': action \(action), destination page \(page.map(String.init) ?? "nil")")
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("  link-forms.pdf: pages=\(doc.pageCount) size=\(size / 1024) KB")
}

// MARK: main

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-fixtures <outdir>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let started = Date()
for spec in [smallSpec, linksSpec, noOutlineSpec, largeSpec] { try write(spec, to: outDir) }
try writeLinkForms(to: outDir)
print(String(format: "generated in %.1fs", Date().timeIntervalSince(started)))
verify(smallSpec, dir: outDir, expectedDepth: 2)
verify(linksSpec, dir: outDir, expectedDepth: 2)
verify(largeSpec, dir: outDir, expectedDepth: 3)
verify(noOutlineSpec, dir: outDir, expectedDepth: 0)
verifyLinkForms(dir: outDir)
if failures.isEmpty {
    print("fixtures verified OK")
} else {
    failures.forEach { FileHandle.standardError.write(Data("FIXTURE CHECK FAILED: \($0)\n".utf8)) }
    exit(1)
}
