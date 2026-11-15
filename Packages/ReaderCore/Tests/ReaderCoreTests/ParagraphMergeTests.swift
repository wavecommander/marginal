import Foundation
import Testing
@testable import ReaderCore

/// `p("A B C")` → `["A", "B", "C"]`; `_` stands for a blank paragraph.
private func p(_ spec: String) -> [String] {
    spec.split(separator: " ").map { $0 == "_" ? "" : String($0) }
}

private func merged(_ local: String, _ incoming: String) -> [String] {
    ParagraphMerge.merge(local: p(local), incoming: p(incoming)).paragraphs
}

/// Length of a longest common subsequence, by the textbook table (the reference for "shortest").
private func lcsLength(_ a: [String], _ b: [String]) -> Int {
    var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in a.indices.reversed() {
        for j in b.indices.reversed() {
            table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
        }
    }
    return table[0][0]
}

/// Checks the result's invariants: each side appears in order at its mapped positions, and the
/// union is a shortest common supersequence.
private func checkInvariants(_ local: [String], _ incoming: [String], _ result: ParagraphMerge.Result,
                             _ comment: Comment = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(result.localIndices.count == local.count, comment, sourceLocation: sourceLocation)
    #expect(result.incomingIndices.count == incoming.count, comment, sourceLocation: sourceLocation)
    for (side, indices) in [(local, result.localIndices), (incoming, result.incomingIndices)] {
        #expect(zip(indices, indices.dropFirst()).allSatisfy { $0 < $1 }, comment, sourceLocation: sourceLocation)
        #expect(indices.map { result.paragraphs[$0] } == side, comment, sourceLocation: sourceLocation)
    }
    // Every merged paragraph comes from one side or the other.
    let covered = Set(result.localIndices).union(result.incomingIndices)
    #expect(covered == Set(result.paragraphs.indices), comment, sourceLocation: sourceLocation)
    #expect(result.paragraphs.count == local.count + incoming.count - lcsLength(local, incoming), comment,
            sourceLocation: sourceLocation)
}

@Suite("ParagraphMerge")
struct ParagraphMergeTests {
    // MARK: Insertions

    @Test func insertionAtTheStartOnEitherSide() {
        #expect(merged("X A B", "A B") == p("X A B"))
        #expect(merged("A B", "X A B") == p("X A B"))
    }

    @Test func insertionInTheMiddleOnEitherSide() {
        #expect(merged("A X B", "A B") == p("A X B"))
        #expect(merged("A B", "A X B") == p("A X B"))
    }

    @Test func insertionAtTheEndOnEitherSide() {
        #expect(merged("A B X", "A B") == p("A B X"))
        #expect(merged("A B", "A B X") == p("A B X"))
    }

    @Test func bothSidesInsertAtTheSamePlaceLocalFirst() {
        #expect(merged("A X B", "A Y B") == p("A X Y B"))
        #expect(merged("X A", "Y A") == p("X Y A"))
        #expect(merged("A X", "A Y") == p("A X Y"))
        #expect(merged("A X1 X2 B", "A Y1 Y2 B") == p("A X1 X2 Y1 Y2 B"))
    }

    @Test func insertionsOnBothSidesAtDifferentPlaces() {
        #expect(merged("A X B C", "A B C Y") == p("A X B C Y"))
    }

    // MARK: Edits, disjoint, empty, repeats

    @Test func editedParagraphKeepsBothWordingsLocalFirst() {
        #expect(merged("A B2 C", "A B C") == p("A B2 B C"))
        #expect(merged("A B C", "A B2 C") == p("A B B2 C"))
    }

    @Test func disjointTexts() {
        #expect(merged("A B", "C D") == p("A B C D"))
    }

    @Test func oneSideEmpty() {
        #expect(ParagraphMerge.merge(local: [], incoming: p("A B")).paragraphs == p("A B"))
        #expect(ParagraphMerge.merge(local: p("A B"), incoming: []).paragraphs == p("A B"))
        #expect(ParagraphMerge.merge(local: [], incoming: []).paragraphs == [])
    }

    @Test func repeatedIdenticalParagraphs() {
        #expect(merged("A A", "A") == p("A A"))
        #expect(merged("A", "A A A") == p("A A A"))
        #expect(merged("A X A", "A Y A") == p("A X Y A"))
        #expect(merged("A B A", "B A B") == p("A B A B"))
    }

    @Test func crossedOrderPutsTheLocalParagraphFirst() {
        #expect(merged("A B", "B A") == p("A B A"))
    }

    // MARK: Blank paragraphs

    @Test func blankLinesAreSharedNotDoubled() {
        #expect(merged("A _ B", "A _ C") == p("A _ B C"))
        #expect(merged("A _ B", "A _ B _ C") == p("A _ B _ C"))
        #expect(merged("_ _ A", "_ _ A") == p("_ _ A"))
        #expect(merged("A _ _ B", "A _ B") == p("A _ _ B"))
    }

    @Test func sharedTextIsPreferredToASharedBlankLine() {
        // Sharing the blank line instead of B would give A B _ B C: B twice.
        #expect(merged("A _ B", "B _ C") == p("A _ B _ C"))
        // Whitespace-only paragraphs count as blank.
        #expect(ParagraphMerge.merge(local: ["A", " ", "B"], incoming: ["B", " ", "C"]).paragraphs == ["A", " ", "B", " ", "C"])
    }

    // MARK: Mapping

    @Test func mappingSaysWhereEachParagraphWent() {
        let result = ParagraphMerge.merge(local: p("A X B"), incoming: p("A Y B Z"))
        #expect(result.paragraphs == p("A X Y B Z"))
        #expect(result.localIndices == [0, 1, 3])
        #expect(result.incomingIndices == [0, 2, 3, 4])
    }

    // MARK: Texts

    @Test func textWithItselfIsUnchanged() {
        for text in ["", "A", "A\n", "A\n\nB\n", "A\r\nB", "\n", "  \n\n"] {
            let result = ParagraphMerge.mergeText(local: text, incoming: text)
            #expect(result.text == text)
            #expect(result.localIndices == Array(NoteBandLayout.paragraphs(of: text).indices))
            #expect(result.incomingIndices == result.localIndices)
        }
    }

    @Test func textsMergeThroughTheirParagraphs() {
        let result = ParagraphMerge.mergeText(local: "Intro\nMine\nEnd", incoming: "Intro\nTheirs\nEnd")
        #expect(result.text == "Intro\nMine\nTheirs\nEnd")
        #expect(result.paragraphs == ["Intro", "Mine", "Theirs", "End"])
        #expect(result.localIndices == [0, 1, 3])
        #expect(result.incomingIndices == [0, 2, 3])
    }

    @Test func trailingNewlineIsTheEndOfTheTextNotABlankLine() {
        // Only the local text ends in a newline: it stays at the end.
        var result = ParagraphMerge.mergeText(local: "A\nB\n", incoming: "A\nC")
        #expect(result.text == "A\nB\nC\n")
        #expect(result.localIndices == [0, 1, 3])
        #expect(result.incomingIndices == [0, 2])
        // Only the incoming text does.
        result = ParagraphMerge.mergeText(local: "A\nB", incoming: "A\nC\n")
        #expect(result.text == "A\nB\nC\n")
        #expect(result.incomingIndices == [0, 2, 3])
        // Same paragraphs, newline only on one side: the merged text keeps the newline.
        #expect(ParagraphMerge.mergeText(local: "A\nB", incoming: "A\nB\n").text == "A\nB\n")
        #expect(ParagraphMerge.mergeText(local: "A\nB\n", incoming: "A\nB").text == "A\nB\n")
        // Both end in a newline.
        #expect(ParagraphMerge.mergeText(local: "A\n", incoming: "B\n").text == "A\nB\n")
        // A real blank line before the end is a paragraph like any other.
        #expect(ParagraphMerge.mergeText(local: "A\n\n", incoming: "A\nB").text == "A\n\nB\n")
    }

    @Test func oneTextEmpty() {
        var result = ParagraphMerge.mergeText(local: "A\nB", incoming: "")
        #expect(result.text == "A\nB")
        #expect(result.incomingIndices == [1], "the empty text's only paragraph maps to the last one")
        result = ParagraphMerge.mergeText(local: "", incoming: "A\nB\n")
        #expect(result.text == "A\nB\n")
        #expect(result.localIndices == [2])
        #expect(result.incomingIndices == [0, 1, 2])
    }

    @Test func localLineBreaksSurviveWhenTheLocalTextAlreadyHasEverything() {
        let local = "A\r\nB\rC"
        let result = ParagraphMerge.mergeText(local: local, incoming: "A\nC")
        #expect(result.text == local)
        #expect(result.incomingIndices == [0, 2])
        // Otherwise paragraphs are joined with "\n".
        #expect(ParagraphMerge.mergeText(local: local, incoming: "A\nD").text == "A\nB\nC\nD")
    }

    // MARK: Properties

    @Test func propertiesOverGeneratedLists() {
        let vocabulary = ["A", "B", "C", "D", "E", "", "", " "]
        for seed in UInt64(0)..<400 {
            var rng = SeededGenerator(state: seed)
            func list() -> [String] {
                (0..<Int.random(in: 0...9, using: &rng)).map { _ in vocabulary.randomElement(using: &rng)! }
            }
            let a = list(), b = list()
            let ab = ParagraphMerge.merge(local: a, incoming: b)
            checkInvariants(a, b, ab, "seed \(seed): \(a) + \(b)")
            #expect(ParagraphMerge.merge(local: a, incoming: a).paragraphs == a, "seed \(seed)")
            #expect(ParagraphMerge.merge(local: ab.paragraphs, incoming: b).paragraphs == ab.paragraphs, "seed \(seed)")
            #expect(ParagraphMerge.merge(local: ab.paragraphs, incoming: a).paragraphs == ab.paragraphs, "seed \(seed)")
            #expect(ParagraphMerge.merge(local: a, incoming: b) == ab, "seed \(seed): deterministic")
        }
    }

    @Test func textPropertiesOverGeneratedTexts() {
        let vocabulary = ["A", "B", "C", "D", "", "", " "]
        let separators = ["\n", "\n", "\r\n"]
        for seed in UInt64(0)..<400 {
            var rng = SeededGenerator(state: seed)
            func text() -> String {
                var result = ""
                for k in 0..<Int.random(in: 0...6, using: &rng) {
                    if k > 0 { result += separators.randomElement(using: &rng)! }
                    result += vocabulary.randomElement(using: &rng)!
                }
                if Bool.random(using: &rng) { result += "\n" }
                return result
            }
            let a = text(), b = text()
            let ab = ParagraphMerge.mergeText(local: a, incoming: b)
            let comment: Comment = "seed \(seed): \(a.debugDescription) + \(b.debugDescription)"
            #expect(ab.paragraphs == NoteBandLayout.paragraphs(of: ab.text), comment)
            #expect(ab.localIndices.count == NoteBandLayout.paragraphs(of: a).count, comment)
            #expect(ab.incomingIndices.count == NoteBandLayout.paragraphs(of: b).count, comment)
            for indices in [ab.localIndices, ab.incomingIndices] {
                #expect(indices.allSatisfy(ab.paragraphs.indices.contains), comment)
                #expect(zip(indices, indices.dropFirst()).allSatisfy { $0 <= $1 }, comment)
            }
            // Every non-final paragraph of each side is found, with its text, where it maps.
            for (text, indices) in [(a, ab.localIndices), (b, ab.incomingIndices)] {
                let paragraphs = NoteBandLayout.paragraphs(of: text)
                for k in paragraphs.indices.dropLast() {
                    #expect(ab.paragraphs[indices[k]] == paragraphs[k], comment)
                }
            }
            #expect(ParagraphMerge.mergeText(local: a, incoming: a).text == a, comment)
            #expect(ParagraphMerge.mergeText(local: ab.text, incoming: b).text == ab.text, comment)
            #expect(ParagraphMerge.mergeText(local: ab.text, incoming: a).text == ab.text, comment)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func thousandsOfParagraphs() {
        // Worst case for the table: the middle differs throughout but every text is on both sides.
        let count = 3_000
        let local = (0..<count).map { "Paragraph \($0 % 1_000)" }
        let incoming = (0..<count).map { "Paragraph \(($0 * 7 + 3) % 1_000)" }
        let result = ParagraphMerge.merge(local: local, incoming: incoming)
        #expect(result.localIndices.map { result.paragraphs[$0] } == local)
        #expect(result.incomingIndices.map { result.paragraphs[$0] } == incoming)
        #expect(result.paragraphs.count < 2 * count)

        // The usual case: a long note with a few paragraphs added on each side.
        var mine = (0..<count).map { "Line \($0)" }, theirs = mine
        mine.insert("Mine", at: 1_500)
        theirs.insert("Theirs", at: 10)
        theirs.append("Theirs at the end")
        let text = ParagraphMerge.mergeText(local: mine.joined(separator: "\n"), incoming: theirs.joined(separator: "\n"))
        #expect(text.paragraphs.count == count + 3)
    }
}
