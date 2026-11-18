# Tactile Texts: Post-MVP Feature Plans & Specifications

Draft, 18 November 2026. Read `docs/DESIGN.md` (Principles, Concepts, "Keeping data openable across versions"), `docs/LOCALIZATION_PLAN.md`, and `AGENTS.md` first.

Every plan in this directory follows the owner's standing rules:
- Every agent runs on Opus.
- Test only the region changed (`scripts/build.sh`, `scripts/test.sh --packages-only`, or `scripts/test.sh --skip-packages -only-testing:...`); the full gate is suspended.
- At most three agents build or use simulators at once, one booted simulator each, on the iOS 27 simulator while keeping the iPadOS 17.0 deployment target and compiler-checked fallbacks.
- Every view reads and commands its own window's `ReaderSession` and reflects changes from other windows via `StoreChangeHub`.
- All localization rules from `docs/LOCALIZATION_PLAN.md` apply from day one: whole sentences in `Localizable.xcstrings`, translator comments, `BidiIsolated` around user titles/labels, `.formatted(.number.grouping(.never))` for page numbers, and `.leading`/`.trailing` layout.

---

## Feature Specifications

| # | Spec | Summary | Touches Schema / Backup / Sync? |
| --- | --- | --- | --- |
| 01 | [01-logical-page-number-offset.md](file:///Users/benw/dev/marginal/docs/new-features/01-logical-page-number-offset.md) | Per-book logical page numbering (`pageNumberOffset`, Roman front matter, PDF `/PageLabels` detection) while keeping `0..<pageCount` storage indices unchanged. | Yes (`Book.pageNumberOffset: Int?`) |
| 02 | [02-footnote-figure-peek.md](file:///Users/benw/dev/marginal/docs/new-features/02-footnote-figure-peek.md) | Long-press internal PDF links (and `p. N` references in notes) to preview the destination page in a popover before jumping or opening in a new window. | No (view & controller only) |
| 03 | [03-subtle-paper-guides.md](file:///Users/benw/dev/marginal/docs/new-features/03-subtle-paper-guides.md) | Optional faint Ruled, Grid, or Dot background guides on the note page, aligned to the 22 pt `NotePageStyle.lineHeight` in Light and Dark Mode. | Optional (`NotePaperGuideStyle` preference; per-note override optional) |
| 04 | [04-note-inline-formatting-and-lists.md](file:///Users/benw/dev/marginal/docs/new-features/04-note-inline-formatting-and-lists.md) | Bold, italic, inline code, subheadings, and auto-continuing lists in notes while preserving the strict 22 pt line-height invariant so paragraph-band ink never drifts. | No schema change (stored as inline Markdown or optional `textRunsData`) |
| 05 | [05-auto-suggest-headings.md](file:///Users/benw/dev/marginal/docs/new-features/05-auto-suggest-headings.md) | On-demand candidate heading titles and suggested nesting level extracted from the current page's layout when opening `HeadingSheet`. | No (pure `ReaderCore` + `HeadingSheet` UI) |
| 06 | [06-named-bookmarks.md](file:///Users/benw/dev/marginal/docs/new-features/06-named-bookmarks.md) | Optional reader-assigned labels on bookmarks (`Bookmark.title: String?`), editable from the reader toolbar, `BookmarksListView`, and `PagesGridView`, and searchable in the Notebook/Library. | Yes (`Bookmark.title: String?`) |
| 07 | [07-library-collections-and-status.md](file:///Users/benw/dev/marginal/docs/new-features/07-library-collections-and-status.md) | User collections/shelves (`Collection` model + membership) and reading-status filters (`All`, `Want to Read`, `Reading`, `Finished`) in the Library. | Yes (`Book.readingStatus`, `BookCollectionModel`) |
| 08 | [08-single-section-and-note-share.md](file:///Users/benw/dev/marginal/docs/new-features/08-single-section-and-note-share.md) | Direct `Share Note…` in the Notes panel header and `Export Section Notes…` in the Contents sidebar and Section note tab, reusing `MarkdownExporter` and `NotebookPDFWriter`. | No (scoping + UI wiring) |

---

## Coordinating Data & Schema Changes ("Keeping data openable across versions")

Four of the eight features (01, 03 if per-note, 06, and 07) add persistent fields or models. Rather than burning four separate `VersionedSchema` steps, any subset shipped in the same release should be combined into **one additive schema version** (`TactileTextsSchemaV4` in `Packages/ReaderStore/Sources/ReaderStore/Schema.swift`):

1. **Additive-only SwiftData schema (`TactileTextsSchemaV4`):**
   - `BookModel`: adds `pageNumberOffset: Int?` (01) and `readingStatusRaw: String?` (07), plus `collectionIDsData: Data?` (or a join/entity `BookCollectionModel` with `id`, `name`, `createdAt`, `sortOrder`) (07).
   - `BookmarkModel`: adds `title: String?` (06).
   - Lightweight migration stage `.lightweight(fromVersion: TactileTextsSchemaV3.self, toVersion: TactileTextsSchemaV4.self)`.
   - Because every change only adds optional columns or new models, Core Data's inferred downgrade in `LibraryDatabase.openInThisVersion` continues to convert `V4 → V3 → V2 → V1`, keeping `LibraryDatabaseTests.everyVersionConvertsDownToTheOneBefore` green.
2. **Backups (`ReaderBackup`) and Sync (`ReaderSync`):**
   - All new fields on `Book`, `Bookmark`, and `Collection` are optional `Codable` keys at the existing backup format version (`encodeIfPresent` / `decodeIfPresent`).
   - Unknown enum cases (`ReadingStatus(storedValue:)`) fall back to `nil` (automatic status derived from `lastOpenedAt` and `progress`), matching `HighlightColor(storedValue:)`.
   - Extend `NewerAppBackupTests` and `NewerVersionRowTests` in the same commit that introduces the fields.
   - Update `ReaderCore/Merge` and `LibrarySyncCore` so backup merges and cloud sync carry `pageNumberOffset`, `readingStatus`, `Bookmark.title`, and collections deterministically.
