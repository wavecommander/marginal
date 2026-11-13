# Marginal (working title): design

A native iPadOS app for reading large textbook PDFs, marking them up, and keeping notes attached
to pages and to headings.

Mockups: https://claude.ai/artifact/DGC3WWVFeVmNY7pSaKknpP (seven screens; names below match the
artboard titles). The mockups are drawn in HTML, so treat them as layout and behaviour intent.
System controls (segmented controls, sheets, the PencilKit tool picker) should be the real system
ones even where the mockup draws an approximation.

## Principles

1. **The PDF is never modified.** Ink, highlights, notes and bookmarks live in the app's own store
   beside the imported file. Exporting an annotated copy is an explicit action.
2. **Notes have two anchors: a page or a heading.** Both are first-class and one tap apart.
3. **A 1,500-page, 600 MB PDF must feel like a 20-page one.** Nothing walks every page on the main
   thread, and nothing loads the whole file into memory.
4. **Pencil draws, finger scrolls.** Markup never blocks reading.
5. **A note is a page of its own.** Anything the Pencil can do to a PDF page it can do to a note:
   write over the typed text, circle, underline, highlight, sketch in the blank space.

## Screens

| Artboard | What it shows |
| --- | --- |
| Library | Imported books in a grid with progress, search, sort, Import PDF, and a "Continue reading" card with shortcuts to Resume and to the Notebook. |
| Reader · page note | The main reading layout: Contents sidebar (PDF outline with note badges), the page, and the Notes inspector on "Page note". |
| Markup with Apple Pencil | Markup mode: ink over the page, a tool palette, undo/redo, Done. |
| Markup · page and note together | Markup mode with the notes panel widened to half the screen: the same tool palette inks the PDF page on the left and the note on the right. The note is zoomed to 140% for writing; ink sits over the typed text and in the blank space below it. |
| Reader · section note | Notes inspector on "Section note": a level picker over the heading path, the heading's note, and the page notes that fall inside that heading. |
| Notebook · all notes by heading | Every note and highlight for one book, laid out along the outline, filterable, exportable. |
| Portrait · notes sheet | Narrow widths: the inspector becomes a resizable bottom sheet and the page stays scrollable behind it. |

## Concepts

- **Book**: one imported PDF, copied into the app container. Has page count, file size, cover
  thumbnail, last-read page, and a progress fraction.
- **Outline**: a tree of headings. It starts from the PDF's own outline and merges in headings the
  reader adds by hand ("Add heading at page N"). A PDF with no outline is fully usable: the reader
  builds the tree as they go.
- **Heading**: a node with a title, a start page, a level, and a derived page range. The range
  runs from the start page to the page before the next heading at the same or a shallower level.
- **Heading path** of a page: the chain of headings whose ranges contain it, shallowest first
  (for page 312: "5 Eigenvalues and Eigenvectors" then "5.2 The Characteristic Equation").
- **Note**: attached to exactly one target, a page or a heading, with at most one note per
  target. A note has two layers: typed text, and Pencil ink over the whole note. There is no
  separate sketch box; the blank space below the text is drawing space and grows as it is used.
- **Note page**: the surface a note is laid out on. It has a fixed logical width (about 320 pt)
  and grows downward. Every place a note appears (side panel, widened panel, bottom sheet,
  Notebook) shows the same layout scaled, never re-wrapped, so ink stays registered to the words
  it was drawn on.
- **Highlight**: a coloured text range on a page, with the highlighted text stored for lists and
  export.
- **Ink**: one PencilKit drawing per page.
- **Bookmark**: a flagged page.

## Behaviour rules

- **Current page** is the page PDFKit reports as current while scrolling. The toolbar subtitle,
  the Contents selection, and the inspector all follow it.
- **Page note** tab always shows the note for the current page and changes as the reader scrolls.
  An empty note is a placeholder, not a stored record.
- **Section note** tab opens on the deepest heading in the current page's heading path. The level
  picker lists the whole path, so a chapter note is one tap up. Below the note it lists the page
  notes inside that heading's range; tapping one jumps to the page.
- **Note badges** in Contents mark a heading that has its own note or any page note or highlight
  in its range.
- **Markup mode** shows the PencilKit tool picker and enables the per-page ink canvases. Drawing
  policy is Pencil only; fingers scroll and zoom. Leaving the mode hides the picker and makes the
  ink read-only. Ink saves when a page leaves the screen, on Done, and when the app backgrounds.
- **Markup mode covers notes too.** There is one mode and one tool picker for the whole reader.
  While it is on, the Pencil inks whichever surface it touches, the PDF page or the open note, and
  undo/redo follow the surface last drawn on. While it is off, the Pencil in a note behaves as in
  any text field (Scribble, selection) and note ink is read-only. A finger always scrolls, and a
  finger tap in a note places the text cursor in either mode, so typing and inking can alternate
  without leaving markup mode.
- **Writing room.** The notes panel can be dragged wider, up to half the screen, and has a zoom
  control (100% to 200%, also pinch). Widening zooms the note page; it does not re-wrap it.
- **Ink follows the text it annotates.** Each stroke belongs to the paragraph it was drawn over,
  or to the blank space after the text. When typing above makes a paragraph move down or up, its
  strokes move with it. Re-wrapping inside a paragraph does not move that paragraph's own strokes;
  the lasso tool is the fix for that case. Deleting a paragraph leaves its strokes in place,
  attached to the paragraph before it.
- **Notes shown elsewhere keep their ink.** The Notebook and the "page notes in this section" list
  render a note with its ink. Editing and inking happen in the notes panel.
- **Highlights** are made from a text selection through the edit menu (colour choices), in or out
  of markup mode. Tapping a highlight offers recolour and delete.
- **Autosave** everywhere, debounced. There is no Save button; the inspector shows "Saved".
- **Deleting a book** removes its file and all of its notes, ink and highlights after a
  confirmation that states those counts.
- **Narrow width** (portrait, Split View, Stage Manager): Contents becomes an overlay and the
  inspector becomes a sheet with medium and large detents and background interaction enabled.
- **Notebook** rows open the reader at that page or heading.
- **Export.** Markdown export carries note text, and for each note with ink an image of the whole
  note (text and ink together) saved beside the Markdown file. Notebook export to PDF is the
  faithful format: every note drawn exactly as it looks, ink included.

## Technical decisions

| Area | Decision | Why |
| --- | --- | --- |
| UI | SwiftUI app; UIKit bridges only for `PDFView` and `PKCanvasView` | System look for free; PDFKit and PencilKit are UIKit views. |
| PDF | PDFKit (`PDFView`, continuous vertical scroll, `PDFOutline`, `PDFSelection`) | Lazy page rendering and text selection without a third-party dependency. |
| Ink | PencilKit, one `PKCanvasView` per visible page through `PDFPageOverlayViewProvider` | Keeps strokes in page coordinates under zoom and scroll; only visible pages hold a canvas. |
| Structured data | SwiftData (`VersionedSchema` from day one) | Books, notes, highlights, bookmarks, user headings. |
| Ink storage | One file per page, `Application Support/Books/<bookID>/ink/<page>.drawing`, and one per note, `.../notes/<noteID>.drawing`; atomic writes | Keeps megabytes of strokes out of the database; one surface's write cannot corrupt another. |
| Note page | A fixed-width, non-scrolling text view with a `PKCanvasView` of the same content size over it, both inside one zooming scroll view | Text and ink share one coordinate space at every zoom; the outer scroll view owns scrolling and pinch. |
| Note ink anchoring | Strokes are stored per paragraph band in band-local coordinates, with the band layout saved alongside; the displayed drawing is composed from the bands' current positions | Typing above a marked-up paragraph moves its ink with it, and a font-metric change between OS versions shifts bands instead of misplacing ink. |
| Note text | Plain text with a fixed font size on the note page; larger text comes from zoom | A fixed layout is what keeps ink registered. Dynamic Type sets the default zoom. |
| Tool picker | One shared `PKToolPicker` owned by the reader session; page canvases and the note canvas register with it | One tool and colour selection across both surfaces. |
| Heading identity | A stable anchor derived from the node's outline path, title and start page, with a fallback match on title plus page | PDF outline items carry no ID, and notes must survive relaunch. |
| Core logic | A pure-Swift package (`ReaderCore`) with no PDFKit or SwiftData imports | Outline, anchoring, scoping and export are testable with `swift test` in seconds. |
| Project file | XcodeGen `project.yml`; the `.xcodeproj` is generated and git-ignored | Parallel agents never edit or merge a `pbxproj`. |
| Minimum OS | iPadOS 18.0 deployment target, confirmed building with Xcode 27.2 (27B52) against the iOS 27.2 simulator SDK. Only the iOS 27.0 simulator runtime is installed, so tests run on 27.0 only; iOS 18 behaviour is not exercised here. | Current SwiftData, `inspector`, and PencilKit tool picker behaviour. |
| Dependencies | None beyond Apple frameworks | |

Agents must check every Apple API named here against the installed SDK's documentation before
building on it. This table records intent, not verified signatures.

## Not in version 1

iCloud sync, collections or tags in the Library, EPUB, OCR for scanned books, handwriting search,
automatic heading detection from page text, split view of two pages or two books, sharing single
notes. The store layout should not rule these out.

## Open questions for the owner

1. App name ("Marginal" is a placeholder) and bundle identifier.
2. Notes are plain text under the ink in version 1 (no bold, lists are typed dashes). Rich text
   changes line heights mid-note and makes ink anchoring harder; is plain text acceptable?
3. Should exporting an annotated PDF copy of the book (WP11) be in version 1?
