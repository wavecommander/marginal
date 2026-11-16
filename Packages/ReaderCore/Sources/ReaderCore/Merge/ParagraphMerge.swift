import Foundation

/// The ordered union of two versions of a note's paragraphs, used when a restore merges a note
/// that exists on both sides with different text (`BookMerge`).
///
/// **What it builds:** a shortest common supersequence of the two paragraph lists. Every
/// paragraph of each side appears, in that side's order; a paragraph with the same text on both
/// sides that the alignment pairs up appears once. Paragraphs are compared by exact text, which is
/// the identity `NoteBands` uses to move handwriting with its paragraph, so a paragraph edited on
/// one side appears twice (old and new wording).
///
/// **Rules where several supersequences are equally short:**
/// - *Which paragraphs are shared.* Among the alignments that share the most paragraphs, the one
///   sharing the most non-blank paragraphs wins: a blank paragraph (empty or whitespace only) is
///   shared only when that costs no shared text. Without this, two notes that differ in their
///   text but both have a blank line could be aligned on the blank line and repeat their text
///   (`["A", "", "B"]` with `["B", "", "C"]` gives `["A", "", "B", "", "C"]`, not
///   `["A", "B", "", "B", "C"]`). Remaining ties are broken by walking both lists from the start
///   and, where two different paragraphs meet and either could be passed over without sharing
///   less, passing over the local one, so it comes first.
/// - *Order in a gap.* Between two shared paragraphs, the paragraphs only the local side has come
///   first, then those only the incoming side has, each in its own order.
/// - *Blank lines are paragraphs like any other*, compared by exact text. A blank line both sides
///   have between the same two shared paragraphs is shared, never doubled: no gap ever holds an
///   equal paragraph from each side, because sharing it would make the supersequence shorter.
///   (For the newline at the very end of a note see `mergeText`.)
///
/// So merging a list with itself, or with any list it already contains in order, returns it
/// unchanged, and `merge(merge(a, b), b) == merge(a, b)`.
///
/// **Cost:** the paragraphs are interned to integers, and the common prefix and suffix are
/// shared in O(m + n). The rest is a dynamic programme over the differing middle, restricted to
/// paragraphs whose text occurs on both sides (a paragraph only one side has can never be
/// shared): O(m′·n′) time and m′·n′ bytes, where m′ and n′ count those paragraphs. Two notes of
/// 3,000 paragraphs that differ everywhere but share all their text cost about 9 MB and a few
/// tens of milliseconds; the usual case (a few paragraphs added or edited) is close to linear.
public enum ParagraphMerge {
    /// The union of two paragraph lists and where each original paragraph went.
    public struct Result: Hashable, Sendable {
        /// The merged paragraphs, in order.
        public var paragraphs: [String]
        /// `localIndices[i]` is the index in `paragraphs` of the local side's paragraph `i`.
        /// Strictly increasing.
        public var localIndices: [Int]
        /// `incomingIndices[i]` is the index in `paragraphs` of the incoming side's paragraph `i`.
        /// Strictly increasing.
        public var incomingIndices: [Int]

        public init(paragraphs: [String], localIndices: [Int], incomingIndices: [Int]) {
            self.paragraphs = paragraphs
            self.localIndices = localIndices
            self.incomingIndices = incomingIndices
        }
    }

    /// The union of two note texts, through their paragraphs (`NoteBandLayout.paragraphs(of:)`).
    public struct TextResult: Hashable, Sendable {
        /// The merged note text.
        public var text: String
        /// `NoteBandLayout.paragraphs(of: text)`.
        public var paragraphs: [String]
        /// For each element of `NoteBandLayout.paragraphs(of: local)`, the index in `paragraphs`
        /// it maps to (see `mergeText` for the final empty paragraph). Non-decreasing.
        public var localIndices: [Int]
        /// The same for the incoming text.
        public var incomingIndices: [Int]

        public init(text: String, paragraphs: [String], localIndices: [Int], incomingIndices: [Int]) {
            self.text = text
            self.paragraphs = paragraphs
            self.localIndices = localIndices
            self.incomingIndices = incomingIndices
        }
    }

    /// `true` for a paragraph that is empty or holds only whitespace.
    public static func isBlank(_ paragraph: String) -> Bool {
        paragraph.allSatisfy(\.isWhitespace)
    }

    /// The ordered union of two paragraph lists; see the type's rules.
    public static func merge(local: [String], incoming: [String]) -> Result {
        // Intern the texts so the inner loop compares integers.
        var ids: [String: Int] = [:]
        var blank: [Bool] = []
        func intern(_ text: String) -> Int {
            if let id = ids[text] { return id }
            let id = blank.count
            ids[text] = id
            blank.append(isBlank(text))
            return id
        }
        let a = local.map(intern), b = incoming.map(intern)
        let m = a.count, n = b.count

        // Shared prefix and suffix. Pairing equal ends is always part of a best alignment.
        var prefix = 0
        while prefix < m && prefix < n && a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < m - prefix && suffix < n - prefix && a[m - 1 - suffix] == b[n - 1 - suffix] { suffix += 1 }

        // The differing middle, keeping only paragraphs whose text the other side also has.
        let middleA = prefix..<(m - suffix), middleB = prefix..<(n - suffix)
        let textsInB = Set(b[middleB]), textsInA = Set(a[middleA])
        let fa = middleA.filter { textsInB.contains(a[$0]) }
        let fb = middleB.filter { textsInA.contains(b[$0]) }

        // Anchors: pairs (local index, incoming index) of shared paragraphs in the middle.
        var anchors: [(Int, Int)] = []
        if !fa.isEmpty && !fb.isEmpty {
            let p = fa.count, q = fb.count
            // Lexicographic score (shared paragraphs, shared non-blank paragraphs) as one integer.
            let scale = min(p, q) + 1
            func weight(_ text: Int) -> Int { blank[text] ? scale : scale + 1 }
            // Suffix scores in two rolling rows; the step to take from each cell in `step`
            // (0 share, 1 skip the local paragraph, 2 skip the incoming one).
            var below = [Int](repeating: 0, count: q + 1)
            var row = [Int](repeating: 0, count: q + 1)
            var step = [UInt8](repeating: 0, count: p * q)
            for i in stride(from: p - 1, through: 0, by: -1) {
                row[q] = 0
                let x = a[fa[i]]
                for j in stride(from: q - 1, through: 0, by: -1) {
                    if x == b[fb[j]] {
                        row[j] = below[j + 1] + weight(x)
                        step[i * q + j] = 0
                    } else if below[j] >= row[j + 1] {
                        row[j] = below[j]
                        step[i * q + j] = 1
                    } else {
                        row[j] = row[j + 1]
                        step[i * q + j] = 2
                    }
                }
                swap(&below, &row)
            }
            var i = 0, j = 0
            while i < p && j < q {
                switch step[i * q + j] {
                case 0: anchors.append((fa[i], fb[j])); i += 1; j += 1
                case 1: i += 1
                default: j += 1
                }
            }
        }

        // Emit: prefix, then each gap (local-only first) and its anchor, then the suffix.
        var paragraphs: [String] = []
        paragraphs.reserveCapacity(m + n - prefix - suffix - anchors.count)
        var localIndices = [Int](repeating: 0, count: m)
        var incomingIndices = [Int](repeating: 0, count: n)
        func shared(_ i: Int, _ j: Int) {
            localIndices[i] = paragraphs.count
            incomingIndices[j] = paragraphs.count
            paragraphs.append(local[i])
        }
        for k in 0..<prefix { shared(k, k) }
        var nextA = prefix, nextB = prefix
        for (ai, bj) in anchors + [(m - suffix, n - suffix)] {
            while nextA < ai { localIndices[nextA] = paragraphs.count; paragraphs.append(local[nextA]); nextA += 1 }
            while nextB < bj { incomingIndices[nextB] = paragraphs.count; paragraphs.append(incoming[nextB]); nextB += 1 }
            if ai < m - suffix { shared(ai, bj); nextA += 1; nextB += 1 }
        }
        for k in 0..<suffix { shared(m - suffix + k, n - suffix + k) }
        return Result(paragraphs: paragraphs, localIndices: localIndices, incomingIndices: incomingIndices)
    }

    /// Merges two note texts through `merge(local:incoming:)` on their paragraphs.
    ///
    /// **The final empty paragraph is the end of the text, not a blank line.** A text ending in a
    /// newline has an empty last paragraph (`"a\n"` → `["a", ""]`), and the empty text has a
    /// single empty paragraph (`""` → `[""]`). That paragraph is set aside before the lists are
    /// merged, and the merged text ends with a newline when either text did. Otherwise a trailing
    /// newline on one side would turn into a blank line in the middle of the merged note
    /// (`"a\nb\n"` with `"a\nc"` would give `"a\nb\n\nc"`; it gives `"a\nb\nc\n"`). A set-aside
    /// paragraph maps to the merged text's last paragraph, which is the merged final empty
    /// paragraph unless the side was the empty text.
    ///
    /// The merged text joins paragraphs with `"\n"`, except that when the merged paragraphs are
    /// exactly the local text's, the local text is returned as it is (so its own line breaks,
    /// such as `"\r\n"`, survive). Equal texts are returned unchanged with identity mappings.
    public static func mergeText(local: String, incoming: String) -> TextResult {
        let localParagraphs = NoteBandLayout.paragraphs(of: local)
        if local == incoming {
            let identity = Array(localParagraphs.indices)
            return TextResult(text: local, paragraphs: localParagraphs, localIndices: identity, incomingIndices: identity)
        }
        let incomingParagraphs = NoteBandLayout.paragraphs(of: incoming)
        let l = body(of: localParagraphs), r = body(of: incomingParagraphs)
        let core = merge(local: l.body, incoming: r.body)
        var paragraphs = core.paragraphs
        if l.endsWithNewline || r.endsWithNewline { paragraphs.append("") }

        let text: String
        if paragraphs == localParagraphs {
            text = local
        } else if paragraphs.isEmpty {
            text = ""
            paragraphs = [""]
        } else {
            text = paragraphs.joined(separator: "\n")
        }
        let last = paragraphs.count - 1
        func indices(_ count: Int, _ mapped: [Int]) -> [Int] {
            (0..<count).map { $0 < mapped.count ? mapped[$0] : last }
        }
        return TextResult(text: text, paragraphs: paragraphs,
                          localIndices: indices(localParagraphs.count, core.localIndices),
                          incomingIndices: indices(incomingParagraphs.count, core.incomingIndices))
    }

    /// The paragraphs that take part in the merge: all but a final empty paragraph.
    private static func body(of paragraphs: [String]) -> (body: [String], endsWithNewline: Bool) {
        guard paragraphs.last == "" else { return (paragraphs, false) }
        return (Array(paragraphs.dropLast()), paragraphs.count > 1)
    }
}
