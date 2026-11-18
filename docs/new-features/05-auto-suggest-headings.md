# 05 · Auto-Suggest Headings When Adding a Heading

Draft, 18 November 2026. Read `docs/DESIGN.md` ("The reader's own headings", Principle 3: "A 1,500-page, 600 MB PDF must feel like a 20-page one") and `App/Features/Sidebar/AddHeadingSheet.swift` first.

## Goal

Many academic PDFs, course packs, and scanned textbooks arrive with no embedded PDF outline (`PDFOutline`), or with only top-level chapter entries and no sub-sections (`5.1`, `5.2`, `5.3`). Readers can already build the outline by hand via **Add Heading at Page N** (`HeadingSheet`), or select text and choose **Add as Heading**. However, when opening **Add Heading at Page N** from the toolbar, sidebar, or shortcut (`⇧⌘H`), the Title field starts blank unless text was pre-selected.

**Auto-Suggest Headings** inspects **only the target page** on demand when `HeadingSheet` opens, extracts up to 3–5 likely heading candidates from that page's typography and layout (or recognised OCR text on a scanned page), and offers them as one-tap suggestion chips alongside an inferred nesting level.

---

## Principles & Invariants

1. **Single-page, on-demand inspection only (`Principle 3`).**
   - Nothing ever scans the whole book in the background to guess an outline. Inspection runs only on the single `PDFPage` selected in `HeadingSheet` (taking < 2 ms for a single page).
   - If the user edits the "Starts on page" number in `HeadingSheet`, candidates refresh for the newly typed page index.
2. **100% user-confirmed.**
   - No heading is ever created automatically. Candidates are shown in `HeadingSheet` (and optionally pre-fill the Title field only when the user opened `HeadingSheet` with no prior text selection, or appear as tappable chips directly under the Title field so the empty/Scribble field stays clean).
3. **Works on both native-text PDFs and recognised scanned pages.**
   - On a page with a PDF text layer, `PDFPage.attributedString` + line bounding boxes (`PDFSelection.selectionsByLine()`) provide font size, weight, and vertical geometry.
   - On a scanned page without a PDF text layer, it falls back to the book's `RecognisedPage` (`Books/<bookID>/text/<page>.json`) if available, using bounding-box height and numbering prefixes (`Chapter 4`, `4.2 ...`).

---

## Behaviour Specification

### 1. How Candidates Are Extracted & Scored (`PageHeadingExtractor`)

Given a single page's lines (each with `text: String`, `bounds: CGRect` in page space, and optional `fontSize: CGFloat`, `isBold: Bool`):

1. **Filter out noise:**
   - Ignore running headers and footers: single lines within the top 6% or bottom 6% of the page that contain only page numbers, book title repeats, or < 2 letters.
   - Ignore body paragraphs: lines longer than 110 characters, or multi-sentence blocks ending in a period (unless matching a numbered heading pattern like `5.2. The Characteristic Equation`).
   - Ignore equations/captions (`Figure 3.1:`, `Table 2:`).
2. **Score remaining candidates:**
   - **Typography score:** font size relative to the page's median body font size (e.g., `>= 1.15x` body size), bold/semibold traits, or all-caps chapter headers (`CHAPTER 5`).
   - **Structural prefix score:** matches academic numbering patterns:
     - Top-level: `Chapter N`, `Part I`, `Appendix A`, or standalone `N Title` near the top of a page.
     - Sub-section: `N.M Title` (depth 2), `N.M.K Title` (depth 3), `§N.M`.
   - **Vertical isolation & position:** extra whitespace above the line, and higher placement on the page (`bounds.maxY` in PDF page space).
   - **Multi-line heading merge:** two consecutive lines at the top of the page with identical large font size (e.g., line 1: `Chapter 5`, line 2: `Eigenvalues and Eigenvectors`) are combined into `"5 Eigenvalues and Eigenvectors"` or `"Chapter 5: Eigenvalues and Eigenvectors"`.
3. **Return top 4 distinct candidates**, ordered by score/reading order.

### 2. Inferring the Suggested Placement (`HeadingParentChoice`)

When the reader taps a candidate chip (e.g., `"5.2.1 Diagonalization"`):
- `HeadingNumberPrefixParser` checks the candidate's numeric prefix depth (`5` → level 1 / top-level; `5.2` → level 2 under `"5 ..."`; `5.2.1` → level 3 under `"5.2 ..."`).
- If `session.outline`'s `headingPath(forPage: pageIndex)` contains a parent at the matching depth (for example, `"5.2 The Characteristic Equation"` is at level 2), `HeadingSheet` automatically selects that parent in the **Place** picker!
- The reader can still tap any other parent in the **Place** picker before tapping **Add**.

### 3. UI in `HeadingSheet` (`App/Features/Sidebar/AddHeadingSheet.swift`)

- When `HeadingSheet` opens in `.add(pageIndex, suggested)` mode:
  - If `suggested` is non-empty (the user came from **Add as Heading** on a text selection), the Title field starts pre-filled with `suggested`, as today.
  - Below the Title `TextField`, if `candidates` is non-empty, a compact **"On This Page"** row lists up to 4 candidate chips (showing the candidate text and a subtle icon).
  - Tapping a chip sets `title = candidate.title` and updates `parent` if the candidate's numbering implies a specific parent in `choices`.

---

## Packages & Implementation Plan

| Package | What it is | Where |
| --- | --- | --- |
| AH1 | `PageHeadingExtractor` & `HeadingNumberPrefixParser` in `ReaderCore`: pure-Swift candidate scoring, running-header filtering, multi-line display-title merging, and prefix-to-level inference (`"5.2.1"` → depth 3) over value-type `[PageTextLine]` inputs | `Packages/ReaderCore/Sources/ReaderCore/Outline/PageHeadingExtractor.swift` |
| AH2 | PDFKit & Recognised-Text bridge + `HeadingSheet` UI: extracts `[PageTextLine]` for `pageIndex` from `PDFDocument` (or `RecognisedTextStore`) and renders the **"On This Page"** suggestion chips in `HeadingSheet` with accessibility identifiers | `App/Features/Sidebar/AddHeadingSheet.swift`, `App/Features/Reader/` |

### Done when

- `swift test` in `ReaderCore` tests `PageHeadingExtractor` against synthetic textbook pages: merges two-line chapter headings, ignores running headers/footers and figure captions, ranks `5.2 The Characteristic Equation` above body lines, and infers parent level from `5.2` and `5.2.1`.
- UI test opens **Add Heading at This Page** on a fixture page with a bold heading and no pre-selected text, taps the suggested chip, verifies the title and parent picker update, and saves the heading.
