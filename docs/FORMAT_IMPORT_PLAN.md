# Tactile Texts: importing other formats by converting to PDF

Draft, 15 November 2026. Read `docs/DESIGN.md` (Principles, Concepts, "Not in version 1") first.
The plan follows the owner's standing rules: Opus for every package, targeted tests only with the
full gate suspended, iOS 27 simulators only, at most three build/simulator agents at a time.

Package F0 (the feasibility spike) ran on 15 November 2026; see "F0 findings" at the end. The
approach holds. Two parts of the first draft did not survive and are rewritten below: how
table-of-contents targets are located, and how the outline is written. Nothing else is built.

## Goal

Let the reader import books and documents that are not PDFs and use them with every feature a PDF
has: Contents, page and section notes, Pencil ink, highlights, bookmarks, search, thumbnails,
section history, the Notebook and exports.

The app does this by converting the file to a PDF **once, at import**. Everything after the import
sees an ordinary PDF, so the reader, the store and the data model do not change.

**Owner requirement:** the reader is told what conversion costs them when they go to import, and
before any conversion starts. They can back out at that point with nothing changed.

## Where the app stands today

- Every stored thing is anchored to a fixed page: notes, bookmarks and user headings by
  `pageIndex`, ink in the page's crop-box space, highlights as page-space rects
  (`Packages/ReaderCore/Sources/ReaderCore/Model/Records.swift`).
- PDFKit is used directly in 19 app files. The reader, search, thumbnails and the cover each open
  the book's file with `PDFDocument(url:)` or `CGPDFDocument`.
- Import is one path for every source (Files picker, drop, "Open in", `-importFixture`):
  `ImportService.importFiles` → `ImportPipeline.probe` (size, `%PDF-` header, fingerprint) →
  `stage` (copy, open, cover) → `commit` (rename `Imports/<id>` to `Books/<id>`, save the `Book`).
- PDF-only assumptions sit in a small number of places:
  - `ImportPipeline.hasPDFHeader`, and `adoptDroppedFile` adding `.pdf` to a nameless drop.
  - `LibraryScreen`: `fileImporter(allowedContentTypes: [.pdf])`, `onDrop(of: [.pdf])`,
    the "Import PDF" button and empty-state text.
  - `project.yml`: `CFBundleDocumentTypes` lists only `com.adobe.pdf`.
  - `ImportError.notAPDF` and its message; `IncomingPDFHandler`.
- `ImportJob.Phase` is `waiting, checking, copying, finishing`. There is no step where an import
  waits for the reader.
- The SwiftData schema is `MarginalSchemaV1` with no migration stages.
- The project has no third-party dependencies, and `DESIGN.md` lists EPUB under "Not in version 1".

## Formats

| Format | Extensions | Converter | Phase |
| --- | --- | --- | --- |
| Comic and image archives | `.cbz`, `.zip` of images | Images | A |
| Images | `.jpg`, `.png`, `.heic`, `.tiff` (multi-page) | Images | A |
| EPUB 2 and 3, reflowable, no DRM | `.epub` | Web | B |
| Plain text, Markdown, HTML, web archive | `.txt`, `.md`, `.html`, `.webarchive` | Web | C |
| Word, RTF, Pages | `.docx`, `.doc`, `.rtf`, `.pages` | Web | C |
| Presentations | `.pptx`, `.ppt`, `.key` | Web, one slide per page | C |

Not supported, and the app says so by name when one is chosen:

- **DRM-protected books** (Kindle, Apple Books, Adobe DRM EPUB). They cannot be read by anyone but
  the seller's app.
- **MOBI and AZW3.** No system support; a parser would have to be written from scratch.
- **DjVu.** The usual decoder is GPL, which the App Store does not allow.
- **CBR.** RAR is a proprietary format.
- **Fixed-layout EPUB** and spreadsheets. Possible later; out of this plan.

## Decision: tell the reader before converting

### When the sheet appears

Any import that includes a file needing conversion shows one **Convert to PDF** sheet, in the
window that asked, after the files are chosen and before anything is converted. This holds for
every source: the Files picker, a drop, and "Open in" from another app.

- PDFs in the same batch import straight away, as today. They never wait for the sheet.
- One sheet covers every non-PDF file in the batch, grouped by format.
- Before the sheet, the app does only the cheap check: size, format detection, fingerprint, and the
  DRM check. A file that is already in the Library opens that book and is left out of the sheet.
- **Cancel** discards the request. Nothing is copied into the Library and no book is created.
  Files the app had to adopt (a drop, the "Open in" inbox) are deleted.
- **Convert** starts the conversions. Each file then shows progress in the Library like any import
  and can still be cancelled.
- The sheet is shown every time. It has no "don't show again" switch (owner decision,
  15 November 2026).
- Files that cannot be imported are listed in the same sheet with the reason, so the reader gets
  one answer for the whole batch, not a sheet followed by alerts.

### What the sheet says

The heading and the first block are the same for every format:

> **Convert to PDF?**
> Tactile Texts reads PDFs. These files will be converted to PDF copies so you can write on them,
> highlight them and attach notes to their pages.
>
> - The pages are fixed once converted. You can zoom, but you can't change the text size or layout
>   afterwards.
> - Converting again makes a new book. Notes, ink and highlights don't move across.
> - Your original file is not changed. A copy is kept with the book, so the book uses more storage.

Then one block per format present in the batch:

| Format | Limitations shown |
| --- | --- |
| EPUB | Page numbers won't match the print edition or other reading apps. Contents come from the book's own table of contents. Some links inside the book may not work. Audio, video and interactive parts are left out. |
| Comics and images | Pages are pictures: there is no text to select, search or highlight. Ink, notes and bookmarks work as usual. |
| Word, RTF, Pages | The layout may differ from the original app: fonts, page breaks and spacing can change. Comments and tracked changes are not shown. |
| Text, Markdown, HTML | The app chooses the typeface and page size. Images that are not inside the file are not downloaded. |
| Presentations | Each slide becomes one page. Animations, transitions, audio and video are left out. Speaker notes are not included. Fonts and spacing can differ from the original app. |

For EPUB and the text formats the sheet has one setting, **Text size** (Small, Medium, Large), with
a line under it: "Choose now. It can't be changed after converting." The page size is fixed at a
6 × 9 inch trade page (owner decision, 15 November 2026). Presentations and Office documents keep
their own page or slide size and have no setting.

The copy above is the draft English. It goes through the rules in `docs/LOCALIZATION_PLAN.md`
(whole sentences, translator comments, no concatenation).

### After the import

- A converted book is labelled in the Library's context menu and the reader's More menu:
  "Converted from EPUB".
- The Library's empty state and the import button stop saying "PDF": "Import" and "Import a book or
  document to start reading and taking notes."
- Settings gains a "Supported formats" row that shows the same limitations at any time.

## Decision: the converted PDF is the book

- `Book.fileName` keeps pointing at a PDF in `Books/<id>/`. The reader, search, thumbnails, the
  cover and exports are untouched.
- The original file is kept beside it, unmodified, as `Books/<id>/original.<ext>` (owner decision,
  15 November 2026). It is there so a later version can re-convert or export it; nothing reads it
  in this plan. Deleting the book deletes it, and the book's storage figure includes it.
- `Book.fingerprint` is the **original** file's fingerprint, so importing the same EPUB twice finds
  the existing book before any conversion.
- `Book` gains three optional fields (`nil` for a native PDF): `sourceFormat`, `originalFileName`,
  `converterVersion`. This is `MarginalSchemaV2` with a lightweight migration stage.
- Principle 1 ("The PDF is never modified") still holds: the generated PDF is written once during
  import and never touched after the commit, and the original is never touched at all.
  `DESIGN.md` is updated to say so and to move EPUB out of "Not in version 1".
- `restoreMissingDocument` (re-import repairs a book whose PDF went missing) re-runs the conversion
  with the stored text size. Pages could differ if the OS's WebKit has changed; see Risks.

## How conversion works

### Shape

```
choose files ─► preflight (probe, detect format, DRM check, fingerprint)
                 ├─ PDF ───────────────────────────────► stage ─► commit      (unchanged)
                 ├─ already in Library ────────────────► open that book
                 ├─ unsupported / protected ───────────► listed in the sheet
                 └─ convertible ─► Convert to PDF sheet ─► copy original ─► convert ─► stage checks ─► commit
```

- `ImportFormat` (ReaderCore): detection from magic bytes first, extension second. A ZIP whose
  `mimetype` entry is `application/epub+zip` is an EPUB; a ZIP of images is a comic archive.
- `DocumentConverter` (app): one protocol, one implementation per converter family.
  Input: the original's URL, a staging directory, options, a progress callback.
  Output: a PDF in the staging directory, plus a title and cover image when the format has them.
  The outline is written into the PDF by the converter, so it is not passed back separately.
- `ImportJob.Phase` gains `converting`, with a fraction (chapters or images done over total).
- The existing stage checks (opens, has pages, not locked, cover) run on the generated PDF.
- `ImportError` gains `unsupportedFormat`, `protected` and `conversionFailed`; `notAPDF` is reworded.

### ZIP reader (ReaderCore)

iOS has no public unzip API, and EPUB, CBZ and DOCX are ZIP files. A small reader over the
Compression framework keeps the no-dependencies rule: stored and deflate entries, ZIP64, one entry
streamed at a time. It rejects path traversal and caps total uncompressed size and entry count
(zip bombs). It is plain Foundation, so its tests run on the host with `swift test`.

### Images converter (phase A)

- Pages in natural sort order of the entry names (`page2` before `page10`).
- One image decoded at a time through ImageIO and drawn into a `CGPDFContext` page of the image's
  aspect ratio. Memory stays flat however long the comic is.
- The cover is page one. There is no outline; the reader adds headings by hand as for any PDF
  without one.
- JPEG data passes through without re-encoding (finding 7), so a converted comic is about the size
  of the original.

### Web converter (phases B and C)

An off-screen `WKWebView` lays the content out and the system print path
(`UIPrintPageRenderer` with the web view's print formatter) paginates it into PDF pages with real,
selectable text. So search, highlights and "Add as Heading" work on converted books.

- **Isolation.** Content is served to the web view through a custom URL scheme handler that reads
  straight from the archive. The book's own JavaScript is off; the app's own queries still run.
  A content rule list blocks every load except the book's scheme. The rule list is required: in
  the spike, a page with scripts off and no rule list still fetched a remote image and stylesheet
  (finding 5).
- **EPUB.** The package parser (ReaderCore) reads `container.xml`, the OPF manifest and spine, and
  the navigation document or NCX. Each spine item is rendered to its own PDF, then the parts are
  joined. Rendering by chapter bounds memory and gives a natural progress fraction and cancel point.
- **Styling.** The book's own CSS is kept. The app adds a small stylesheet for page margins, the
  chosen text size and sensible image scaling.
- **Outline.** A table-of-contents entry points at a chapter and sometimes a place inside it. The
  chapter's first page is known exactly. For a place inside a chapter (F0 finding 2: the print
  path writes no link annotations, so marker links are not an option):
  1. before printing, the app asks the web view for the target element's text and how far down the
     chapter it sits;
  2. after printing, it searches the chapter's PDF for that text and takes the match nearest the
     estimated page.
  In the spike this found the right page for all five targets, where the estimate alone was a page
  out for two. A target with no text of its own (an empty anchor) uses the estimate.
- **Internal links.** Planned the same way: list the book's links and their text before printing,
  find each link's text in the PDF, and write a jump to the target's page. Writing the jump is
  proven (finding 3); finding a link's rectangle by its text is not yet tested, and short link text
  such as "1" will be ambiguous. Links that cannot be placed are dropped, as the sheet warns.
- **Joining and where the outline is stored.** One CoreGraphics pass, off the main thread, draws
  every chapter page into the final file and writes the outline (`CGPDFContextSetOutline`) and the
  links (`setDestination(_:for:)`, `setURL(_:for:)`) as it goes. The outline is in the PDF, so
  `ReaderDocumentLoader.outlineEntries` works unchanged. PDFKit is **not** used to write the
  outline: on the iOS 27 simulator `PDFDocument.write` saved the file without it (finding 3).
  Outline entries land on the right page; the position within the page is not kept, which matches
  how the app's outline works (page-based).
- **Title and cover.** From the EPUB's metadata and cover image when present; otherwise the file
  name and page one, as today.
- **Text, Markdown, HTML.** Wrapped in the app's stylesheet and sent down the same path. Markdown
  is turned into HTML from Foundation's Markdown parser.
- **Word, RTF, Pages.** `WKWebView` can display these itself; the plan is to load the file and
  print it the same way. This works off-screen for `.docx`, `.doc` and `.rtf` (finding 6); `.pages`
  has not been run.
- **PowerPoint and Keynote.** Loaded the same way. The system renders each slide as a fixed-size
  block; the app sets the page size to the slide's size and adds a page break after each slide,
  which gave exactly one slide per page with selectable text for `.pptx` (finding 6). The first
  line of each slide's text becomes its outline entry, so Contents and section notes work per
  slide. `.ppt` and `.key` are expected to behave the same but have not been run (no test files).

## Packages

Every package: Opus, targeted tests for its own region only, iOS 27 simulator only.

### F0 · Feasibility spike

Throwaway code in the scratchpad or a branch that is not merged. It answers these on the iOS 27
simulator and appends a "Findings" section to this file:

1. Does an off-screen `WKWebView` paginate through the print formatter at a custom page size, with
   selectable text PDFKit can search?
2. Do marker links survive into the PDF as link annotations at the right place?
3. Which way of joining chapter PDFs keeps memory flat at 1,500 pages and keeps text selectable?
4. How long does the main thread stall per chapter while printing? (Principle 3: the Library must
   stay responsive during a conversion.)
5. Does a custom URL scheme handler work with printing, with JavaScript off?
6. Do `.docx`, `.doc`, `.rtf` and `.pages` load and print off-screen? Do `.pptx`, `.ppt` and
   `.key` load, can each slide be made exactly one page, and are slide titles readable?
7. Does `CGPDFContext` keep JPEG data as it is?

Done when: each question has a measured answer and the owner has agreed any change of scope.

Status: run on 15 November 2026; answers are in "F0 findings". The owner gave the go-ahead for
wave 1 the same day.

### F1 · Formats, ZIP and EPUB parsing (ReaderCore, no simulator)

- `ImportFormat` and detection; natural sort for page names.
- ZIP reader with the safety limits above.
- EPUB package parser: metadata, manifest, spine, navigation (EPUB 3 nav and EPUB 2 NCX), cover.
- DRM detection: `META-INF/encryption.xml` entries other than font obfuscation, and `rights.xml`.
- `ConversionLimitation`: which limitations apply to which format, as data. The words live in the
  app.

Done when: host tests cover detection for every format in the table, ZIP edge cases (ZIP64,
traversal, oversize), both navigation forms, and a protected EPUB being recognised.

Status: done on 15 November 2026, not committed. 56 host tests, also run on the iOS 27 simulator.
Every fixture is built in the test code; no real EPUB, comic or Office file has been through it.
Things F3 and F5 need to know:
- A file that starts as a ZIP is treated as a ZIP even if `%PDF-` appears in its first 1 KiB. The
  current `hasPDFHeader` would call it a PDF; F3 uses the detector for both.
- A comic archive is recognised by entry names only; the image bytes are not checked until F4.
- An EPUB whose package file cannot be parsed is still detected as an EPUB and fails in the
  converter with `conversionFailed`.
- Readium LCP (`META-INF/license.lcpl`) and an unreadable `encryption.xml` count as protected.
- Fixed layout is read from the package-level setting and Apple's display options only.

### F2 · Book fields, schema V2 and the converter contract

- `Book.sourceFormat`, `originalFileName`, `converterVersion`; `MarginalSchemaV2`; lightweight
  migration from V1.
- `DocumentConverter` protocol, `ConversionOptions`, `ConvertedDocument`, and a registry keyed by
  `ImportFormat`, in a new `App/Features/Import/` folder. No converter yet; a test stub only.

Done when: store tests open a V1 store and read it as V2 with the new fields `nil`, and the
existing store tests pass unchanged.

Status: done on 15 November 2026, not committed. The migration test passes on the Mac and on the
iOS 27 simulator. The kept original's path is `BookStorageLayout.originalPath`. The stub converter
is in `Tests/DocumentConverterTests.swift`; F3 moves it into the app for its UI tests.

### F3 · Import flow and the Convert to PDF sheet

- Preflight in `ImportService`: classify each file, send PDFs on, queue the rest as a
  `ConversionRequest` addressed to the window (the same pattern as `failures`).
- The sheet, with the copy above, the per-format blocks, the Text size setting and the
  "can't be imported" list. Accessibility identifiers on the sheet, both buttons and each block.
- `ImportJob.Phase.converting`; cancel during conversion removes the staging directory.
- Security-scoped access to picked files is held from the pick until Convert or Cancel.
- New `ImportError` cases and messages; "Import PDF" becomes "Import".
- `project.yml` document types, `fileImporter` and `onDrop` content types, `adoptDroppedFile`,
  `IncomingPDFHandler`.
- Launch argument `-confirmConversions` so `-importFixture` can import a non-PDF in UI tests
  without a sheet; without it a fixture import shows the sheet like any other.

Done when, using the stub converter:
- choosing an EPUB shows the sheet and no book or file exists in `Books/` until Convert;
- Cancel leaves the Library and the disk exactly as they were;
- a batch of one PDF and one EPUB imports the PDF without waiting;
- a protected EPUB is listed as not importable;
- a drop and an "Open in" show the same sheet.

### F4 · Images converter

CBZ, image ZIPs, single images and multi-page TIFF, as described above.

Done when: a 300-image fixture converts with flat memory, pages are in natural order, the page
count matches, and ink drawn on a converted page reloads in place.

### F5 · Web converter and EPUB

The off-screen renderer, the scheme handler, chapter joining, the outline and link pass, title and
cover.

Done when, for the EPUB fixture: the page text is searchable and highlightable, Contents shows the
book's table of contents and each entry lands on the right page, a section note attaches to a
converted heading, no network request is made, and cancelling mid-book leaves nothing behind.

### F6 · Text, Markdown, HTML, Office documents and presentations

The remaining Web-converter inputs, including one-slide-per-page pagination for presentations.

Done when: each fixture converts, its text is searchable, a file that fails to render reports
`conversionFailed` naming the file, and the presentation fixture has one page per slide at the
slide's aspect ratio.

### F7 · Provenance, fixtures, journey test and docs

- "Converted from …" in the Library and the reader; the "Supported formats" row in Settings.
- `Fixtures/make-fixtures.swift` and `scripts/fixtures.sh` generate `small.epub`, `protected.epub`,
  `small.cbz`, `small.docx`, `small.pptx`, `small.md`.
- One journey UI test: import an EPUB, read the sheet, convert, open, highlight, add a section
  note, see both in the Notebook.
- `DESIGN.md` (principle 1 wording, Concepts ▸ Book, "Not in version 1"), `DEVICE_CHECKLIST.md`
  (convert a real EPUB and a real comic on the device).

## Waves

| Wave | Packages (parallel within a wave) |
| --- | --- |
| 0 | F0 spike, then the owner's go-ahead |
| 1 | F1 core (host only) · F2 model and contract (one simulator) |
| 2 | F3 import flow · F4 images · F5 web and EPUB (three agents, one simulator each, each in its own worktree) |
| 3 | F6 text, Office and presentations · F7 provenance, fixtures, docs |

File ownership in wave 2: F3 owns `App/Features/Library/`, `project.yml` and the sheet; F4 and F5
each add files under `App/Features/Import/Converters/` and one line to the registry. The registry
line is the only shared edit and is merged by the orchestrator.

Phase A ships after wave 2 without F5 if EPUB slips: the sheet, the flow and comics stand alone.

## Owner decisions (15 November 2026)

1. The Convert to PDF sheet is shown every time, with no "don't show again".
2. EPUB and text use one fixed 6 × 9 inch page; the reader chooses only the text size.
3. The original file is kept with the book.
4. Word, RTF, Pages and presentations (PowerPoint, Keynote) are in. Spreadsheets are out.

## Open questions

1. **A print-sheet route.** "Print ▸ Share ▸ Tactile Texts" from any app already produces a PDF
   and would cover formats this plan leaves out. It needs a share extension; not planned here.

## Risks

- **The spike used synthetic documents on the simulator.** Printing off-screen works, but real
  EPUBs (embedded fonts, large images, tables, footnotes, right-to-left text), real slide decks
  (pictures, charts, master backgrounds) and a real iPad have not been tried. F5 and F6 each start
  by running three real files of the owner's choosing before building further.
- **Main-thread stalls.** Printing draws on the main thread at about 3 to 4 ms a page (finding 4):
  unnoticeable for a 12-page chapter (45 ms), a visible hitch for a 173-page one (560 ms). F5
  prints long chapters in batches of pages with a yield between batches; that batching is designed
  but not yet tried.
- **Conversion is not reproducible across OS versions.** A WebKit update can move a page break, so
  re-converting the same EPUB may give different pages. That is why the generated PDF is kept
  for good and why the sheet says a second conversion is a new book.
- **Waiting on the sheet.** A picked file's access can lapse if the app is suspended while the
  sheet is up. The request then fails with "could not be read" and the reader picks the file again.
- **Hostile files.** ZIP limits, no JavaScript and no network are the defences; F1 and F5 each test
  theirs.
- **Presentations beyond the simple case.** One slide per page worked for a plain three-slide
  `.pptx`. If complex decks split or clip, the fallback is drawing each rendered slide into its own
  page as a picture, which loses text selection and search for presentations; the sheet's wording
  would change to say so.
- **`.pages`, `.key` and `.ppt` are untested.** The spike had no files of these types. They stay
  in scope on the expectation that they load like their siblings; F6 checks first and drops any
  that do not, with the sheet listing them as not importable.
- **iOS 17.** The deployment target is 17.0 but testing there is suspended, so the schema migration
  and the WebKit path are exercised on iOS 27 only until the owner resumes it.
- **Localization overlap.** F3 adds strings to the Library while `LOCALIZATION_PLAN.md` L1a extracts
  them. Whichever lands second rebases; F3 follows the localization rules from the start.

## F0 findings (15 November 2026)

Run on the iPad Pro 11-inch (M5) simulator, iOS 27.0, Xcode 27.2, with a throwaway app outside the
repository. Test documents were synthetic: generated HTML chapters, Word/RTF files made with
`textutil`, and a hand-built three-slide `.pptx`. Not run: a real device, iOS 17, real-world books
or decks, and `.pages`, `.key` and `.ppt` (no test files).

| # | Question | Answer | Measured |
| --- | --- | --- | --- |
| 1 | Does an off-screen web view paginate to a custom page size with selectable text? | **Yes.** No window needed. | 200 paragraphs → 23 pages of 432 × 648 pt in 86 ms; PDFKit search and per-line selection rects work. |
| 2 | Do marker links survive printing? | **No.** The print path writes no link annotations at all, including ordinary links. | 0 annotations, attached or off-screen. Text match near a position estimate found 5 of 5 targets on the right page; the estimate alone was one page out for 2 of 5. |
| 3 | How to join chapters and add the outline? | **One CoreGraphics pass.** PDFKit's `write` dropped the outline on iOS (it kept it on macOS). | 1,540 pages joined in 2.5 s off the main thread. Footprint rose 2.5 MB with outline and links, 0 MB without; PDFKit joining rose 12.5 MB. Outline (35 entries plus a nested one), an internal jump and an external link all read back correctly; text stays selectable. |
| 4 | How long does printing block the main thread? | **About 3 to 4 ms a page.** | 12 pages 45 ms, 44 pages 145 ms, 173 pages 560 ms. Loading a chapter takes 0.4 to 1.2 s but does not block. Footprint stayed under 24 MB. |
| 5 | Does a scheme handler work with printing and scripts off? | **Yes, but a block rule is also needed.** | HTML, CSS and image served from the handler and printed; the page's script did not run; the app's own queries did. Remote requests: 2 without the rule list, 0 with it. |
| 6 | Do Office files load and print off-screen? | **Yes** for `.docx`, `.doc`, `.rtf`, `.pptx`. | Word-family files: 5 to 8 Letter pages, text searchable; first load 2.3 to 5.9 s. `.pptx`: slides are 960 × 540 blocks; page size set to match plus a break after each gave 3 pages for 3 slides, titles readable. |
| 7 | Does `CGPDFContext` keep JPEG data? | **Yes.** | A 907 KB JPEG became a 911 KB PDF page by every route tried (ImageIO, UIImage, `PDFPage(image:)`). |

Other things learned:

- Content rule lists do not accept regular-expression alternation (`(a|b)`). The working rule set
  is "block everything", then "ignore previous rules" for the book's scheme.
- `WKWebView.createPDF` does keep link annotations, but it produces one tall page, not pages, so
  it is not a substitute for the print path.
- A sub-heading's outline entry keeps its page but not its position on the page.
