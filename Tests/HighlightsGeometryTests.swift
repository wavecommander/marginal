import CoreGraphics
import Foundation
import ReaderCore
import Testing
import UIKit
@testable import Marginal

/// WP7's pure rules: text normalisation, overlap, hit-testing, the palette and the menus.
@MainActor
struct HighlightsGeometryTests {
    private let bookID = UUID()

    private func highlight(_ rects: [CGRect], _ color: HighlightColor = .yellow, created: TimeInterval = 0) -> Highlight {
        Highlight(bookID: bookID, pageIndex: 0, rects: rects, color: color, text: "t",
                  createdAt: Date(timeIntervalSince1970: created))
    }

    @Test func whitespaceIsNormalised() {
        #expect(HighlightGeometry.normalizedText("  the quick\namber\t\tfox \r\n annotates\u{00A0}margins  ")
                == "the quick amber fox annotates margins")
        #expect(HighlightGeometry.normalizedText("\n \t") == "")
        #expect(HighlightGeometry.normalizedText("one") == "one")
    }

    @Test func overlapNeedsTheSameLineAndSharedExtent() {
        let line = CGRect(x: 100, y: 500, width: 100, height: 12)
        // Same line, overlapping horizontally.
        #expect(HighlightGeometry.linesOverlap(line, CGRect(x: 150, y: 501, width: 100, height: 12)))
        // Inside.
        #expect(HighlightGeometry.linesOverlap(line, CGRect(x: 120, y: 500, width: 20, height: 12)))
        // Touching end to end: separate highlights.
        #expect(!HighlightGeometry.linesOverlap(line, CGRect(x: 200, y: 500, width: 50, height: 12)))
        // Next line down (no vertical overlap) or barely touching vertically.
        #expect(!HighlightGeometry.linesOverlap(line, CGRect(x: 100, y: 485, width: 100, height: 12)))
        #expect(!HighlightGeometry.linesOverlap(line, CGRect(x: 100, y: 490, width: 100, height: 12)))
        // Multi-line sets: any pair.
        #expect(HighlightGeometry.overlaps([CGRect(x: 0, y: 0, width: 10, height: 10), line],
                                           [CGRect(x: 190, y: 502, width: 30, height: 10)]))
        #expect(!HighlightGeometry.overlaps([], [line]))
    }

    @Test func hitTestUsesStoredRectsWithTolerance() {
        let a = highlight([CGRect(x: 100, y: 500, width: 100, height: 12), CGRect(x: 72, y: 486, width: 60, height: 12)])
        let b = highlight([CGRect(x: 300, y: 300, width: 40, height: 12)], .green)
        let all = [a, b]
        #expect(HighlightGeometry.hitTest(CGPoint(x: 150, y: 506), in: all)?.id == a.id)
        #expect(HighlightGeometry.hitTest(CGPoint(x: 80, y: 490), in: all)?.id == a.id, "second line")
        #expect(HighlightGeometry.hitTest(CGPoint(x: 203, y: 506), in: all)?.id == a.id, "within tolerance")
        #expect(HighlightGeometry.hitTest(CGPoint(x: 210, y: 506), in: all) == nil, "beyond tolerance")
        #expect(HighlightGeometry.hitTest(CGPoint(x: 320, y: 306), in: all)?.id == b.id)
        #expect(HighlightGeometry.hitTest(CGPoint(x: 10, y: 10), in: all) == nil)
        // A small highlight inside a big one's tolerance band: the one actually under the point wins.
        let small = highlight([CGRect(x: 201, y: 500, width: 20, height: 12)], .pink, created: 10)
        #expect(HighlightGeometry.hitTest(CGPoint(x: 202, y: 506), in: [a, small])?.id == small.id)
    }

    @Test func fallbackMergeUnionsPerLine() {
        let merged = HighlightGeometry.mergedLines([
            CGRect(x: 100, y: 500, width: 50, height: 12), CGRect(x: 140, y: 500, width: 60, height: 12),
            CGRect(x: 72, y: 486, width: 30, height: 12),
        ])
        #expect(merged == [CGRect(x: 100, y: 500, width: 100, height: 12), CGRect(x: 72, y: 486, width: 30, height: 12)])
    }

    @Test func paletteHasFourNamedColoursWithDarkModeBorders() {
        #expect(HighlightColor.allCases.map(HighlightPalette.name) == ["Yellow", "Green", "Blue", "Pink"])
        let light = UITraitCollection(userInterfaceStyle: .light)
        let dark = UITraitCollection(userInterfaceStyle: .dark)
        for color in HighlightColor.allCases {
            var lightWhite: CGFloat = 0, darkWhite: CGFloat = 0, alpha: CGFloat = 0
            HighlightPalette.swatchBorder(color).resolvedColor(with: light).getWhite(&lightWhite, alpha: &alpha)
            HighlightPalette.swatchBorder(color).resolvedColor(with: dark).getWhite(&darkWhite, alpha: &alpha)
            #expect(darkWhite > lightWhite + 0.3, "\(color): the dark-mode border is a light tint")
            #expect(HighlightPalette.pageFill(color).cgColor.alpha < 0.5)
        }
        // The mockup's swatches.
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        HighlightPalette.swatch(.yellow).getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(Int((r * 255).rounded()) == 0xFF && Int((g * 255).rounded()) == 0xD6 && Int((b * 255).rounded()) == 0x0A)
        // The Notebook forwards to the palette.
        #expect(NotebookHighlightStyle.name(.pink) == "Pink")
    }

    @Test func menusNameTheColoursAndMarkTheCurrentOne() throws {
        let menu = HighlightMenus.selectionMenu { _ in }
        #expect(menu.title == "Highlight")
        #expect(menu.children.map(\.title) == ["Yellow", "Green", "Blue", "Pink"])
        let (store, book) = try HighlightsTestSupport.makeStore()
        let session = ReaderSession(book: book, store: store)
        let controller = try #require(session.highlights)
        let tapMenu = controller.tapMenu(for: Highlight(bookID: book.id, pageIndex: 0, rects: [], color: .green, text: "x"))
        let colours = try #require(tapMenu.children.first as? UIMenu)
        #expect(colours.children.map(\.title) == ["Yellow", "\u{2713} Green", "Blue", "Pink"])
        #expect(colours.children.compactMap { ($0 as? UIAction)?.state } == [.off, .on, .off, .off])
        #expect(tapMenu.children.dropFirst().map(\.title) == ["Copy", "Delete"])
        #expect((tapMenu.children.last as? UIAction)?.attributes.contains(.destructive) == true)
    }
}
