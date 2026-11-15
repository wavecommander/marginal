import Foundation

/// Locale-independent "natural" ordering for file and archive entry names: digit runs compare
/// by numeric value (`page2` < `page10`), letters compare case-insensitively, and paths compare
/// component by component (`ch1/p10` < `ch2/p1`). The order is total and deterministic: names
/// equal under those rules are tie-broken by leading zeros, then by exact Unicode scalars.
public enum NaturalSort {
    /// Compares two names (or `/`-separated paths).
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let primary = compareIgnoringTies(lhs, rhs)
        if primary != .orderedSame { return primary }
        // Tie-breaks: fewer leading zeros first ("p1" < "p01"), then exact case/scalars.
        let zeros = leadingZeroSignature(lhs).lexicographicallyPrecedes(leadingZeroSignature(rhs))
        if zeros { return .orderedAscending }
        if leadingZeroSignature(rhs).lexicographicallyPrecedes(leadingZeroSignature(lhs)) { return .orderedDescending }
        let a = Array(lhs.unicodeScalars.map(\.value)), b = Array(rhs.unicodeScalars.map(\.value))
        if a == b { return .orderedSame }
        return a.lexicographicallyPrecedes(b) ? .orderedAscending : .orderedDescending
    }

    /// `true` when `lhs` sorts before `rhs`.
    public static func areInIncreasingOrder(_ lhs: String, _ rhs: String) -> Bool {
        compare(lhs, rhs) == .orderedAscending
    }

    /// The names in natural order. Stable: identical names keep their input order.
    public static func sorted(_ names: [String]) -> [String] {
        sorted(names, by: { $0 })
    }

    /// The elements in natural order of `key`. Stable: equal keys keep their input order.
    public static func sorted<Element>(_ elements: [Element], by key: (Element) -> String) -> [Element] {
        let keyed = elements.enumerated().map { (offset: $0.offset, key: key($0.element), element: $0.element) }
        return keyed.sorted { a, b in
            switch compare(a.key, b.key) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: a.offset < b.offset
            }
        }.map(\.element)
    }

    // MARK: Internals

    private enum Token {
        case number(digits: [UInt8])   // ASCII digit values with leading zeros removed
        case text([UInt32])            // lower-cased, precomposed scalars
    }

    private static func compareIgnoringTies(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = components(lhs), b = components(rhs)
        for (x, y) in zip(a, b) {
            let result = compareComponent(x, y)
            if result != .orderedSame { return result }
        }
        if a.count == b.count { return .orderedSame }
        return a.count < b.count ? .orderedAscending : .orderedDescending
    }

    private static func components(_ path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: false)
    }

    private static func compareComponent(_ lhs: Substring, _ rhs: Substring) -> ComparisonResult {
        let a = tokens(lhs), b = tokens(rhs)
        for (x, y) in zip(a, b) {
            let result = compareToken(x, y)
            if result != .orderedSame { return result }
        }
        if a.count == b.count { return .orderedSame }
        return a.count < b.count ? .orderedAscending : .orderedDescending
    }

    private static func compareToken(_ lhs: Token, _ rhs: Token) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (.number(a), .number(b)):
            if a.count != b.count { return a.count < b.count ? .orderedAscending : .orderedDescending }
            if a == b { return .orderedSame }
            return a.lexicographicallyPrecedes(b) ? .orderedAscending : .orderedDescending
        case (.number, .text): return .orderedAscending
        case (.text, .number): return .orderedDescending
        case let (.text(a), .text(b)):
            if a == b { return .orderedSame }
            return a.lexicographicallyPrecedes(b) ? .orderedAscending : .orderedDescending
        }
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { scalar.value >= 48 && scalar.value <= 57 }

    private static func tokens(_ component: Substring) -> [Token] {
        // `lowercased()` and canonical composition use Unicode default mappings, not the locale.
        let normalized = String(component).precomposedStringWithCanonicalMapping.lowercased()
        var result: [Token] = []
        var digits: [UInt8] = []
        var text: [UInt32] = []
        func flushDigits() {
            guard !digits.isEmpty else { return }
            let trimmed = Array(digits.drop(while: { $0 == 0 }))
            result.append(.number(digits: trimmed))
            digits.removeAll()
        }
        func flushText() {
            guard !text.isEmpty else { return }
            result.append(.text(text))
            text.removeAll()
        }
        for scalar in normalized.unicodeScalars {
            if isDigit(scalar) {
                flushText()
                digits.append(UInt8(scalar.value - 48))
            } else {
                flushDigits()
                text.append(scalar.value)
            }
        }
        flushDigits()
        flushText()
        return result
    }

    /// The count of leading zeros of each digit run, in order (used only to break ties).
    private static func leadingZeroSignature(_ string: String) -> [Int] {
        var result: [Int] = []
        var inRun = false, zeros = 0, sawNonZero = false
        for scalar in string.unicodeScalars {
            if isDigit(scalar) {
                if !inRun { inRun = true; zeros = 0; sawNonZero = false }
                if !sawNonZero {
                    if scalar.value == 48 { zeros += 1 } else { sawNonZero = true }
                }
            } else if inRun {
                result.append(zeros)
                inRun = false
            }
        }
        if inRun { result.append(zeros) }
        return result
    }
}
