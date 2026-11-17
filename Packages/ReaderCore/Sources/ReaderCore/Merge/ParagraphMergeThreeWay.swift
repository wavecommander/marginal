import Foundation

/// The three-way merge of a note's text that sync uses (`BookMerge.merge(local:remote:base:)`):
/// what each side did since the base is applied, paragraph by paragraph.
extension ParagraphMerge {
    /// A three-way merge of note texts and where each side's paragraphs went.
    public struct ThreeWayTextResult: Hashable, Sendable {
        /// The merged note text.
        public var text: String
        /// `NoteBandLayout.paragraphs(of: text)`.
        public var paragraphs: [String]
        /// For each element of `NoteBandLayout.paragraphs(of: local)`, its index in `paragraphs`,
        /// or `nil` where the merge removed that paragraph. The non-`nil` entries increase.
        public var localIndices: [Int?]
        /// The same for the remote text.
        public var remoteIndices: [Int?]
        /// The same for the base text: where each base paragraph that survived went.
        public var baseIndices: [Int?]

        public init(text: String, paragraphs: [String], localIndices: [Int?], remoteIndices: [Int?], baseIndices: [Int?]) {
            self.text = text
            self.paragraphs = paragraphs
            self.localIndices = localIndices
            self.remoteIndices = remoteIndices
            self.baseIndices = baseIndices
        }
    }

    /// Merges two versions of a note's text that both changed since `base`.
    ///
    /// **Rules** (paragraphs as `NoteBandLayout.paragraphs(of:)`, compared by exact text, the
    /// final empty paragraph set aside as in `mergeText(local:incoming:)`):
    /// - *Whole texts.* Equal local and remote texts give that text; a side equal to the base
    ///   gives the other side's text exactly (its own line breaks kept).
    /// - *Alignment.* Each side is aligned with the base as `merge(local:incoming:)` aligns two
    ///   lists (most shared paragraphs, non-blank preferred). A base paragraph both sides kept is
    ///   *stable*; the stretches between stable paragraphs are merged on their own, in order.
    /// - *A stretch one side left as the base had it* takes the other side's version; a stretch
    ///   both sides changed the same way is taken once.
    /// - *A stretch both sides changed differently:* a paragraph either side added is kept; a base
    ///   paragraph either side removed (or reworded, which is a removal and an addition) is
    ///   removed, since the other side at most left it unchanged; the added paragraphs are joined
    ///   with `merge(local:incoming:)`, so a paragraph both sides added is kept once, and where
    ///   the sides differ the local paragraphs come first. A paragraph both sides reworded
    ///   appears in both wordings, local first, as in a two-way merge.
    /// - *End of text.* The merged text ends with a newline when the local side changed that and
    ///   does, or else when the remote side does.
    ///
    /// Merging a text with the base on one side returns the other side unchanged, so a device
    /// that changed nothing adopts the other's text exactly.
    public static func mergeText(local: String, remote: String, base: String) -> ThreeWayTextResult {
        let lp = NoteBandLayout.paragraphs(of: local)
        let rp = NoteBandLayout.paragraphs(of: remote)
        let bp = NoteBandLayout.paragraphs(of: base)
        if local == remote {
            return ThreeWayTextResult(text: local, paragraphs: lp, localIndices: identity(lp), remoteIndices: identity(lp),
                                      baseIndices: alignment(of: bp, onto: lp))
        }
        if local == base {
            return ThreeWayTextResult(text: remote, paragraphs: rp, localIndices: alignment(of: lp, onto: rp),
                                      remoteIndices: identity(rp), baseIndices: alignment(of: bp, onto: rp))
        }
        if remote == base {
            return ThreeWayTextResult(text: local, paragraphs: lp, localIndices: identity(lp),
                                      remoteIndices: alignment(of: rp, onto: lp), baseIndices: alignment(of: bp, onto: lp))
        }

        let l = body(of: lp), r = body(of: rp), b = body(of: bp)
        let lb = l.body, rb = r.body, bb = b.body
        let baseToLocal = matches(bb, lb), baseToRemote = matches(bb, rb)
        var localToBase = [Int?](repeating: nil, count: lb.count)
        var remoteToBase = [Int?](repeating: nil, count: rb.count)
        for (i, j) in baseToLocal.enumerated() { if let j { localToBase[j] = i } }
        for (i, j) in baseToRemote.enumerated() { if let j { remoteToBase[j] = i } }

        var out: [String] = []
        var li = [Int?](repeating: nil, count: lb.count)
        var ri = [Int?](repeating: nil, count: rb.count)
        var bi = [Int?](repeating: nil, count: bb.count)
        var bPos = 0, lPos = 0, rPos = 0

        func region(_ bEnd: Int, _ lEnd: Int, _ rEnd: Int) {
            let bRange = bPos..<bEnd, lRange = lPos..<lEnd, rRange = rPos..<rEnd
            let bSlice = bb[bRange], lSlice = lb[lRange], rSlice = rb[rRange]
            if lSlice.elementsEqual(rSlice) {
                for (offset, k) in lRange.enumerated() {
                    li[k] = out.count; ri[rPos + offset] = out.count
                    out.append(lb[k])
                }
            } else if lSlice.elementsEqual(bSlice) {
                for k in rRange { ri[k] = out.count; out.append(rb[k]) }
            } else if rSlice.elementsEqual(bSlice) {
                for k in lRange { li[k] = out.count; out.append(lb[k]) }
            } else {
                let addedLocal = lRange.filter { localToBase[$0] == nil }
                let addedRemote = rRange.filter { remoteToBase[$0] == nil }
                let joined = merge(local: addedLocal.map { lb[$0] }, incoming: addedRemote.map { rb[$0] })
                for (k, index) in zip(addedLocal, joined.localIndices) { li[k] = out.count + index }
                for (k, index) in zip(addedRemote, joined.incomingIndices) { ri[k] = out.count + index }
                out.append(contentsOf: joined.paragraphs)
            }
            // A base paragraph goes where the side that kept it put it, if that was kept.
            for k in bRange {
                if let j = baseToLocal[k], let index = li[j] { bi[k] = index }
                else if let j = baseToRemote[k], let index = ri[j] { bi[k] = index }
            }
            bPos = bEnd; lPos = lEnd; rPos = rEnd
        }

        for k in bb.indices {
            guard let j = baseToLocal[k], let m = baseToRemote[k] else { continue }
            region(k, j, m)
            li[j] = out.count; ri[m] = out.count; bi[k] = out.count
            out.append(bb[k])
            bPos = k + 1; lPos = j + 1; rPos = m + 1
        }
        region(bb.count, lb.count, rb.count)

        let endsWithNewline = l.endsWithNewline != b.endsWithNewline ? l.endsWithNewline : r.endsWithNewline
        var paragraphs = out
        if endsWithNewline { paragraphs.append("") }
        let text: String
        if paragraphs == lp {
            text = local
        } else if paragraphs == rp {
            text = remote
        } else if paragraphs.isEmpty {
            text = ""
            paragraphs = [""]
        } else {
            text = paragraphs.joined(separator: "\n")
        }
        let last = paragraphs.count - 1
        func full(_ count: Int, _ mapped: [Int?]) -> [Int?] {
            (0..<count).map { $0 < mapped.count ? mapped[$0] : last }
        }
        return ThreeWayTextResult(text: text, paragraphs: paragraphs, localIndices: full(lp.count, li),
                                  remoteIndices: full(rp.count, ri), baseIndices: full(bp.count, bi))
    }

    private static func identity(_ paragraphs: [String]) -> [Int?] { paragraphs.indices.map { $0 } }

    /// For each paragraph of `from`, the index of the paragraph of `to` it aligns with, or `nil`.
    /// The final empty paragraph (the end of the text) maps to the last paragraph of `to`.
    static func alignment(of from: [String], onto to: [String]) -> [Int?] {
        let f = body(of: from), t = body(of: to)
        let mapped = matches(f.body, t.body)
        return from.indices.map { $0 < mapped.count ? mapped[$0] : to.count - 1 }
    }

    /// For each element of `a`, the index of the element of `b` that `merge(local:incoming:)`
    /// shares it with, or `nil`.
    private static func matches(_ a: [String], _ b: [String]) -> [Int?] {
        let joined = merge(local: a, incoming: b)
        var atMerged: [Int: Int] = [:]
        for (j, index) in joined.incomingIndices.enumerated() { atMerged[index] = j }
        return joined.localIndices.map { atMerged[$0] }
    }
}
