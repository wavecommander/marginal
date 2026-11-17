import Foundation

/// How the Library orders its books. Stored (shared by all windows) as the raw value in
/// `@AppStorage("library.sort")`.
public enum LibrarySort: String, CaseIterable, Identifiable, Sendable {
    case recentlyOpened, title, dateAdded

    public static let storageKey = "library.sort"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .recentlyOpened: "Recently Opened"
        case .title: "Title"
        case .dateAdded: "Date Added"
        }
    }

    public var systemImage: String {
        switch self {
        case .recentlyOpened: "clock"
        case .title: "textformat"
        case .dateAdded: "calendar.badge.plus"
        }
    }
}

/// The Library's pure rules: ordering, search, "continue reading", and the strings shown for a
/// book. No UI and no store access, so they are unit-tested directly.
public enum LibraryLogic {
    /// `books` in the order of `sort`. Recently opened: latest `lastOpenedAt` first, books never
    /// opened after them, newest import first. Title: localized, case-insensitive, numbers in
    /// natural order ("Chapter 2" before "Chapter 10"). Date added: newest first. Ties end on
    /// the ID so the order is stable.
    public static func sorted(_ books: [Book], by sort: LibrarySort) -> [Book] {
        books.sorted { lhs, rhs in
            switch sort {
            case .recentlyOpened:
                switch (lhs.lastOpenedAt, rhs.lastOpenedAt) {
                case let (l?, r?) where l != r: return l > r
                case (.some, .none): return true
                case (.none, .some): return false
                default: break
                }
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
            case .title:
                let order = lhs.title.localizedStandardCompare(rhs.title)
                if order != .orderedSame { return order == .orderedAscending }
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt < rhs.addedAt }
            case .dateAdded:
                if lhs.addedAt != rhs.addedAt { return lhs.addedAt > rhs.addedAt }
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// Books whose title contains `query` (case, diacritic and width insensitive), plus those in
    /// `noteMatches` (books with a note or highlight that contains it). An empty query keeps all.
    public static func filtered(_ books: [Book], query: String, noteMatches: Set<UUID> = []) -> [Book] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return books }
        return books.filter { $0.title.localizedStandardContains(trimmed) || noteMatches.contains($0.id) }
    }

    /// The most recently opened book, or `nil` if none has been opened.
    public static func continueReading(_ books: [Book]) -> Book? {
        books.filter { $0.lastOpenedAt != nil }.max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
    }

    // MARK: Strings

    /// Percent read, or `nil` for a book that was never opened.
    public static func percentRead(_ book: Book) -> Int? {
        guard book.lastOpenedAt != nil else { return nil }
        return Int((book.progress * 100).rounded())
    }

    /// Progress for the bar: `0` for a book never opened.
    public static func progressFraction(_ book: Book) -> Double {
        book.lastOpenedAt == nil ? 0 : book.progress
    }

    /// "742 pages · 148 MB".
    public static func detailLine(_ book: Book) -> String {
        "\(pagesText(book.pageCount)) · \(sizeText(book.fileSize))"
    }

    public static func pagesText(_ count: Int) -> String {
        "\(count.formatted(.number)) \(count == 1 ? "page" : "pages")"
    }

    public static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "Title, 742 pages, 42 percent read" (VoiceOver).
    public static func accessibilityLabel(_ book: Book) -> String {
        let progress = percentRead(book).map { "\($0) percent read" } ?? "not started"
        return "\(book.title), \(pagesText(book.pageCount)), \(progress)"
    }

    /// "Page 312 of 742".
    public static func pageLine(_ book: Book) -> String {
        "Page \((book.lastReadPageIndex + 1).formatted(.number)) of \(book.pageCount.formatted(.number))"
    }

    /// "20 notes and highlights" (nothing for zero).
    public static func annotationLine(count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count.formatted(.number)) \(count == 1 ? "note or highlight" : "notes and highlights")"
    }

    /// The text of the delete confirmation: what goes with the book.
    public static func deletionMessage(title: String, summary: BookDeletionSummary) -> String {
        func count(_ n: Int, _ one: String, _ many: String) -> String? {
            n > 0 ? "\(n.formatted(.number)) \(n == 1 ? one : many)" : nil
        }
        var parts = ["the PDF file"]
        parts += [
            count(summary.notes, "note", "notes"),
            count(summary.highlights, "highlight", "highlights"),
            count(summary.inkedPages, "page of ink", "pages of ink"),
            count(summary.records.bookmarks, "bookmark", "bookmarks"),
            count(summary.records.userHeadings, "heading you added", "headings you added"),
        ].compactMap { $0 }
        let list = parts.count > 1
            ? parts.dropLast().joined(separator: ", ") + " and " + parts.last!
            : parts[0]
        return "This permanently removes “\(title)”: \(list). This can't be undone."
    }

    /// `true` if any of the texts contains the query (used for notes and highlights).
    public static func anyText(_ texts: some Sequence<String>, contains query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return texts.contains { $0.localizedStandardContains(trimmed) }
    }

    /// How many of the texts contain the query, matched like `anyText` and like the Notebook's
    /// search (`NotebookFeed.rows`), so a book's count in Library search equals the rows its
    /// results show. `0` for an empty query.
    public static func matchCount(_ texts: some Sequence<String>, query: String) -> Int {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return texts.reduce(0) { $0 + ($1.localizedStandardContains(trimmed) ? 1 : 0) }
    }

    /// The books with matching notes or highlights, in Library search's order: most matches
    /// first, ties in the Library's own `sort`. Books with no matches (absent or `0` in
    /// `counts`) are left out.
    public static func searchResultOrder(_ books: [Book], counts: [UUID: Int], sort: LibrarySort) -> [Book] {
        let matching = books.filter { (counts[$0.id] ?? 0) > 0 }
        let rank = Dictionary(uniqueKeysWithValues: sorted(matching, by: sort).enumerated().map { ($1.id, $0) })
        return matching.sorted { lhs, rhs in
            let l = counts[lhs.id] ?? 0, r = counts[rhs.id] ?? 0
            if l != r { return l > r }
            return (rank[lhs.id] ?? 0) < (rank[rhs.id] ?? 0)
        }
    }

    /// Books whose title contains `query` (as `filtered` matches titles), in `sort` order.
    public static func titleMatches(_ books: [Book], query: String, sort: LibrarySort) -> [Book] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return sorted(books.filter { $0.title.localizedStandardContains(trimmed) }, by: sort)
    }

    /// "1 match", "12 matches".
    public static func matchesText(_ count: Int) -> String {
        "\(count.formatted(.number)) \(count == 1 ? "match" : "matches")"
    }

    /// "1 book", "5 books".
    public static func booksText(_ count: Int) -> String {
        "\(count.formatted(.number)) \(count == 1 ? "book" : "books")"
    }

    /// Index into a palette of `count` colours, stable across launches (not `hashValue`).
    public static func paletteIndex(for text: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var sum: UInt64 = 5381
        for byte in text.utf8 { sum = (sum &* 33) &+ UInt64(byte) }
        return Int(sum % UInt64(count))
    }
}
