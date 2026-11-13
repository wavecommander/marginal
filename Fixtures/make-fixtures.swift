// Deterministic fixture PDF generator (macOS). Usage:
//   swiftc -O -o /tmp/make-fixtures Fixtures/make-fixtures.swift && /tmp/make-fixtures <outdir>
// (scripts/fixtures.sh wraps this.) Writes small.pdf, large.pdf, no-outline.pdf, then verifies
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

struct Spec {
    var file: String
    var pages: Int
    var entries: [Entry]
    var runningHeader: String
    /// page -> extra sentence appended to that page's first paragraph
    var specials: [Int: String] = [:]
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
    for (page, _) in spec.specials {
        let key = spec.file == "small.pdf" ? "the quick amber fox annotates margins" : "zygomorphic lighthouse theorem"
        let hits = doc.findString(key, withOptions: [.caseInsensitive]).compactMap { $0.pages.first }
            .map { doc.index(for: $0) + 1 }
        check(hits == [page], "\(spec.file): '\(key)' found on pages \(hits), expected [\(page)]")
    }
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    print("  \(spec.file): pages=\(doc.pageCount) size=\(size / 1024) KB")
}

// MARK: main

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-fixtures <outdir>\n".utf8))
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let started = Date()
for spec in [smallSpec, noOutlineSpec, largeSpec] { try write(spec, to: outDir) }
print(String(format: "generated in %.1fs", Date().timeIntervalSince(started)))
verify(smallSpec, dir: outDir, expectedDepth: 2)
verify(largeSpec, dir: outDir, expectedDepth: 3)
verify(noOutlineSpec, dir: outDir, expectedDepth: 0)
if failures.isEmpty {
    print("fixtures verified OK")
} else {
    failures.forEach { FileHandle.standardError.write(Data("FIXTURE CHECK FAILED: \($0)\n".utf8)) }
    exit(1)
}
