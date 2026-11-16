import Foundation
import Testing
@testable import ReaderCore

@Suite("Heading anchors")
struct HeadingAnchorTests {
    @Test func stringFormat() throws {
        let anchor = HeadingAnchor(pdfPath: [4, 1], pageIndex: 311, title: " 5.2 The  Characteristic/Equation ")
        #expect(anchor.rawValue == "pdf1/4.1/311/5.2 The Characteristic/Equation")
        #expect(HeadingAnchor(rawValue: anchor.rawValue) == anchor)
        #expect(HeadingAnchor(rawValue: anchor.rawValue)?.title == "5.2 The Characteristic/Equation")
        #expect(HeadingAnchor(rawValue: anchor.rawValue)?.pdfPath == [4, 1])

        let noPage = HeadingAnchor(pdfPath: [0], pageIndex: nil, title: "Part I")
        #expect(noPage.rawValue == "pdf1/0/-/Part I")
        #expect(HeadingAnchor(rawValue: noPage.rawValue)?.pageIndex == nil)

        let id = UUID(uuidString: "9F1C0000-0000-0000-0000-0000000000AB")!
        let user = HeadingAnchor(userHeadingID: id)
        #expect(user.rawValue == "user1/9F1C0000-0000-0000-0000-0000000000AB")
        #expect(HeadingAnchor(rawValue: "user1/9f1c0000-0000-0000-0000-0000000000ab") == user)
        #expect(user.userHeadingID == id && user.isUserHeading && user.title == nil)

        for bad in ["", "pdf1/", "pdf1/1/2", "pdf1//1/x", "pdf1/a/1/x", "pdf1/1./1/x", "pdf1/1/-1/x", "pdf1/1/+1/x",
                    "user1/nope", "pdf2/1/1/x", "heading"] {
            #expect(HeadingAnchor(rawValue: bad) == nil, "\(bad)")
        }
        #expect(HeadingAnchor(rawValue: "pdf1/0/3/") != nil)   // empty title is allowed
    }

    @Test func codableAsASingleString() throws {
        let anchor = HeadingAnchor(pdfPath: [2], pageIndex: 7, title: "Two")
        let data = try JSONEncoder().encode([anchor])
        #expect(String(decoding: data, as: UTF8.self) == #"["pdf1\/2\/7\/Two"]"#)
        #expect(try JSONDecoder().decode([HeadingAnchor].self, from: data) == [anchor])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([HeadingAnchor].self, from: Data(#"["junk"]"#.utf8)) }
    }

    @Test func anchorsAreIdenticalAfterRebuildingFromTheSameEntries() {
        let entries = syntheticEntries(pageCount: 500, chapters: 5, sections: 4, subsections: 3)
        let first = Outline(pdfEntries: entries, pageCount: 500).nodes.map(\.anchor)
        let second = Outline(pdfEntries: entries, pageCount: 500).nodes.map(\.anchor)
        #expect(first == second)
        #expect(Set(first).count == first.count)
        let withUsers = Outline(pdfEntries: entries, userHeadings: [
            UserHeading(id: uuid(1), bookID: bookA, title: "Mine", pageIndex: 100, parent: first[0], createdAt: fixedDate),
        ], pageCount: 500)
        #expect(withUsers.nodes.filter { !$0.isUserHeading }.map(\.anchor) == first)
    }

    @Test func duplicateTitlesGetDistinctAnchorsAndResolveExactly() {
        let outline = Outline(pdfEntries: [
            e("Ch1", 1, 10), e("Exercises", 2, 15),
            e("Ch2", 1, 30), e("Exercises", 2, 35), e("Exercises", 2, 36),
            e("Ch3", 1, 50), e("Summary", 2, 55), e("Summary", 2, 55),
        ], pageCount: 100)
        let exercises = outline.nodes.filter { $0.title == "Exercises" }
        let summaries = outline.nodes.filter { $0.title == "Summary" }
        #expect(Set((exercises + summaries).map(\.anchor)).count == 5)
        for node in exercises + summaries {
            let match = outline.resolve(node.anchor)
            #expect(match?.node.anchor == node.anchor)
            #expect(match?.quality == .exact)
        }
        #expect(outline.headingPath(forPage: 36).last?.anchor == exercises[2].anchor)
        #expect(outline.headingPath(forPage: 15).last?.anchor == exercises[0].anchor)
    }

    // v1 of a book's outline, and variants a new edition or a re-export might produce.
    let v1 = [e("1 Vectors", 1, 10), e("1.1 Addition", 2, 10), e("1.2 Scaling", 2, 20), e("2 Matrices", 1, 40), e("Exercises", 2, 45)]

    @Test func fallbackAfterATitleEdit() {
        let old = Outline(pdfEntries: v1, pageCount: 100)
        var entries = v1
        entries[2].title = "1.2 Scalar Multiplication"
        let new = Outline(pdfEntries: entries, pageCount: 100)
        let match = new.resolve(old.titled("1.2 Scaling").anchor)
        #expect(match?.node.title == "1.2 Scalar Multiplication")
        #expect(match?.quality == .pathAndPage)
        #expect(match?.isExact == false)
        #expect(new.resolve(old.titled("2 Matrices").anchor)?.quality == .exact)
    }

    @Test func fallbackAfterAPageShift() {
        let old = Outline(pdfEntries: v1, pageCount: 100)
        let shifted = Outline(pdfEntries: v1.map { e($0.title, $0.level, $0.pageIndex.map { $0 + 2 }) }, pageCount: 102)
        for node in old.nodes {
            let match = shifted.resolve(node.anchor)
            #expect(match?.node.title == node.title)
            #expect(match?.quality == .pathAndTitle)
        }
    }

    @Test func fallbackAfterAHeadingIsInsertedBefore() {
        let old = Outline(pdfEntries: v1, pageCount: 100)
        let new = Outline(pdfEntries: [e("0 Preface", 1, 5)] + v1, pageCount: 100)
        let match = new.resolve(old.titled("2 Matrices").anchor)
        #expect(match?.node.title == "2 Matrices")
        #expect(match?.node.anchor.pdfPath == [2])
        #expect(match?.quality == .titleAndPage)
        #expect(new.resolve(old.titled("Exercises").anchor)?.node.anchor.pdfPath == [2, 0])
    }

    @Test func titleOnlyFallbackRequiresAUniqueTitle() {
        let old = Outline(pdfEntries: v1, pageCount: 100)
        let shiftedAndInserted = [e("0 Preface", 1, 5)] + v1.map { e($0.title, $0.level, $0.pageIndex.map { $0 + 3 }) }
        let new = Outline(pdfEntries: shiftedAndInserted, pageCount: 110)
        #expect(new.resolve(old.titled("2 Matrices").anchor)?.quality == .titleOnly)
        #expect(new.resolve(old.titled("Exercises").anchor)?.quality == .titleOnly)

        let twoExercises = Outline(pdfEntries: shiftedAndInserted + [e("Exercises", 2, 60)], pageCount: 110)
        #expect(twoExercises.resolve(old.titled("Exercises").anchor) == nil)
        #expect(Outline(pdfEntries: [e("Other", 1, 0)], pageCount: 10).resolve(old.titled("2 Matrices").anchor) == nil)
    }

    @Test func titleComparisonIgnoresCaseAndDiacritics() {
        let stored = HeadingAnchor(pdfPath: [0], pageIndex: 3, title: "Équations  différentielles")
        let outline = Outline(pdfEntries: [e("EQUATIONS DIFFERENTIELLES", 1, 3)], pageCount: 10)
        let match = outline.resolve(stored)
        #expect(match?.quality == .titleAndPage)
        #expect(match?.node.anchor.pdfPath == [0])
    }

    @Test func userAnchorsMatchOnlyByID() {
        let heading = UserHeading(id: uuid(7), bookID: bookA, title: "Mine", pageIndex: 3, parent: nil, createdAt: fixedDate)
        let outline = Outline(pdfEntries: [], userHeadings: [heading], pageCount: 10)
        #expect(outline.resolve(heading.anchor)?.quality == .exact)
        #expect(outline.resolve(HeadingAnchor(userHeadingID: uuid(8))) == nil)
    }

    @Test func resolveAllGivesEachNodeToTheStrongestAnchorOnly() {
        let outline = Outline(pdfEntries: v1, pageCount: 100)
        let real = outline.titled("1.2 Scaling").anchor
        let stale = HeadingAnchor(pdfPath: [9, 9], pageIndex: 20, title: "1.2 Scaling")
        let gone = HeadingAnchor(pdfPath: [7], pageIndex: 70, title: "Nowhere")
        #expect(outline.resolve(stale)?.node.anchor == real)          // alone, it would match
        let all = outline.resolveAll([stale, real, gone, real])
        #expect(all.count == 1)
        #expect(all[real]?.quality == .exact)
        #expect(all[stale] == nil && all[gone] == nil)
    }
}

@Suite("Heading path performance")
struct HeadingPathPerformanceTests {
    /// 1,500 pages, 3 levels (30 × 8 × 6 = 1,710 headings). Every page change calls
    /// `headingPath(forPage:)`; it must be a table lookup, not a tree walk.
    @Test func headingPathIsFastOnALargeBook() {
        let clock = ContinuousClock()
        let entries = syntheticEntries(pageCount: 1_500, chapters: 30, sections: 8, subsections: 6)
        #expect(entries.count == 1_710)
        var outline: Outline!
        let buildTime = clock.measure { outline = Outline(pdfEntries: entries, pageCount: 1_500) }

        var total = 0
        let lookupTime = clock.measure {
            for _ in 0..<20 {
                for page in 0..<1_500 { total &+= outline.headingPath(forPage: page).count }
            }
        }
        #expect(outline.pathTitles(5).isEmpty)
        #expect(outline.headingPath(forPage: 1_499).count == 3)
        #expect(outline.headingPath(forPage: 700).map(\.level) == [1, 2, 3])
        #expect(total > 0)
        // Generous bounds for debug builds on CI: 30,000 lookups and one build.
        #expect(buildTime < .seconds(1), "build took \(buildTime)")
        #expect(lookupTime < .seconds(1), "30,000 lookups took \(lookupTime)")
    }
}
