import PencilKit

/// Reconciling one page's ink between windows (design: "The same book in two windows stays
/// consistent"; a surface mid-stroke is never overwritten).
///
/// ## The rule (three-way merge, never silently dropping a stroke)
/// `local` is this window's drawing, `remote` the drawing another window stored, `base` the
/// stored drawing both started from (the last state this window loaded or saved). Strokes are
/// matched by identity (`StrokeIdentity`: creation time, random seed, path; stable across moves,
/// recolouring and encoding) plus occurrence, and compared by placed content
/// (`StrokeFingerprint`: ink, colour, path, full transform, mask).
/// - A stroke added on either side since `base` is kept.
/// - A stroke erased on one side is removed only if the other side left it unchanged; if the
///   other side edited it (moved, recoloured, partly erased), the edit wins and it is kept.
/// - A stroke edited on one side only takes that side's version; edited on both, local wins.
/// - With no `base` (nothing known in common) the result is the union.
/// - Order: the remote (stored) z-order, then local additions on top in local order. So a
///   window with no local change ends up with exactly the stored drawing, and two windows
///   converge instead of rewriting each other's order.
///
/// The same rule as the note page's `NoteInk.merge` (WP13), applied to page ink, which has no
/// bands: strokes are compared with their full transform.
nonisolated enum PageInkMerge {
    static func merge(local: PKDrawing, remote: PKDrawing, base: PKDrawing?) -> PKDrawing {
        PKDrawing(strokes: merge(local: local.strokes, remote: remote.strokes, base: base?.strokes))
    }

    static func merge(local: [PKStroke], remote: [PKStroke], base: [PKStroke]?) -> [PKStroke] {
        var baseContent: [StrokeKey: StrokeFingerprint] = [:]
        if let base {
            for (key, stroke) in keyed(base) { baseContent[key] = StrokeFingerprint(stroke) }
        }
        let localKeyed = keyed(local)
        let remoteKeyed = keyed(remote)
        var localByKey: [StrokeKey: PKStroke] = [:]
        for (key, stroke) in localKeyed { localByKey[key] = stroke }
        let remoteKeys = Set(remoteKeyed.map(\.0))

        var result: [PKStroke] = []
        result.reserveCapacity(max(local.count, remote.count))
        // Strokes the remote side has, in its order.
        for (key, remoteStroke) in remoteKeyed {
            let baseValue = baseContent[key]
            if let localStroke = localByKey[key] {
                // On both sides: the remote version only if it alone changed since base.
                if let baseValue, StrokeFingerprint(localStroke) == baseValue,
                   StrokeFingerprint(remoteStroke) != baseValue {
                    result.append(remoteStroke)
                } else {
                    result.append(localStroke)
                }
            } else if let baseValue, StrokeFingerprint(remoteStroke) == baseValue {
                continue  // erased locally, unchanged remotely
            } else {
                result.append(remoteStroke)  // added remotely, or edited remotely and erased locally
            }
        }
        // Strokes only the local side has, on top.
        for (key, localStroke) in localKeyed where !remoteKeys.contains(key) {
            if let baseValue = baseContent[key], StrokeFingerprint(localStroke) == baseValue {
                continue  // erased remotely, unchanged locally
            }
            result.append(localStroke)  // added locally, or edited locally and erased remotely
        }
        return result
    }

    /// Whether two drawings hold the same strokes (same identities and placed content) in the
    /// same order.
    static func sameStrokes(_ a: PKDrawing, _ b: PKDrawing) -> Bool {
        sameStrokes(a.strokes, b.strokes)
    }

    static func sameStrokes(_ a: [PKStroke], _ b: [PKStroke]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { StrokeFingerprint($0) == StrokeFingerprint($1) }
    }

    /// Strokes paired with identity keys (identity plus occurrence among equal identities).
    private static func keyed(_ strokes: [PKStroke]) -> [(StrokeKey, PKStroke)] {
        var seen: [StrokeIdentity: Int] = [:]
        return strokes.map { stroke in
            let identity = StrokeIdentity(stroke)
            let occurrence = seen[identity, default: 0]
            seen[identity] = occurrence + 1
            return (StrokeKey(identity: identity, occurrence: occurrence), stroke)
        }
    }
}
