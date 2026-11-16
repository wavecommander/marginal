# Tactile Texts: scanned books plan

Moved here on 16 November 2026 from the retired initial build plan, taking the
corrected version from the scanned-books branch. Design: "Scanned books" in `docs/DESIGN.md`.
Built on branch `claude/ocr-scanned-pdfs-b25608` under the owner's standing rules in `AGENTS.md`
(Opus for every package, targeted tests only, at most three build or simulator agents at once,
iOS 27 simulators).

**Status, 16 November 2026:** S0, S1, S2 and S4 are done on the scanned-books branch, which is
not yet merged into `build-v1`. S3 is still to do. `docs/SCANNED_BOOKS_FINDINGS.md` arrives with
that branch.

S0 runs first and alone; S1 follows; S2 and S4 can then run in parallel, and S3 follows S2. S0's
answers are in `docs/SCANNED_BOOKS_FINDINGS.md`, which every later package reads first, and the
rows below were corrected from it on 16 November 2026.

| Package | What it is | Where |
| --- | --- | --- |
| S0 | Findings and fixture. No feature code. Adds `scanned.pdf` to the fixture generator (30 pages, each one image of printed text with no text layer, a known phrase on a known page, plus one typed page) and answers, on the installed SDK, in `docs/SCANNED_BOOKS_FINDINGS.md`: does a Live Text selection in `PDFView` reach the reader's selection menu as a `ReaderTextSelection` with per-line rects and a string; do Copy, Look Up, Add as Heading and paragraph Select All work on it; does `PDFPage.string` stay empty on a scanned page; does Live Text run in the simulator; which Vision request to use at the iPadOS 17 floor and whether a newer one is worth an availability-gated path; does Vision run in the simulator; seconds per page and peak memory at the chosen render size. If a Live Text selection cannot be read by the app, stop and report: S4 does not go ahead as designed | `Fixtures/`, `docs/` |
| S1 | Core and store. In `ReaderCore`: the scan-detection rule as a pure function over page samples (text length, image coverage), the recognition state (not decided, declined, in progress, paused, complete), the recognised-page value (text, word boxes), the store protocol, and the highlight's text source with `Notebook` and `MarkdownExporter` treating a Live Text highlight as a crop with an optional caption. In `ReaderStore`: the file-backed recognised-text store and the state sidecar, removed with the book. The highlight's source is an optional field: a new schema version (V3) with a lightweight migration stage, since the existing highlight model is frozen, and optional in `Codable`; an existing library and the checked-in version 1 backup still load, and backup and merge carry the field | `Packages/ReaderCore`, `Packages/ReaderStore` |
| S2 | Recognition and search. One app-wide queue: render, recognise, convert boxes to page space, save, announce progress through the change hub; near-the-reader-first ordering; resume after relaunch; pause in Low Power Mode and under serious thermal state; cancel on book delete. The search worker reads each page through a page-text source and falls back to recognised text when the page has none, building hit rects from word boxes; a running search picks up pages recognised after it started (the engine scans forward once today, so this is new plumbing). Whether a page has text is read from the file, never the on-screen document. The reader's search mark gains a path drawn from the hit's rects alone, because re-finding text on a scanned page fails. `BackupScheduler.noteChange` skips hub events whose `StoreChange.affectsBackup` is false, so recognition progress never makes an automatic backup due | `App/Features/TextRecognition/`, `App/Features/Search/`, the search mark in `App/Features/Reader/` |
| S3 | The notice and the search status. Detection at the end of import and the one notice per import, after the Convert to PDF sheet, with the estimate; no notice for books converted from pictures. An import with no window attached (`-importFixture`) leaves the notice for the first window to show, as conversion requests are. The status view at the top of the search panel for every state, the same in every window on the book. Strings go through the app's localisation as the rest do | `App/Features/TextRecognition/`, a hook in `App/Features/Library/` and a slot in `App/Features/Search/` |
| S4 | Scanned-page highlights. Capture, drawing, recolour, delete and Copy already work through the existing code (S0), so this is: setting the source when a highlight is made, decided from the file's own page; the crop renderer (off the main thread, cached); crops in "Highlights on this page", the Notebook, the Markdown ZIP (`highlights/`) and the Notebook PDF; backup, merge and restore round trip. Also the backup side of recognised text, found missing by S1: `text/` and `recognition.json` (the `BookStorageLayout` constants) are left out of every backup, and a merge or replace on this iPad keeps the book's recognised text and state (`App/Features/Backup/`, `Packages/ReaderBackup`). Adds the real-device checks to `docs/DEVICE_CHECKLIST.md` under "Scanned books" | `App/Features/Highlights/`, `App/Features/Notebook/`, `App/Features/Notes/` |

Done when:

- **S1**: `swift test` covers detection (a book with a few blank or picture-only pages is not
  scanned; a scan with a typed cover is), the state's transitions, and the store's write, read,
  list and removal; the version 1 backup test still passes.
- **S2**: unit tests recognise `scanned.pdf` and find the known phrase with rects on the right
  page; a relaunch mid-way continues the count instead of restarting; the scroll measurement
  on `scanned.pdf` with recognition running stays within the bound it has without it.
- **S3**: UI tests import `scanned.pdf` and see the notice; choose Not Now, open search, see
  the offer, accept it and find the phrase with its hit marked; import `small.pdf` and see no
  notice; a second window on the book shows the same progress.
- **S4**: a seeded Live Text highlight on `scanned.pdf` is drawn in place after a relaunch,
  recolours, deletes, shows a non-empty crop in the Notebook and appears in all three exports.
  A UI test also makes one from a real selection, waiting for PDFKit to read the page first
  (up to 15 seconds on a cold start).

App tests are the `TextRecognition*` and `ScannedHighlight*` classes in `Tests/` and
`UITests/ScannedBooksUITests`.
