import Foundation
@testable import ReaderCore

/// `e("Title", 1, 10)` → a raw entry. Pages are zero-based indices.
func e(_ title: String, _ level: Int, _ page: Int?) -> RawOutlineEntry {
    RawOutlineEntry(title: title, level: level, pageIndex: page)
}

extension Outline {
    /// The node with this exact title (first in pre-order). Traps if missing.
    func titled(_ title: String) -> OutlineNode {
        guard let node = nodes.first(where: { $0.title == title }) else { fatalError("no node titled \(title)") }
        return node
    }

    /// Titles of the heading path for a page.
    func pathTitles(_ page: Int) -> [String] { headingPath(forPage: page).map(\.title) }
}

/// Deterministic pseudo-random numbers for generated outlines.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
let bookA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!

func uuid(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
}

/// A synthetic book outline: `chapters` × `sections` × `subsections`, spread evenly over
/// `pageCount` pages after 10 pages of front matter.
func syntheticEntries(pageCount: Int, chapters: Int, sections: Int, subsections: Int) -> [RawOutlineEntry] {
    var entries: [RawOutlineEntry] = []
    let leaves = chapters * sections * subsections
    let usable = pageCount - 10
    var leaf = 0
    for c in 0..<chapters {
        for s in 0..<sections {
            for u in 0..<subsections {
                let page = 10 + leaf * usable / leaves
                if s == 0 && u == 0 { entries.append(e("\(c + 1) Chapter", 1, page)) }
                if u == 0 { entries.append(e("\(c + 1).\(s + 1) Section", 2, page)) }
                entries.append(e("\(c + 1).\(s + 1).\(u + 1) Subsection", 3, page))
                leaf += 1
            }
        }
    }
    return entries
}
