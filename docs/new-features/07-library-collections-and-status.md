# 07 · Collections / Shelves & Reading Status Filters in the Library

Draft, 18 November 2026. Read `docs/DESIGN.md` ("Not in version 1", "Library search", "Keeping data openable across versions") and `App/Features/Library/LibraryScreen.swift` first.

## Goal

Once a student, researcher, or technical reader has imported 20–50 textbooks, papers, and reference manuals across several courses or projects, a single flat Library grid becomes hard to scan. **Collections & Reading Status Filters** adds two complementary, zero-clutter ways to organize the Library:
1. **Reading Status:** every book has a status (`Reading`, `To Read`, `Finished`), derived automatically from reading activity by default and overridable with one tap.
2. **Collections (Shelves):** user-named groups (e.g., *"Linear Algebra"*, *"Fall Semester"*, *"Reference"*); a book can belong to any number of collections, and deleting a collection never deletes its books.

---

## Principles & Invariants

1. **Zero clutter when unused.**
   - A new Library with no collections and fewer than 4 books needs no sidebar; the filter bar stays compact and unobtrusive.
2. **Automatic status by default, manual override when wanted.**
   - If the reader never touches Reading Status (`book.readingStatus == nil`), the app derives it automatically:
     - Never opened (`lastOpenedAt == nil` and `lastReadPageIndex == 0`): **To Read** (`.toRead`).
     - Opened and on the last page (`lastReadPageIndex + 1 >= pageCount`): **Finished** (`.finished`).
     - Otherwise: **Reading** (`.reading`).
   - The reader can explicitly set a book to **To Read**, **Reading**, or **Finished** (for example, marking a textbook **Finished** even when the index takes up the last 40 pages, or keeping a reference manual in **Reading**) from the book's context menu.
3. **Many-to-many Collections without foreign-key fragility.**
   - A book can belong to multiple collections (e.g., both *"Math 204"* and *"Midterm Review"*).
   - Deleting a collection removes only the collection record; every book in it stays in the Library untouched.
   - Deleting a book removes its collection memberships.
4. **Full forward and backward compatibility ("Keeping data openable across versions").**
   - Added in `TactileTextsSchemaV4` as optional fields/models:
     - `BookModel` adds `readingStatusRaw: String?` (`nil` = automatic).
     - `BookCollectionModel` is a new entity (`id: UUID`, `name: String`, `bookIDsData: Data`, `createdAt: Date`, `modifiedAt: Date`).
   - Because `TactileTextsSchemaV4` only adds an optional column on `BookModel` and a new model `BookCollectionModel`, Core Data's inferred migration converts `V4 ↔ V3` cleanly without stranding older builds.

---

## Behaviour Specification

### 1. Library Filter Bar & Sidebar

- **Filter pills above the Library grid (under the toolbar / Continue Reading card):**
  - Built-in status filters: **All**, **Reading**, **To Read**, **Finished**.
  - Followed by user collections in alphabetical (or custom) order: e.g., **Linear Algebra (4)**, **Systems (7)**, plus a **New Collection…** (`+`) button or **Manage Collections…** menu item.
  - On wide windows with many collections, or via the filter bar, selecting a pill filters both the Library cover grid and Library Search results to that scope (with a clear `"Searching in <Collection> — Search All Books"` banner when searching inside a filter).
- **Continue Reading card:**
  - Shows only when the filter is **All** or **Reading** (or shows the most recently opened book within the selected collection when a collection is active).

### 2. Managing Collections & Status

- **Book context menu (and multi-select or drag-and-drop):**
  - **Reading Status ▸** submenu: `To Read`, `Reading`, `Finished` (with a checkmark on the current effective status, and `Automatic` if overridden).
  - **Collections ▸** submenu: lists every collection with a checkmark for each collection the book belongs to (tapping toggles membership immediately), plus **New Collection with This Book…**.
  - Dragging a book cover onto a Collection pill adds the book to that collection.
- **Collection actions (long-press / context menu on a Collection pill):**
  - **Rename Collection…**
  - **Delete Collection…** (confirms: *"Delete “<Name>”? The N books in this collection will stay in your Library."*)

---

## Data, Backup, Merge & Sync Compatibility

- **Value types (`ReaderCore`):**
  - `ReadingStatus`: `enum ReadingStatus: String, CaseIterable, Hashable, Codable, Sendable { case toRead, reading, finished }` with lenient decoding (`init(storedValue:)` returning `nil` for unknown future cases).
  - `Book.readingStatus: ReadingStatus?` (`nil` means automatic; `Book.effectiveReadingStatus` computes the fallback from `lastOpenedAt`, `lastReadPageIndex`, and `pageCount`).
  - `BookCollection`: `struct BookCollection: Identifiable, Hashable, Codable, Sendable { public var id: UUID; public var name: String; public var bookIDs: Set<UUID>; public var createdAt: Date; public var modifiedAt: Date }`.
- **Backups (`ReaderBackup`):**
  - `Manifest` or a top-level `collections.json` entry inside the `.ttbackup` archive stores `[BookCollection]`. Older app versions ignore `collections.json` (`NewerAppBackupTests`).
  - When restoring a subset of books or merging a backup: collections whose books are in the library are merged by `id` or case-insensitive `name`, taking the union of `bookIDs`.
- **Cloud Sync (`ReaderSync`):**
  - Syncs `Book.readingStatus` on the book record, and syncs `BookCollection` records (`bookIDs` merged by set diff against the sync base so adding a book on iPad A and another on iPad B keeps both).

---

## Packages & Implementation Plan

| Package | What it is | Where |
| --- | --- | --- |
| CS1 | `ReadingStatus`, `Book.effectiveReadingStatus`, and `BookCollection` in `ReaderCore`; `TactileTextsSchemaV4` (`BookModel.readingStatusRaw`, `BookCollectionModel`) in `ReaderStore`; backup & sync merge support in `ReaderBackup` and `ReaderSync` | `Packages/ReaderCore`, `Packages/ReaderStore`, `Packages/ReaderBackup`, `Packages/ReaderSync` |
| CS2 | Library UI: filter bar pills (`All`, `Reading`, `To Read`, `Finished`, user collections), Book context menu (`Reading Status`, `Collections`), New/Rename/Delete Collection sheets/alerts, drag-and-drop onto collection pills, and Library search scoping | `App/Features/Library/`, `UITests/LibraryUITests.swift` |

### Done when

- `swift test` covers `Book.effectiveReadingStatus` transitions, `BookCollection` CRUD, V3↔V4 schema conversion, backup round-trip (including older backups without collections and newer backups opened in older code), and 3-way sync merge of collection memberships.
- UI test creates a collection `"Linear Algebra"`, adds a book to it from the cover context menu, filters the Library by `"Linear Algebra"` and by `"Finished"`, and deletes the collection while verifying the book remains in `"All"`.
