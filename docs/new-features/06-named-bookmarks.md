# 06 · Named Bookmarks (Optional Bookmark Labels)

Draft, 18 November 2026. Read `docs/DESIGN.md` ("Concepts ▸ Bookmark", "Keeping data openable across versions") and `App/Features/Sidebar/BookmarksListView.swift` first.

## Goal

Today a `Bookmark` is a flagged page (`id`, `bookID`, `pageIndex`, `createdAt`), and tapping the toolbar bookmark button toggles it in one tap with zero friction. In a 1,200-page reference book or textbook, however, readers often bookmark 8–15 recurring lookup pages (*"Laplace Transform Table"*, *"Periodic Table"*, *"Problem Set 4"*, *"Glossary"*, *"Formula Sheet"*). When all of them sit in the same appendix or chapter, `BookmarksListView` lists them only as `Page 712`, `Page 745`, `Page 780`.

**Named Bookmarks** keeps one-tap bookmarking completely frictionless while adding an **optional label** (`Bookmark.title: String?`) that can be added or edited from the Bookmarks list, the Pages grid, or a long-press on the toolbar Bookmark button, and searched in the Notebook and Library.

---

## Principles & Invariants

1. **One-tap bookmarking stays instant.**
   - Tapping the Bookmark button in the reader toolbar (or pressing `⌘D`) still adds or removes a bookmark on the current page immediately, with no modal prompt.
   - An unnamed bookmark has `title == nil` and displays exactly as it does today (`Page 312` with the deepest heading below it).
2. **At most one bookmark per page per book (`compositeKey = "<bookID>|<pageIndex>"`).**
   - Unchanged. Naming a bookmark updates the existing `Bookmark` record for `(bookID, pageIndex)`.
3. **Full forward and backward compatibility ("Keeping data openable across versions").**
   - `title: String?` is an optional attribute added in `TactileTextsSchemaV4` and encoded with `encodeIfPresent` in backups and sync.
   - An older version opening a V4 store or backup simply ignores `title` and keeps every bookmark as an unnamed page bookmark.

---

## Behaviour Specification

### 1. Adding or Editing a Bookmark's Name

- **From `BookmarksListView` (Contents sidebar ▸ Bookmarks tab):**
  - Context menu on any bookmark row gains **Rename Bookmark…** (or **Name Bookmark…** when `title == nil`), with a swipe action on the leading edge (or alongside Remove on trailing edge).
  - Opens a lightweight alert or popover with a single text field (placeholder: `"Bookmark name (optional)"`, pre-filled with `bookmark.title ?? ""`). Saving an empty/whitespace-only string sets `title = nil` (reverts to an unnamed bookmark without deleting the bookmark).
- **From the Reader Toolbar Bookmark Button:**
  - **Tap:** toggles bookmark on/off for `currentPageIndex` (if a named bookmark is removed, the Undo toast or re-tapping within the session can restore it, or removing clears it as today).
  - **Long-press / Secondary click on the toolbar Bookmark button:**
    - If the current page is not bookmarked: offers **Bookmark & Name…** (bookmarks the page and opens the name prompt).
    - If the current page is already bookmarked: offers **Name Bookmark…** / **Rename Bookmark…** and **Remove Bookmark**.
- **From `PagesGridView` (Contents sidebar ▸ Pages tab):**
  - Context menu on a bookmarked page thumbnail includes **Rename Bookmark…**.

### 2. How Named Bookmarks Are Displayed

- **In `BookmarksListView` (`App/Features/Sidebar/BookmarksListView.swift`):**
  - **When `bookmark.title` is set (e.g., `"Laplace Transform Table"`):**
    - Primary line (`.body`, semibold when current page): `Laplace Transform Table`
    - Secondary line (`.subheadline`, `.secondary`): `p. 312 · 5.2 The Characteristic Equation` (using logical page label when an offset is set).
  - **When `bookmark.title == nil`:**
    - Primary line: `Page 312`
    - Secondary line: `5.2 The Characteristic Equation` (identical to today).
- **In Search (Library Search & Reader Search / Notebook):**
  - Searching in the book's search panel or Library search also matches non-empty `Bookmark.title` strings, so typing `"Laplace"` surfaces the named bookmark right alongside matching notes and highlights.

---

## Data, Backup, Merge & Sync Compatibility

- **Value type (`Packages/ReaderCore/Sources/ReaderCore/Model/Records.swift`):**
  - `Bookmark` gains `public var title: String?` (normalised: trimmed of leading/trailing whitespace; empty string stored as `nil`).
- **Database (`Packages/ReaderStore/Sources/ReaderStore/Schema.swift`):**
  - `TactileTextsSchemaV4.BookmarkModel` adds `var title: String?`.
- **Merge (`ReaderCore/Merge`):**
  - When merging two copies of a book that both have a bookmark on `pageIndex`:
    - In backup restore merge (`Merge`): keep `local.title ?? remote.title` (local non-nil name wins; if local is unnamed and backup has a name, adopt the backup's name).
    - In Cloud Sync (`ReaderSync`): 3-way merge against `base?.title` so renaming or clearing a bookmark name on one iPad propagates cleanly to the other.

---

## Packages & Implementation Plan

| Package | What it is | Where |
| --- | --- | --- |
| NB1 | `Bookmark.title: String?` in `ReaderCore`, `TactileTextsSchemaV4.BookmarkModel` in `ReaderStore`, backup `Codable` tests in `ReaderBackup`, and 2-way/3-way merge rules in `ReaderCore/Merge` and `ReaderSync` | `Packages/ReaderCore`, `Packages/ReaderStore`, `Packages/ReaderBackup`, `Packages/ReaderSync` |
| NB2 | UI in `BookmarksListView`, `ReaderScreen` toolbar long-press menu, `PagesGridView` context menu, rename alert/popover, and accessibility labels/identifiers | `App/Features/Sidebar/BookmarksListView.swift`, `App/Features/Reader/`, `UITests/` |

### Done when

- `swift test` in `ReaderCore`, `ReaderStore`, `ReaderBackup`, and `ReaderSync` covers `Bookmark.title` persistence, whitespace normalization (`"   " → nil`), V3→V4→V3 migration, version 1 `.ttbackup` loading (`title == nil`), and backup/sync merging of named and unnamed bookmarks.
- UI test bookmarks a page, renames it to `"Formula Sheet"` from the Bookmarks tab context menu, verifies `"Formula Sheet"` and `"p. N"` appear in the row and VoiceOver value, and verifies clearing the name returns the row to `"Page N"`.
