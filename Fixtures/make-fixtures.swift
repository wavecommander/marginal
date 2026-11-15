// Deterministic fixture PDF generator (macOS). Usage:
//   swiftc -O -o /tmp/make-fixtures Fixtures/make-fixtures.swift && /tmp/make-fixtures <outdir>
// (scripts/fixtures.sh wraps this.) Writes small.pdf, links.pdf, link-forms.pdf, large.pdf,
// no-outline.pdf, and the files the app converts at import (small.epub, protected.epub, small.cbz,
// small.md, small.docx, small.pptx), then verifies them and exits non-zero on any mismatch.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
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

// MARK: - Formats converted at import (F7)
//
// small.epub, protected.epub, small.cbz, small.md, small.docx and small.pptx: the files the
// conversion UI tests import. ZIPs are written here with stored entries and a fixed date, so the
// output is the same byte for byte on every run. small.docx is made by /usr/bin/textutil and
// repacked the same way (textutil stamps the current time into its ZIP headers).

/// A ZIP writer: stored (uncompressed) entries, in the order added, all dated 1980-01-01.
struct StoredZIP {
    private(set) var entries: [(name: String, data: Data)] = []

    mutating func add(_ name: String, _ data: Data) { entries.append((name, data)) }
    mutating func add(_ name: String, _ text: String) { add(name, Data(text.utf8)) }

    static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    func data() -> Data {
        var out = Data(), central = Data()
        func le16(_ d: inout Data, _ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le32(_ d: inout Data, _ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        for (name, data) in entries {
            let offset = UInt32(out.count), crc = Self.crc32(data), nameBytes = Array(name.utf8)
            // Local header: version 2.0, UTF-8 names, stored, time 00:00, date 1980-01-01.
            le32(&out, 0x0403_4B50); le16(&out, 20); le16(&out, 0x0800); le16(&out, 0); le16(&out, 0); le16(&out, 0x21)
            le32(&out, crc); le32(&out, UInt32(data.count)); le32(&out, UInt32(data.count))
            le16(&out, UInt16(nameBytes.count)); le16(&out, 0)
            out.append(contentsOf: nameBytes)
            out.append(data)
            le32(&central, 0x0201_4B50); le16(&central, 0x031E); le16(&central, 20); le16(&central, 0x0800); le16(&central, 0)
            le16(&central, 0); le16(&central, 0x21); le32(&central, crc); le32(&central, UInt32(data.count))
            le32(&central, UInt32(data.count)); le16(&central, UInt16(nameBytes.count))
            le16(&central, 0); le16(&central, 0); le16(&central, 0); le16(&central, 0)
            le32(&central, 0o100644 << 16); le32(&central, offset)
            central.append(contentsOf: nameBytes)
        }
        let directoryOffset = UInt32(out.count)
        out.append(central)
        le32(&out, 0x0605_4B50); le16(&out, 0); le16(&out, 0)
        le16(&out, UInt16(entries.count)); le16(&out, UInt16(entries.count))
        le32(&out, UInt32(central.count)); le32(&out, directoryOffset); le16(&out, 0)
        return out
    }
}

/// A PNG of `size` pixels: a fill, a darker frame, and `label` in large type in the middle.
func pngImage(width: Int, height: Int, fill: (CGFloat, CGFloat, CGFloat), label: String) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: fill.0, green: fill.1, blue: fill.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setStrokeColor(CGColor(red: fill.0 * 0.5, green: fill.1 * 0.5, blue: fill.2 * 0.5, alpha: 1))
    ctx.setLineWidth(CGFloat(width) / 30)
    ctx.stroke(CGRect(x: 0, y: 0, width: width, height: height).insetBy(dx: CGFloat(width) / 20, dy: CGFloat(width) / 20))
    ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
    let f = font("Helvetica-Bold", CGFloat(width) / 8)
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): f,
        NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attrs))
    let bounds = CTLineGetImageBounds(line, ctx)
    ctx.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2 - bounds.minX, y: (CGFloat(height) - bounds.height) / 2)
    CTLineDraw(line, ctx)
    let image = ctx.makeImage()!
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

func xmlEscape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "'", with: "&#39;")
}

// MARK: small.epub

/// What the conversion tests rely on in `small.epub`. Mirrored in `UITests/ConversionJourneyUITests.swift`.
enum SmallEPUB {
    static let title = "The Small Fixture Book"
    /// One paragraph of its own (one line on the converted page, set apart by margins so PDFKit
    /// reads it as a text block of its own), in chapter 2 right under
    /// "The Lighthouse", which the table of contents targets by fragment (`ch2.xhtml#lighthouse`).
    static let phrase = "The amber fox annotates margins."
    /// Nested navigation, in pre-order: (title, href, level).
    static let toc: [(String, String, Int)] = [
        ("Chapter 1: Departure", "text/ch1.xhtml", 1),
        ("The Harbour", "text/ch1.xhtml#harbour", 2),
        ("Chapter 2: The Crossing", "text/ch2.xhtml", 1),
        ("The Lighthouse", "text/ch2.xhtml#lighthouse", 2),
        ("Keeper's Log", "text/ch2.xhtml#log", 3),
        ("Chapter 3: Landfall", "text/ch3.xhtml", 1),
    ]
}

/// Deterministic prose: `count` paragraphs of `words` words from the fixture vocabulary, each
/// starting with a tag such as "Paragraph 2.3" so every paragraph is distinct.
func epubParagraphs(_ tag: String, count: Int, words: Int = 70) -> String {
    var rng = LCG(state: UInt64(tag.unicodeScalars.reduce(7) { $0 &* 31 &+ UInt64($1.value) }))
    return (1...count).map { index in
        var parts: [String] = []
        for _ in 0..<words { parts.append(sentenceWords[rng.next() % sentenceWords.count]) }
        return "<p>Paragraph \(tag).\(index) \(parts.joined(separator: " ")).</p>"
    }.joined(separator: "\n")
}

/// Words with no overlap with the phrase, so the phrase stays unique in the book.
let sentenceWords = ["harbour", "lantern", "evening", "orchard", "compass", "thimble", "meadow", "quarry", "sparrow",
                     "anchor", "pebble", "willow", "cobbler", "ferry", "granite", "mantle", "parcel", "ribbon",
                     "the", "of", "and", "a", "to", "in", "was", "beside", "under", "slowly", "bright", "quiet"]

func xhtmlDocument(title: String, body: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
    <head><meta charset="utf-8"/><title>\(xmlEscape(title))</title><link rel="stylesheet" href="../style.css"/></head>
    <body>
    \(body)
    </body>
    </html>
    """
}

func smallEPUB(encryption: String? = nil) -> Data {
    var zip = StoredZIP()
    zip.add("mimetype", "application/epub+zip")  // first and stored, as EPUB requires
    zip.add("META-INF/container.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """)
    if let encryption { zip.add("META-INF/encryption.xml", encryption) }
    zip.add("OEBPS/content.opf", """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="uid">urn:uuid:6b1f0a52-3c8e-4d7b-9e21-5f4a8c0d2e19</dc:identifier>
            <dc:title>\(SmallEPUB.title)</dc:title>
            <dc:creator>Fixture Author</dc:creator>
            <dc:language>en</dc:language>
            <meta property="dcterms:modified">2026-11-15T00:00:00Z</meta>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            <item id="css" href="style.css" media-type="text/css"/>
            <item id="cover" href="images/cover.png" media-type="image/png" properties="cover-image"/>
            <item id="ch1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
            <item id="ch3" href="text/ch3.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine>
            <itemref idref="ch1"/>
            <itemref idref="ch2"/>
            <itemref idref="ch3"/>
          </spine>
        </package>
        """)
    // The nav document: nested lists built from `SmallEPUB.toc`.
    var nav = "", depth = 0
    for (index, entry) in SmallEPUB.toc.enumerated() {
        let (title, href, level) = entry
        if level > depth { nav += "<ol>"; depth = level } else {
            nav += "</li>"
            while depth > level { nav += "</ol></li>"; depth -= 1 }
        }
        nav += "<li><a href=\"\(href)\">\(xmlEscape(title))</a>"
        if index == SmallEPUB.toc.count - 1 {
            nav += "</li>"
            while depth > 1 { nav += "</ol></li>"; depth -= 1 }
            nav += "</ol>"
        }
    }
    zip.add("OEBPS/nav.xhtml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en">
        <head><meta charset="utf-8"/><title>Contents</title></head>
        <body><nav epub:type="toc" id="toc"><h1>Contents</h1>\(nav)</nav></body>
        </html>
        """)
    zip.add("OEBPS/style.css", """
        body { font-family: Georgia, serif; }
        h1 { font-size: 1.8em; }
        h2 { font-size: 1.3em; }
        h3 { font-size: 1.1em; }
        p { text-indent: 1.2em; margin: 0 0 0.4em 0; }
        p.phrase { text-indent: 0; margin: 1em 0 1.5em 0; font-family: "Times New Roman", Times, serif; }
        """)
    zip.add("OEBPS/images/cover.png", pngImage(width: 600, height: 900, fill: (0.93, 0.62, 0.29), label: "Small"))
    zip.add("OEBPS/text/ch1.xhtml", xhtmlDocument(title: "Chapter 1", body: """
        <h1 id="c1">Chapter 1: Departure</h1>
        \(epubParagraphs("1.0", count: 8))
        <h2 id="harbour">The Harbour</h2>
        \(epubParagraphs("1.1", count: 10))
        """))
    zip.add("OEBPS/text/ch2.xhtml", xhtmlDocument(title: "Chapter 2", body: """
        <h1 id="c2">Chapter 2: The Crossing</h1>
        \(epubParagraphs("2.0", count: 10))
        <h2 id="lighthouse">The Lighthouse</h2>
        <p class="phrase">\(SmallEPUB.phrase)</p>
        \(epubParagraphs("2.1", count: 6))
        <h3 id="log">Keeper's Log</h3>
        \(epubParagraphs("2.2", count: 8))
        """))
    zip.add("OEBPS/text/ch3.xhtml", xhtmlDocument(title: "Chapter 3", body: """
        <h1 id="c3">Chapter 3: Landfall</h1>
        \(epubParagraphs("3.0", count: 10))
        <p>The end.</p>
        """))
    return zip.data()
}

/// `small.epub` with an `encryption.xml` that encrypts a chapter with AES (not font
/// obfuscation): DRM, so the import lists it as copy-protected.
func protectedEPUB() -> Data {
    smallEPUB(encryption: """
        <?xml version="1.0" encoding="UTF-8"?>
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
          <enc:EncryptedData>
            <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
            <enc:CipherData><enc:CipherReference URI="OEBPS/text/ch1.xhtml"/></enc:CipherData>
          </enc:EncryptedData>
        </encryption>
        """)
}

// MARK: small.cbz

/// The comic's page images, in the order they are stored in the archive (not reading order):
/// natural sort must put page2 before page10. (file name, page number shown on it).
let smallCBZPages: [(String, Int)] = [("page10.png", 5), ("page2.png", 2), ("page1.png", 1), ("page9.png", 4), ("page3.png", 3)]

func smallCBZ() -> Data {
    let fills: [(CGFloat, CGFloat, CGFloat)] = [(0.95, 0.85, 0.55), (0.6, 0.8, 0.95), (0.75, 0.92, 0.7), (0.95, 0.7, 0.75), (0.8, 0.75, 0.95)]
    var zip = StoredZIP()
    for (name, number) in smallCBZPages {
        zip.add(name, pngImage(width: 800, height: 1200, fill: fills[number - 1], label: "Page \(number)"))
    }
    return zip.data()
}

// MARK: small.md

let smallMarkdown = """
    # Small Markdown Fixture

    A short document for the text converter. It has *emphasis*, **strong text** and `code`.

    ## A List

    - The first item names the harbour.
    - The second item names the lantern.
    - The third item names the orchard.

    ## A Code Block

    ```
    let answer = 42
    ```

    ## A Link

    Read [the example page](https://example.com/) for more. Images that are not inside the file
    are never downloaded.

    The phrase markdown lighthouse keeper appears once.

    """

// MARK: small.docx (textutil)

/// HTML for textutil: three headings with paragraphs.
func smallDocxHTML() -> String {
    var html = "<html><head><meta charset='utf-8'><title>Small Word Fixture</title></head><body>"
    for chapter in 1...3 {
        html += "<h1>Section \(chapter): Word Heading \(chapter)</h1>"
        for paragraph in 1...6 {
            html += "<p>DOCPARA-\(chapter)-\(paragraph). The quick brown fox jumps over the lazy dog. "
                + "Sphinx of black quartz, judge my vow. Pack my box with five dozen liquor jugs.</p>"
        }
    }
    return html + "</body></html>"
}

func run(_ tool: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "fixtures", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "\(tool) \(arguments.joined(separator: " ")) failed"])
    }
}

/// Converts the HTML with textutil, unzips it and repacks the parts (sorted, `[Content_Types].xml`
/// first) with fixed dates.
func smallDocx() throws -> Data {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("make-fixtures-\(getpid())", isDirectory: true)
    try? FileManager.default.removeItem(at: scratch)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let html = scratch.appendingPathComponent("small.html"), docx = scratch.appendingPathComponent("small.docx")
    let parts = scratch.appendingPathComponent("parts", isDirectory: true)
    try Data(smallDocxHTML().utf8).write(to: html)
    try run("/usr/bin/textutil", ["-convert", "docx", "-output", docx.path, html.path])
    try run("/usr/bin/unzip", ["-q", "-o", docx.path, "-d", parts.path])
    var names: [String] = []
    let enumerator = FileManager.default.enumerator(at: parts, includingPropertiesForKeys: [.isRegularFileKey])!
    for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        names.append(String(url.standardizedFileURL.path.dropFirst(parts.standardizedFileURL.path.count + 1)))
    }
    names.sort { ($0 == "[Content_Types].xml" ? "" : $0) < ($1 == "[Content_Types].xml" ? "" : $1) }
    var zip = StoredZIP()
    for name in names { zip.add(name, try Data(contentsOf: parts.appendingPathComponent(name))) }
    return zip.data()
}

// MARK: small.pptx (hand-built, three 16:9 slides; after the F0 spike's generator)

func smallPPTX(slides count: Int = 3) -> Data {
    let ns = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" "
        + "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
        + "xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
    let x = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    func rels(_ items: [(String, String, String)]) -> String {
        x + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + items.map { "<Relationship Id=\"\($0.0)\" Type=\"\(rel)/\($0.1)\" Target=\"\($0.2)\"/>" }.joined()
            + "</Relationships>"
    }
    func shape(_ id: Int, _ name: String, _ type: String, _ y: Int, _ cy: Int, _ text: String, _ size: Int) -> String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr>"
            + "<p:nvPr><p:ph type=\"\(type)\"\(type == "title" ? "" : " idx=\"1\"")/></p:nvPr></p:nvSpPr>"
            + "<p:spPr><a:xfrm><a:off x=\"838200\" y=\"\(y)\"/><a:ext cx=\"10515600\" cy=\"\(cy)\"/></a:xfrm>"
            + "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr>"
            + "<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang=\"en-US\" sz=\"\(size)\"/><a:t>\(text)</a:t></a:r></a:p></p:txBody></p:sp>"
    }
    let treeHead = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>"
        + "<p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
    func titleAndBody(_ title: String, _ body: String) -> String {
        shape(2, "Title", "title", 365125, 1325563, title, 4400) + shape(3, "Body", "body", 1825625, 4351338, body, 2800)
    }
    func slide(_ n: Int) -> String {
        x + "<p:sld \(ns)><p:cSld><p:spTree>\(treeHead)"
            + titleAndBody("Slide \(n) Title SLIDETITLE-\(n)", "Body text of slide \(n) SLIDEBODY-\(n)")
            + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
    }
    let layout = x + "<p:sldLayout \(ns) type=\"obj\" preserve=\"1\"><p:cSld name=\"Title and Content\"><p:spTree>\(treeHead)"
        + titleAndBody("Title", "Body") + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"
    let master = x + "<p:sldMaster \(ns)><p:cSld><p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg><p:spTree>\(treeHead)"
        + titleAndBody("Title", "Body") + "</p:spTree></p:cSld>"
        + "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" "
        + "accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
        + "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst>"
        + "<p:txStyles><p:titleStyle><a:lvl1pPr><a:defRPr sz=\"4400\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill>"
        + "<a:latin typeface=\"+mj-lt\"/></a:defRPr></a:lvl1pPr></p:titleStyle>"
        + "<p:bodyStyle><a:lvl1pPr><a:defRPr sz=\"2800\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill>"
        + "<a:latin typeface=\"+mn-lt\"/></a:defRPr></a:lvl1pPr></p:bodyStyle><p:otherStyle/></p:txStyles></p:sldMaster>"
    func colour(_ name: String, _ value: String) -> String { "<a:\(name)><a:srgbClr val=\"\(value)\"/></a:\(name)>" }
    let fill3 = String(repeating: "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>", count: 3)
    let line3 = String(repeating: "<a:ln w=\"9525\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln>", count: 3)
    let effect3 = String(repeating: "<a:effectStyle><a:effectLst/></a:effectStyle>", count: 3)
    let theme = x + "<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"Fixture\"><a:themeElements>"
        + "<a:clrScheme name=\"Fixture\">"
        + "<a:dk1><a:sysClr val=\"windowText\" lastClr=\"000000\"/></a:dk1><a:lt1><a:sysClr val=\"window\" lastClr=\"FFFFFF\"/></a:lt1>"
        + colour("dk2", "44546A") + colour("lt2", "E7E6E6") + colour("accent1", "4472C4") + colour("accent2", "ED7D31")
        + colour("accent3", "A5A5A5") + colour("accent4", "FFC000") + colour("accent5", "5B9BD5") + colour("accent6", "70AD47")
        + colour("hlink", "0563C1") + colour("folHlink", "954F72") + "</a:clrScheme>"
        + "<a:fontScheme name=\"Fixture\"><a:majorFont><a:latin typeface=\"Helvetica\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:majorFont>"
        + "<a:minorFont><a:latin typeface=\"Helvetica\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:minorFont></a:fontScheme>"
        + "<a:fmtScheme name=\"Fixture\"><a:fillStyleLst>\(fill3)</a:fillStyleLst><a:lnStyleLst>\(line3)</a:lnStyleLst>"
        + "<a:effectStyleLst>\(effect3)</a:effectStyleLst><a:bgFillStyleLst>\(fill3)</a:bgFillStyleLst></a:fmtScheme>"
        + "</a:themeElements></a:theme>"
    let slideIDs = (1...count).map { "<p:sldId id=\"\(255 + $0)\" r:id=\"rId\($0 + 1)\"/>" }.joined()
    let presentation = x + "<p:presentation \(ns)><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst>"
        + "<p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx=\"12192000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>"
    let ct = "application/vnd.openxmlformats-officedocument"
    let overrides = "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"\(ct).presentationml.presentation.main+xml\"/>"
        + "<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"\(ct).presentationml.slideMaster+xml\"/>"
        + "<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"\(ct).presentationml.slideLayout+xml\"/>"
        + "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"\(ct).theme+xml\"/>"
        + (1...count).map { "<Override PartName=\"/ppt/slides/slide\($0).xml\" ContentType=\"\(ct).presentationml.slide+xml\"/>" }.joined()
    let contentTypes = x + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
        + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
        + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>" + overrides + "</Types>"

    var zip = StoredZIP()
    zip.add("[Content_Types].xml", contentTypes)
    zip.add("_rels/.rels", rels([("rId1", "officeDocument", "ppt/presentation.xml")]))
    zip.add("ppt/presentation.xml", presentation)
    zip.add("ppt/_rels/presentation.xml.rels", rels([("rId1", "slideMaster", "slideMasters/slideMaster1.xml")]
        + (1...count).map { ("rId\($0 + 1)", "slide", "slides/slide\($0).xml") }
        + [("rId\(count + 2)", "theme", "theme/theme1.xml")]))
    zip.add("ppt/slideMasters/slideMaster1.xml", master)
    zip.add("ppt/slideMasters/_rels/slideMaster1.xml.rels",
            rels([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"), ("rId2", "theme", "../theme/theme1.xml")]))
    zip.add("ppt/slideLayouts/slideLayout1.xml", layout)
    zip.add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", rels([("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")]))
    zip.add("ppt/theme/theme1.xml", theme)
    for n in 1...count {
        zip.add("ppt/slides/slide\(n).xml", slide(n))
        zip.add("ppt/slides/_rels/slide\(n).xml.rels", rels([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")]))
    }
    return zip.data()
}

/// Writes the converted-format fixtures.
func writeConvertedFormats(to dir: URL) throws {
    try smallEPUB().write(to: dir.appendingPathComponent("small.epub"))
    try protectedEPUB().write(to: dir.appendingPathComponent("protected.epub"))
    try smallCBZ().write(to: dir.appendingPathComponent("small.cbz"))
    try Data(smallMarkdown.utf8).write(to: dir.appendingPathComponent("small.md"))
    try smallDocx().write(to: dir.appendingPathComponent("small.docx"))
    try smallPPTX().write(to: dir.appendingPathComponent("small.pptx"))
}

/// The ZIP-based fixtures start as ZIPs, the EPUBs with a stored `mimetype` entry first, and
/// list the entries they should (read back with /usr/bin/unzip).
func verifyConvertedFormats(dir: URL) {
    func listing(_ name: String) -> [String] {
        let pipe = Pipe(), process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zipinfo")
        process.arguments = ["-1", dir.appendingPathComponent(name).path]
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: output, as: UTF8.self).split(separator: "\n").map(String.init)
    }
    for name in ["small.epub", "protected.epub"] {
        let data = (try? Data(contentsOf: dir.appendingPathComponent(name))) ?? Data()
        check(data.count > 58 && String(decoding: data[30..<58], as: UTF8.self) == "mimetypeapplication/epub+zip",
              "\(name): mimetype is not the first, stored entry")
        let entries = listing(name)
        check(entries.contains("OEBPS/nav.xhtml") && entries.contains("OEBPS/images/cover.png"), "\(name): entries \(entries)")
        check(entries.contains("META-INF/encryption.xml") == (name == "protected.epub"), "\(name): encryption.xml")
    }
    check(Set(listing("small.cbz")) == Set(smallCBZPages.map(\.0)), "small.cbz: entries \(listing("small.cbz"))")
    check(listing("small.docx").first == "[Content_Types].xml" && listing("small.docx").contains("word/document.xml"),
          "small.docx: entries \(listing("small.docx"))")
    check(listing("small.pptx").filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }.count == 3,
          "small.pptx: entries \(listing("small.pptx"))")
    for name in ["small.epub", "protected.epub", "small.cbz", "small.md", "small.docx", "small.pptx"] {
        let size = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? Int) ?? 0
        check(size > 0, "\(name): empty")
        print("  \(name): size=\(size / 1024) KB")
    }
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
try writeConvertedFormats(to: outDir)
print(String(format: "generated in %.1fs", Date().timeIntervalSince(started)))
verify(smallSpec, dir: outDir, expectedDepth: 2)
verify(linksSpec, dir: outDir, expectedDepth: 2)
verify(largeSpec, dir: outDir, expectedDepth: 3)
verify(noOutlineSpec, dir: outDir, expectedDepth: 0)
verifyLinkForms(dir: outDir)
verifyConvertedFormats(dir: outDir)
if failures.isEmpty {
    print("fixtures verified OK")
} else {
    failures.forEach { FileHandle.standardError.write(Data("FIXTURE CHECK FAILED: \($0)\n".utf8)) }
    exit(1)
}
