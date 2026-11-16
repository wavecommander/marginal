import PencilKit

/// The three-way stroke merge shared by page ink (`PageInkMerge`) and note ink (`NoteInk.merge`),
/// so the two surfaces cannot drift apart.
///
/// ## The rule (never silently dropping a stroke)
/// `local` is this side's strokes, `remote` the strokes stored by the other side, `base` the
/// stored strokes both started from (the last state this side loaded or saved). Strokes are
/// matched by identity (`StrokeIdentity`: creation time, random seed, path; stable across moves,
/// recolouring and encoding) plus occurrence among equal identities, and compared by `content`,
/// which each caller chooses (page ink: `StrokeFingerprint`, the full transform; note ink:
/// `StrokeContent` of the band-local stroke, without the vertical offset relocation changes).
/// - A stroke added on either side since `base` is kept.
/// - A stroke erased on one side is removed only if the other side left it unchanged; if the
///   other side edited it (moved, recoloured, partly erased), the edit wins and it is kept.
/// - A stroke edited on one side only takes that side's version; edited on both, local wins.
/// - With no `base` (nothing known in common) the result is the union.
///
/// ## Order (stroke order is z-order: later strokes draw on top)
/// The remote (stored) order first, then local-only strokes on top in local order. A side with
/// no local change therefore ends up with exactly the stored order, the strokes another window
/// is already showing never change places when this side saves, and what was just drawn here
/// stays on top, where the person drawing it saw it. Two windows converge instead of rewriting
/// each other's order.
nonisolated enum StrokeMerge {
    /// - Parameters:
    ///   - stroke: the PencilKit stroke an element carries (used for its identity).
    ///   - content: what tells an edited stroke from an unchanged one.
    ///   - adoptRemote: applied to every element taken from `remote`.
    static func merge<Element, Content: Equatable>(
        local: [Element], remote: [Element], base: [Element]?,
        stroke: (Element) -> PKStroke,
        content: (Element) -> Content,
        adoptRemote: (Element) -> Element = { $0 }
    ) -> [Element] {
        var baseContent: [StrokeKey: Content] = [:]
        if let base {
            for (key, element) in keyed(base, stroke: stroke) { baseContent[key] = content(element) }
        }
        let localKeyed = keyed(local, stroke: stroke)
        let remoteKeyed = keyed(remote, stroke: stroke)
        var localByKey: [StrokeKey: Element] = [:]
        for (key, element) in localKeyed { localByKey[key] = element }
        let remoteKeys = Set(remoteKeyed.map(\.0))

        var result: [Element] = []
        result.reserveCapacity(max(local.count, remote.count))
        // Strokes the remote side has, in its order.
        for (key, remoteElement) in remoteKeyed {
            let baseValue = baseContent[key]
            if let localElement = localByKey[key] {
                // On both sides: the remote version only if it alone changed since base.
                if let baseValue, content(localElement) == baseValue, content(remoteElement) != baseValue {
                    result.append(adoptRemote(remoteElement))
                } else {
                    result.append(localElement)
                }
            } else if let baseValue, content(remoteElement) == baseValue {
                continue  // erased locally, unchanged remotely
            } else {
                result.append(adoptRemote(remoteElement))  // added remotely, or edited remotely and erased locally
            }
        }
        // Strokes only the local side has, on top.
        for (key, localElement) in localKeyed where !remoteKeys.contains(key) {
            if let baseValue = baseContent[key], content(localElement) == baseValue {
                continue  // erased remotely, unchanged locally
            }
            result.append(localElement)  // added locally, or edited locally and erased remotely
        }
        return result
    }

    /// Elements paired with identity keys (identity plus occurrence among equal identities).
    private static func keyed<Element>(_ elements: [Element], stroke: (Element) -> PKStroke) -> [(StrokeKey, Element)] {
        var seen: [StrokeIdentity: Int] = [:]
        return elements.map { element in
            let identity = StrokeIdentity(stroke(element))
            let occurrence = seen[identity, default: 0]
            seen[identity] = occurrence + 1
            return (StrokeKey(identity: identity, occurrence: occurrence), element)
        }
    }
}
