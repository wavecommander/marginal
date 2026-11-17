import Foundation
import Testing
@testable import ReaderCore

private func merge3(_ local: String, _ remote: String, _ base: String) -> ParagraphMerge.ThreeWayTextResult {
    ParagraphMerge.mergeText(local: local, remote: remote, base: base)
}

/// Each side's surviving paragraphs appear at their mapped positions, in order.
private func checkMaps(_ result: ParagraphMerge.ThreeWayTextResult, _ local: String, _ remote: String, _ base: String,
                       _ comment: Comment = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(result.paragraphs == NoteBandLayout.paragraphs(of: result.text), comment, sourceLocation: sourceLocation)
    for (text, map) in [(local, result.localIndices), (remote, result.remoteIndices), (base, result.baseIndices)] {
        let paragraphs = NoteBandLayout.paragraphs(of: text)
        #expect(map.count == paragraphs.count, comment, sourceLocation: sourceLocation)
        let kept = map.compactMap { $0 }
        #expect(zip(kept, kept.dropFirst()).allSatisfy { $0 <= $1 }, comment, sourceLocation: sourceLocation)
        for (k, index) in map.enumerated().dropLast() {   // the last may be the end of the text
            guard let index else { continue }
            #expect(result.paragraphs.indices.contains(index), comment, sourceLocation: sourceLocation)
            if result.paragraphs.indices.contains(index) {
                #expect(result.paragraphs[index] == paragraphs[k], comment, sourceLocation: sourceLocation)
            }
        }
    }
}

@Suite("ParagraphMerge three-way")
struct ParagraphMergeThreeWayTests {
    @Test func aSideEqualToTheBaseGivesTheOtherSideExactly() {
        let base = "A\nB", edited = "A\r\nB\r\nC"
        let r = merge3(base, edited, base)
        #expect(r.text == edited)
        #expect(r.remoteIndices == [0, 1, 2] && r.localIndices == [0, 1] && r.baseIndices == [0, 1])
        #expect(merge3(edited, base, base).text == edited)
        #expect(merge3(edited, edited, base).text == edited)
    }

    @Test func rewordOnOneSideAndAddOnTheOther() {
        let r = merge3("A\nB1\nC", "A\nB\nC\nD", "A\nB\nC")
        #expect(r.text == "A\nB1\nC\nD")
        #expect(r.localIndices == [0, 1, 2] && r.remoteIndices == [0, nil, 2, 3] && r.baseIndices == [0, nil, 2])
        checkMaps(r, "A\nB1\nC", "A\nB\nC\nD", "A\nB\nC")
    }

    @Test func aParagraphBothRewordedAppearsInBothWordingsLocalFirst() {
        let r = merge3("A\nB1\nC", "A\nB2\nC", "A\nB\nC")
        #expect(r.text == "A\nB1\nB2\nC")
        #expect(r.localIndices == [0, 1, 3] && r.remoteIndices == [0, 2, 3] && r.baseIndices == [0, nil, 3])
    }

    @Test func removalOnOneSideAppliesWhereTheOtherLeftTheParagraph() {
        #expect(merge3("A\nC\nD", "A\nB\nC\nD2", "A\nB\nC\nD").text == "A\nC\nD2")
        #expect(merge3("A\nB\nC\nD2", "A\nC\nD", "A\nB\nC\nD").text == "A\nC\nD2")
    }

    @Test func aRewordBeatsARemoval() {
        #expect(merge3("A\nC", "A\nB2\nC", "A\nB\nC").text == "A\nB2\nC")
        #expect(merge3("A\nB2\nC", "A\nC", "A\nB\nC").text == "A\nB2\nC")
    }

    @Test func bothSidesAddingOrRemovingTheSameParagraphDoItOnce() {
        #expect(merge3("A\nB\nC", "A\nB\nC\nD", "A\nC").text == "A\nB\nC\nD")
        #expect(merge3("A\nC\nX", "A\nC\nY", "A\nB\nC").text == "A\nC\nX\nY")
        #expect(merge3("A", "A\nZ", "A\nB").text == "A\nZ")
    }

    @Test func differentAdditionsAtOnePlaceKeepBothLocalFirst() {
        let r = merge3("A\nL\nC", "A\nR\nC", "A\nC")
        #expect(r.text == "A\nL\nR\nC")
        #expect(r.baseIndices == [0, 3])
    }

    @Test func bothRemovingEverythingGivesEmptyText() {
        let r = merge3("B", "A", "A\nB")
        #expect(r.text == "" && r.paragraphs == [""])
        #expect(r.localIndices == [nil] && r.remoteIndices == [nil] && r.baseIndices == [nil, nil])
    }

    @Test func theFinalNewlineFollowsTheSideThatChangedIt() {
        #expect(merge3("A\nB", "A\n", "A").text == "A\nB\n")
        #expect(merge3("A\nB\n", "A\nC\n", "A\n").text == "A\nB\nC\n")
        #expect(merge3("A\nB", "A\nC\n", "A\n").text == "A\nB\nC", "local removed the final newline")
    }

    @Test func generatedEditsKeepAdditionsAndApplyRemovals() {
        for seed in UInt64(1)...400 {
            var rng = SeededGenerator(state: seed)
            var counter = 0
            func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &rng) }
            let base = (0..<int(0...6)).map { "P\($0)" }
            func edit(_ side: String) -> [String] {
                var paragraphs = base
                for _ in 0..<int(0...3) {
                    switch int(0...3) {
                    case 0:
                        counter += 1
                        paragraphs.insert("\(side)\(counter)", at: int(0...paragraphs.count))
                    case 1 where !paragraphs.isEmpty:
                        let k = int(0...paragraphs.count - 1)
                        if paragraphs[k].hasPrefix("P") { paragraphs[k] += side }
                    case 2 where !paragraphs.isEmpty:
                        paragraphs.remove(at: int(0...paragraphs.count - 1))
                    default:
                        paragraphs.append(["Same", "Other"][int(0...1)])
                    }
                }
                return paragraphs
            }
            let l = edit("L"), r = edit("R")
            let local = l.joined(separator: "\n"), remote = r.joined(separator: "\n"), baseText = base.joined(separator: "\n")
            let result = merge3(local, remote, baseText)
            let comment: Comment = "seed \(seed): \(l) \(r) \(base)"
            checkMaps(result, local, remote, baseText, comment)
            let merged = Set(result.paragraphs)
            for paragraph in l + r where !base.contains(paragraph) {
                #expect(merged.contains(paragraph), comment)
            }
            for paragraph in base {
                #expect(merged.contains(paragraph) == (l.contains(paragraph) && r.contains(paragraph)), comment)
            }
            // A side that changed nothing adopts the other exactly.
            #expect(merge3(baseText, remote, baseText).text == remote, comment)
            #expect(merge3(result.text, result.text, local).text == result.text, comment)
        }
    }
}
