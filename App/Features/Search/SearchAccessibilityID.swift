/// Accessibility identifiers of the search UI (the shared `AccessibilityID` file belongs to the
/// shell). UI tests mirror these strings.
nonisolated enum SearchAccessibilityID {
    static let panel = "search.panel"
    static let field = "search.field"
    static let clear = "search.clear"
    static let done = "search.done"
    /// Cancel while searching.
    static let cancel = "search.cancel"
    /// Continue (after Cancel) or Show More Results (after the cap).
    static let resume = "search.resume"
    static let status = "search.status"
    static let results = "search.results"
    static let next = "search.next"
    static let previous = "search.previous"
    /// One per result: `search.result.<result id>`.
    static func result(_ id: String) -> String { "search.result.\(id)" }
    /// Group header: `search.group.<group id>`.
    static func group(_ id: String) -> String { "search.group.\(id)" }
}
