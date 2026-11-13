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
6. **A full iPadOS citizen.** The app supports multiple windows and every system windowing mode.
   Any screen works at any window size, and a reader can keep several windows open at once: two
   books side by side, a book beside its Notebook, or the same book twice.
7. **Apple Pencil works the way it does in Apple's own apps.** The app defers to the system for
   everything the Pencil does (tool picker, preferences, squeeze, double-tap, hover, Scribble)
   and keeps ink as vector strokes from the canvas to the export.

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
- **Section history**: each reader window's own back and forward trail of the sections the reader
  has jumped between, like a browser's history but for headings. An entry is a place: a page and
  the section that page is in.

## Behaviour rules

- **Section history** (added by the owner after the first plan). The reader toolbar has Back and
  Forward buttons that step through the sections the reader has jumped between.
  - A *jump* is any navigation that is not scrolling: choosing a heading in Contents, go to page,
    a bookmark, a thumbnail, a search hit, a link inside the PDF, a row in the Notebook or in
    "page notes in this section", the level picker's heading, first or last page. Scrolling,
    paging to the next or previous page, and zooming are never jumps.
  - A jump to a different section records the place being left (the page actually on screen at
    that moment and its section), drops any forward entries, and adds the destination. A jump
    that lands in the section the reader is already in moves the page without adding an entry.
    "Section" here is the deepest heading containing the page; a page before the first heading, or
    any page in a book with no outline, counts as its own place ("Page N").
  - Back returns to the previous entry at the page the reader left it on, not the section's first
    page; Forward undoes Back. Before either moves, the current entry is updated to the page on
    screen, so going back and forward again returns to the same spot.
  - Pressing and holding either button lists the entries in that direction by section title and
    page, and choosing one jumps straight to it. The buttons are disabled when there is nothing in
    their direction, and they are visibly different from the "‹ Library" button.
  - The history belongs to the window: two windows on one book have separate trails. It is
    restored with the window and capped at a fixed length (oldest entries drop off). An entry
    whose heading was deleted or changed keeps working by its page.
  - Menu bar commands and keyboard shortcuts: Back ⌘[ and Forward ⌘].
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
  policy is the system default (see "Apple Pencil" below): with a Pencil in use only the Pencil
  draws, and fingers scroll and zoom. Leaving the mode hides the picker and makes the
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

## Windows and scenes

Added by the owner after the first plan. These rules apply to every screen and every package.

- **Multiple windows.** The app declares multiple-scene support. A window shows the Library, a
  reader on one book, or one book's Notebook. A Library window opens a book in place (the mockups'
  "‹ Library" back button); "Open in New Window" is offered wherever a book or a Notebook can be
  opened (context menu, menu bar, and dragging a book cover out of the Library), and the system's
  own "New Window" makes another Library window.
- **Each window is independent.** It has its own reader session: current page, zoom, panels,
  markup mode, tool picker, undo stack and search. Nothing about one window's state is global.
- **The same book in two windows stays consistent.** Notes, highlights, bookmarks, user headings
  and ink are shared data: a change made in one window appears in every other window showing that
  book without a relaunch. A surface that is mid-stroke or mid-edit is never overwritten by a
  change arriving from another window; it reconciles when the stroke or edit ends. The book's
  stored last-read page follows the most recently active window.
- **Closing and deleting.** A window that goes to the background or is closed saves pending text
  and ink first. Deleting a book closes every reader and Notebook window showing it.
- **State restoration.** Each window restores what it was showing (screen, book, page, panels)
  after the system reclaims it or the app relaunches. Markup mode is not restored.
- **Any size.** Layout is driven by the window's own size and size class, never by the screen or
  the device orientation, so full screen, Split View, Slide Over, Stage Manager, freely resized
  windows and external displays all work. The "narrow width" rule above is about window width.
  A minimum window size is declared so no layout has to work below it.
- **System chrome.** Navigation bars and toolbars are the system ones, so window controls and the
  menu bar get their space without custom layout. Every reader action has a menu bar command with a
  keyboard shortcut, and commands act on the focused window.
- **Files and drag and drop.** A PDF opened from Files or another app ("Open in") is imported and
  shown in a window. PDFs can be dropped onto the Library to import them.

## Apple Pencil

Added by the owner after the first plan.

- **Defer to the system.** PencilKit is the only drawing engine, and the tool picker is the system
  `PKToolPicker` with its standard tools, not a custom palette (the palette drawn in the mockups
  stands for it). Whatever the picker and the system already do is left alone and not
  re-implemented: tool, colour and width selection, the ruler, Pencil double-tap and squeeze
  following the reader's Pencil settings, hover preview, barrel roll and haptics on Pencil Pro.
- **Drawing policy is the system default.** Canvases use PencilKit's default drawing policy, which
  honours the "Only Draw with Apple Pencil" setting and the picker's Draw with Finger switch. With
  a Pencil in use this is exactly principle 4; a reader with no Pencil can still draw with a
  finger. The `-inkAnyInput` test switch forces any-input drawing.
- **Scribble.** Every text input (notes, search, go-to-page, titles) is a standard text control so
  Scribble works in it without extra code.
- **Vector ink.** Ink is stored as PencilKit drawings (vector strokes), never as bitmaps, and is
  re-rendered from the strokes at the size it is shown: canvases stay sharp at any zoom, and
  read-only views (Notebook, section list) draw from the strokes at their display scale instead of
  scaling a cached image. PDF exports draw ink as vector paths wherever the stroke's ink can be
  reproduced faithfully that way, and fall back to a high-resolution image only for inks that
  cannot (textured inks such as crayon or watercolour). Markdown export images are bitmaps because
  Markdown has no portable vector image; they are rendered at 3x.

## OS versions

Added by the owner after the first plan: run on the lowest system possible, and let later systems
take full advantage of their SDKs.

- **The floor is iPadOS 17.0.** Every feature in this document works there. Nothing is dropped on
  an older system; it is only done with the API that system has.
- **Newer API is adopted behind an availability check**, never by raising the deployment target.
  The check sits in one small place per feature (a view modifier, a factory, an extension) with
  the older path beside it, so the newer path is easy to find and the older one easy to delete
  when the floor rises. The compiler enforces this: an unguarded call to a newer API does not
  build.
- **Where the newer path matters** (each agent verifies the real availability against the
  installed SDK before relying on this list):
  - *iPadOS 18:* SwiftData `#Unique` and `#Index` (the floor enforces uniqueness in the repository
    instead), `PKToolPicker` item customisation, newer SwiftUI scroll, zoom-transition and tab
    APIs.
  - *iPadOS 26:* the resizable-window model with window controls in the toolbar area, the system
    menu bar, the current system material and toolbar styling, any newer PencilKit and Pencil Pro
    API.
  - *iPadOS 27:* whatever the installed SDK adds for windows, scenes and PencilKit.
- **At the floor the same features use the older system model**: multiple windows through Split
  View, Slide Over and Stage Manager; keyboard shortcuts through the same SwiftUI commands (shown
  in the shortcut overlay instead of a menu bar).
- **Testing.** Two simulator runtimes are installed: iOS 27.0 and iOS 17.5 (the 17.5 image was
  downloaded from Apple's developer site by the owner and imported with `xcrun simctl runtime
  add`; Xcode 27.2 will not download it itself). Every package runs its tests on both, so the
  floor's fallback paths are exercised and not only compiled. Systems in between (18, 26) are
  covered by the compiler and by review.

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
| Minimum OS | iPadOS 17.0 deployment target, built with Xcode 27.2 (27B52) against the iOS 27.2 SDK (confirmed: the build targets `arm64-apple-ios17.0-simulator`). Tests run on the iOS 27.0 and iOS 17.5 simulator runtimes; behaviour on 18 and 26 is compiler-checked but not exercised. | The owner wants the lowest system the design allows. 17.0 is the floor because SwiftData and the Observation framework (`@Observable`) start there. |
| Newer-OS features | Availability-gated (`if #available`, `@available`) with a working fallback at the floor; see "OS versions" | Later systems get everything the SDK offers without raising the floor. |
| Scenes | SwiftUI `WindowGroup`s: Library, and value-based groups for a reader and a Notebook keyed by book ID; one `ReaderSession` per reader window; `@SceneStorage` or a user activity for restoration | Multiple windows, state restoration and "Open in New Window" from system APIs. |
| Shared data across windows | One `ModelContainer` for the app, read on the main actor by every window; an in-process change hub announces ink and note-ink writes (book, page or note ID) so other windows reload that surface | SwiftData observation keeps structured data in step; ink lives in files and needs its own signal. |
| Drawing policy | `PKCanvasView.drawingPolicy = .default`, with the shared system `PKToolPicker` | Honours the reader's Pencil settings instead of overriding them. |
| Vector ink | `PKDrawing` data on disk; live `PKCanvasView` rendering; exports stroke paths as vector | Sharp at any zoom and in exported PDFs. |
| Dependencies | None beyond Apple frameworks | |

Agents must check every Apple API named here against the installed SDK's documentation before
building on it. This table records intent, not verified signatures.

## Not in version 1

iCloud sync, collections or tags in the Library, EPUB, OCR for scanned books, handwriting search,
automatic heading detection from page text, an in-window split of two pages or two books (two
windows cover this), sharing single notes, PaperKit shapes and text boxes on the page. The store layout should not rule these out.

## Open questions for the owner

1. App name ("Marginal" is a placeholder) and bundle identifier.
2. Notes are plain text under the ink in version 1 (no bold, lists are typed dashes). Rich text
   changes line heights mid-note and makes ink anchoring harder; is plain text acceptable?
3. Should exporting an annotated PDF copy of the book (WP11) be in version 1?
