// Generates the bundled Quick Guide (docs/DESIGN.md, "First-run onboarding").
// Usage: swift scripts/make-guide.swift [output directory, default App/Resources]
// Writes "Tactile Texts Quick Guide.pdf": six pages with a two-level outline. The file is
// committed; rerun this only when the guide's text changes. The file name is the book's title in
// the Library, and `QuickGuide` (App/Features/Onboarding) looks up the headings and the
// highlighted sentence by the strings below, so keep them in step.

import AppKit
import CoreText
import Foundation
import PDFKit

let pageW: CGFloat = 468, pageH: CGFloat = 648
let marginX: CGFloat = 50
let textW = pageW - 2 * marginX
let guideTitle = "Tactile Texts Quick Guide"

struct Page {
    var chapter: String
    var section: String
    var paragraphs: [String]
    var tryIt: String
    var footer: String? = nil
}

let pages: [Page] = [
    Page(chapter: "1  Reading", section: "1.1  Start here",
         paragraphs: [
            "This guide is an ordinary PDF, so everything you try here works the same way in your own books.",
            "Scroll with one finger. The panel beside the page is this page\u{2019}s note. Something is already written in it: type into it, or clear it.",
            "Every page has a note of its own, and so does every heading.",
         ],
         tryIt: "Type a few words in the page note, then scroll to the next page. The note changes with the page.",
         footer: "Six short pages. Scroll down to begin."),
    Page(chapter: "1  Reading", section: "1.2  Highlight a line",
         paragraphs: [
            "Touch and hold a word, then drag the handles to select a sentence. Choose a highlight colour from the menu that appears.",
            "A highlight keeps its words, so you can find them later.",
            "Tap a highlight to change its colour or to remove it. The highlights on a page are listed with that page\u{2019}s note.",
         ],
         tryIt: "Highlight any sentence on this page."),
    Page(chapter: "2  Writing", section: "2.1  Write on the page",
         paragraphs: [
            "Tap Markup in the toolbar. The tool picker appears, and Apple Pencil now writes on the page.",
            "Your finger still scrolls and zooms while the Pencil writes, so you can keep reading with Markup on.",
            "Ink is kept beside the book. The PDF file itself is never changed.",
         ],
         tryIt: "Circle this sentence, then tap Markup again to finish."),
    Page(chapter: "2  Writing", section: "2.2  Notes for a page and a section",
         paragraphs: [
            "The notes panel has two tabs. Page note belongs to the page you are on. Section note belongs to the heading this page sits in, which here is 2.2.",
            "On the Section note tab you can step up a level, from 2.2 to chapter 2. The note for chapter 2, Writing, already has a line in it.",
            "With Markup on, the Pencil writes in a note too, over the words or in the space below them.",
         ],
         tryIt: "Open Section note and step up to 2 Writing."),
    Page(chapter: "3  Your books", section: "3.1  Contents you build",
         paragraphs: [
            "The Contents sidebar lists the book\u{2019}s headings. Tap one to jump to it. A badge marks a heading that has notes or highlights.",
            "You can add headings of your own. That is how a PDF with no outline gets a table of contents, and notes attach to your headings like any other.",
         ],
         tryIt: "Tap Add Heading at Page 5 at the bottom of Contents and give it a name."),
    Page(chapter: "3  Your books", section: "3.2  Notebook and export",
         paragraphs: [
            "The Notebook gathers every note, highlight and page of handwriting in a book, laid out under its headings. Open it from the More menu.",
            "Tap any entry to go back to its page. From the Notebook you can export everything as Markdown or as a PDF.",
            "That is everything. Go back to the Library and tap Import PDF to add a book of your own. You can delete this guide at any time and bring it back from Settings.",
         ],
         tryIt: "Open the Notebook and tap the page note from page 1."),
]

/// (title, level, 1-based page)
let outline: [(String, Int, Int)] = [
    ("1 Reading", 0, 1), ("1.1 Start here", 1, 1), ("1.2 Highlight a line", 1, 2),
    ("2 Writing", 0, 3), ("2.1 Write on the page", 1, 3), ("2.2 Notes for a page and a section", 1, 4),
    ("3 Your books", 0, 5), ("3.1 Contents you build", 1, 5), ("3.2 Notebook and export", 1, 6),
]

func font(_ name: String, _ size: CGFloat) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }

/// Draws `text` wrapped to `width` with its top edge `top` points below the page top; returns
/// the height used.
@discardableResult
func draw(_ ctx: CGContext, _ text: String, font f: CTFont, gray: CGFloat = 0.1, x: CGFloat, top: CGFloat,
          width: CGFloat, lineSpacing: CGFloat = 3, centered: Bool = false, tracking: CGFloat = 0) -> CGFloat {
    let style = NSMutableParagraphStyle()
    style.lineSpacing = lineSpacing
    style.alignment = centered ? .center : .left
    let attributed = NSAttributedString(string: text, attributes: [
        .font: f, .paragraphStyle: style, .kern: tracking,
        .foregroundColor: NSColor(white: gray, alpha: 1),
    ])
    let setter = CTFramesetterCreateWithAttributedString(attributed)
    let size = CTFramesetterSuggestFrameSizeWithConstraints(
        setter, CFRange(location: 0, length: 0), nil, CGSize(width: width, height: 10_000), nil)
    let height = ceil(size.height)
    let rect = CGRect(x: x, y: pageH - top - height, width: width, height: height)
    CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil), ctx)
    return height
}

func render() -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: pageW, height: pageH)
    let info = [kCGPDFContextTitle as String: guideTitle] as CFDictionary
    let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, info)!
    let body = font("Times-Roman", 13.5)
    for (index, page) in pages.enumerated() {
        ctx.beginPDFPage(nil)
        // Running header and rule.
        draw(ctx, "\(index + 1)", font: font("Times-Roman", 9.5), gray: 0.3, x: marginX, top: 34, width: 40)
        let headerFont = font("Times-Roman", 9.5)
        let headerWidth: CGFloat = 200
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        let header = NSAttributedString(string: guideTitle, attributes: [
            .font: headerFont, .paragraphStyle: style, .foregroundColor: NSColor(white: 0.3, alpha: 1)])
        let headerSetter = CTFramesetterCreateWithAttributedString(header)
        let headerRect = CGRect(x: pageW - marginX - headerWidth, y: pageH - 34 - 14, width: headerWidth, height: 14)
        CTFrameDraw(CTFramesetterCreateFrame(headerSetter, CFRange(location: 0, length: 0),
                                             CGPath(rect: headerRect, transform: nil), nil), ctx)
        ctx.setStrokeColor(CGColor(gray: 0.1, alpha: 1))
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: marginX, y: pageH - 52))
        ctx.addLine(to: CGPoint(x: pageW - marginX, y: pageH - 52))
        ctx.strokePath()

        var top: CGFloat = 78
        top += draw(ctx, page.chapter.uppercased(), font: font("Times-Roman", 10.5), gray: 0.3, x: marginX, top: top,
                    width: textW, tracking: 1) + 10
        top += draw(ctx, page.section, font: font("Times-Bold", 24), x: marginX, top: top, width: textW) + 18
        for paragraph in page.paragraphs {
            top += draw(ctx, paragraph, font: body, x: marginX, top: top, width: textW) + 12
        }
        // "Try it" box.
        top += 10
        let inset: CGFloat = 14
        let labelHeight: CGFloat = 16
        let tryFont = font("Times-Roman", 13)
        let tryStyle = NSMutableParagraphStyle()
        tryStyle.lineSpacing = 3
        let trySize = CTFramesetterSuggestFrameSizeWithConstraints(
            CTFramesetterCreateWithAttributedString(NSAttributedString(string: page.tryIt, attributes: [
                .font: tryFont, .paragraphStyle: tryStyle])),
            CFRange(location: 0, length: 0), nil, CGSize(width: textW - 2 * inset, height: 10_000), nil)
        let boxHeight = inset + labelHeight + ceil(trySize.height) + inset
        let boxRect = CGRect(x: marginX, y: pageH - top - boxHeight, width: textW, height: boxHeight)
        ctx.setStrokeColor(CGColor(gray: 0.55, alpha: 1))
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.addPath(CGPath(roundedRect: boxRect, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        draw(ctx, "TRY IT", font: font("Helvetica-Bold", 8.5), gray: 0.3, x: marginX + inset, top: top + inset,
             width: textW - 2 * inset, tracking: 0.8)
        draw(ctx, page.tryIt, font: tryFont, x: marginX + inset, top: top + inset + labelHeight, width: textW - 2 * inset)

        if let footer = page.footer {
            draw(ctx, footer, font: font("Times-Italic", 11.5), gray: 0.3, x: marginX, top: pageH - 64, width: textW,
                 centered: true)
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
    return data as Data
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/Resources")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let document = PDFDocument(data: render())!
let root = PDFOutline()
var stack: [PDFOutline] = [root]
var counts: [ObjectIdentifier: Int] = [:]
for (title, level, page) in outline {
    let node = PDFOutline()
    node.label = title
    node.destination = PDFDestination(page: document.page(at: page - 1)!, at: CGPoint(x: 0, y: pageH))
    let parent = stack[level]
    parent.insertChild(node, at: counts[ObjectIdentifier(parent), default: 0])
    counts[ObjectIdentifier(parent), default: 0] += 1
    stack = Array(stack.prefix(level + 1)) + [node]
}
document.outlineRoot = root
document.documentAttributes = [PDFDocumentAttribute.titleAttribute: guideTitle]
let url = outputDirectory.appendingPathComponent("\(guideTitle).pdf")
guard document.write(to: url) else { fatalError("could not write \(url.path)") }

// Verify what the app relies on.
let check = PDFDocument(url: url)!
precondition(check.pageCount == pages.count, "page count")
precondition(check.outlineRoot?.numberOfChildren == 3, "outline roots")
let highlighted = "A highlight keeps its words, so you can find them later."
precondition(!check.findString(highlighted, withOptions: []).isEmpty, "highlight sentence not found as one string")
print("wrote \(url.path): \(check.pageCount) pages, \((try? Data(contentsOf: url))?.count ?? 0) bytes")
