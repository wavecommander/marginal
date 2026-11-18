# 01 · Logical Page Number Offset (Book Page vs. PDF Page)

Draft, 18 November 2026. Read `docs/DESIGN.md` and `docs/LOCALIZATION_PLAN.md` first.

## Goal

In almost every textbook or academic monograph, the first 10–30 pages of the PDF are cover and Roman-numeral front matter (`i–xxiv`), so "page 312" printed on the page (and cited in a syllabus, index, or lecture) is PDF page 336. Let the reader see and jump by the book's own **logical page number** while keeping the 1-based **PDF page index** visible where ambiguity could arise, and never changing the 0-based `pageIndex` stored in the database.

---

## Principles & Invariants

1. **Storage is untouched (`0..<pageCount`).** Every record (`Note`, `Highlight`, `Bookmark`, `UserHeading`, `Book.lastReadPageIndex`, `ReadingAnchor`, ink file names `ink/<page>.drawing`, and recognised text `text/<page>.json`) continues to store the 0-based PDF page index. Changing a book's page offset is an instant metadata update that never rewrites notes, ink, or highlights.
2. **The PDF file is never modified.**
3. **One number per page when there is no offset; logical + physical when an offset is active.** When `pageNumberOffset == nil` (or `0`), every label looks byte-for-byte identical to today (`Page 312`, `p. 312`, `pp. 301–340`).

---

## Behaviour Specification

### 1. Model: How the Offset Works

- `Book` gains an optional `pageNumberOffset: Int?` (`nil` by default).
- Semantics: `pageNumberOffset` is the **0-based `pageIndex` where Book Page 1 starts**.
  - Example: if Book Page 1 is on the 15th page of the PDF (`pageIndex == 14`), `pageNumberOffset = 14`.
  - For any `pageIndex >= offset`: logical book page is `pageIndex - offset + 1` (Arabic numerals: `1, 2, 3…`).
  - For any `pageIndex < offset` (front matter before Page 1): logical label is lowercase Roman numerals starting at `i` for `pageIndex == 0`, or—if page 0 is a cover—`i, ii, iii…` (Specifically: `pageIndex + 1` formatted in lowercase Roman numerals `i, ii, iii, iv…`, which matches standard academic front-matter numbering and never collides with Arabic page numbers `1…N`).
  - Negative offsets (where a PDF starts mid-book, e.g., an extracted chapter starting at Book Page 301 on PDF page 1): if `pageNumberOffset = -300`, `pageIndex == 0` is Book Page `0 - (-300) + 1 = 301`.

### 2. Setting & Auto-Suggesting the Offset

- **Where:** Reader More menu (`…` ▸ **Page Numbering…**) and Menu bar (**Book ▸ Page Numbering…**), plus a button inside the **Go to Page** popover.
- **The sheet (`PageNumberingSheet`):**
  - Default when opened from the reader: offers **"This page (PDF page \(pdfNumber)) is book page:"** with a numeric text field defaulting to `1` (or the current logical page number if already set).
  - Live preview below the field:
    - *"PDF pages 1–14 will show as i–xiv. PDF page 15 will show as p. 1 (PDF 15 of 842)."*
  - **Auto-detect from PDF:** If the PDF contains a `/PageLabels` dictionary in its catalog (accessible via `CGPDFDocument` catalog `PageLabels` number tree or `PDFPage.label` when distinct from `"1", "2", ...`) and finds the first page labeled `"1"`, the sheet shows a one-tap suggestion chip: **"Use PDF's Page 1 (PDF page \(n))"**.
  - **Reset to PDF Pages** button clears `pageNumberOffset` back to `nil`.

### 3. Where Logical Page Numbers Appear

When `book.pageNumberOffset` is set (and non-zero):

| Surface | Without offset (`nil` or `0`) | With offset (e.g., `offset = 14`, at `pageIndex = 325`) |
| --- | --- | --- |
| Reader toolbar subtitle / Page pill | `Page 326 of 800` | `Page 312 (326 of 800)` |
| Short page label (`PageNumbering.label`) in Notes panel header, Notebook rows, Bookmarks, Contents | `p. 326` / `pp. 326–340` | `p. 312` / `pp. 312–326` (front matter: `p. xiv`) |
| Go to Page sheet / popover | Single field (`1–800`) | Accepts book page (`312`), Roman numeral (`xiv`), or `pdf:326` / toggle between **Book Page** and **PDF Page** |
| Notebook & Marked-Up PDF exports | `p. 326` | `p. 312` (links in PDF export still jump to the exact `pageIndex`) |

### 4. Go to Page Input Rules

- When an offset is active, **Go to Page** defaults to **Book Page** mode (with a segmented or inline switch for **PDF Page**):
  - Typing `312` jumps to the `pageIndex` whose book page is `312` (`311 + offset`).
  - Typing a valid Roman numeral (`iv`, `xii`) when `offset > 0` jumps to the corresponding front-matter page (`pageIndex = romanValue - 1`).
  - Switching to **PDF Page** accepts `1…pageCount` directly, as today.

---

## Data, Backup, Merge & Sync Compatibility

- **Database (`TactileTextsSchemaV4`):**
  - Add `var pageNumberOffset: Int?` to `BookModel`.
  - Lightweight migration from V3; older app versions opening the database via **Open in This Version** ignore `pageNumberOffset` and show 1-based PDF numbers.
- **Backup (`ReaderBackup`):**
  - `Book` encodes `pageNumberOffset` via `encodeIfPresent` and decodes via `decodeIfPresent`. Version 1 `.ttbackup` fixtures decode with `pageNumberOffset == nil`.
- **Merge & Sync (`ReaderCore/Merge`, `ReaderSync`):**
  - In backup merge: keep this iPad's `pageNumberOffset` if set, otherwise take the backup's (`local.pageNumberOffset ?? remote.pageNumberOffset`).
  - In Cloud Sync (`LibrarySyncCore`): `pageNumberOffset` is part of the synced book metadata record; last-writer or remote-if-changed wins alongside `title`.

---

## Packages & Implementation Plan

| Package | What it is | Where |
| --- | --- | --- |
| P1 | `PageNumbering` & `Book.pageNumberOffset` in `ReaderCore` and `ReaderStore`. Roman numeral formatting/parsing (`1...3999`), offset-aware `PageNumbering.label(forPageIndex:offset:)` and `PageNumbering.label(forPageRange:offset:)`, `GoToPageParser`, `BookModel` schema column, backup & merge round-trip tests | `Packages/ReaderCore`, `Packages/ReaderStore`, `Packages/ReaderBackup` |
| P2 | PDF `/PageLabels` detector (`PDFPageLabelInspector` reading `CGPDFDocument.catalog` `/PageLabels` off the main thread on demand when opening `PageNumberingSheet`) + `PageNumberingSheet` UI + wiring into Reader toolbar, Page pill, Go to Page, Notes panel, Contents, Bookmarks, Notebook, and Exports | `App/Features/Reader/`, `App/Features/Sidebar/`, `App/Features/Notes/`, `App/Features/Notebook/` |

### Done when

- `swift test` in `ReaderCore`, `ReaderStore`, and `ReaderBackup` covers offset math (positive front-matter offset, negative chapter-extract offset, Roman numerals `i`–`l`, `GoToPageParser`, V3→V4→V3 migration, and `.ttbackup` round-trip).
- UI test sets PDF page 5 as Book Page 1 on a fixture book, verifies the toolbar shows `Page 1 (5 of N)` and page 2 shows `p. ii`, jumps to Book Page 10 via Go to Page, and resets to PDF pages.
