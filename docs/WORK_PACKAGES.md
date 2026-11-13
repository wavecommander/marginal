# Marginal: work packages

Read `docs/DESIGN.md` first. This file splits the build into packages sized for one subagent each
and says which model runs each one. It is written for an orchestrating Claude Code session
**running on the Mac**, where Xcode and the simulators are available.

## How to run this plan

- **Orchestrator** (the main session): spawns one subagent per package with the Agent tool, sets
  `model` to the package's model, and uses `isolation: "worktree"` for packages that run in
  parallel. It merges each wave, runs the full gate, and reviews the diff before starting the next
  wave. It does not write feature code itself.
- **Model choice**: Opus where the package sets contracts other packages depend on, bridges
  UIKit and SwiftUI under performance pressure, or has failure modes that only show up as subtle
  bugs. Sonnet where the contract already exists and the work is building to it.
- **Brief for each subagent**: the package section below, `docs/DESIGN.md`, the mockup link, the
  files it owns, and the gate commands. Tell it which earlier packages are merged.
- **Gate** (every package, before it reports done):
  1. `scripts/build.sh` builds the app for the chosen iPad simulator with no warnings promoted
     from its own files.
  2. `scripts/test.sh` passes: `swift test` in `Packages/ReaderCore`, then `xcodebuild test` on the
     simulator.
  3. For UI packages: `scripts/shot.sh <name>` launches the app on the simulator into the relevant
     screen with the fixture book and saves a screenshot. The agent looks at it against the
     matching mockup artboard and lists the differences it left.
- **Fixtures**: `Fixtures/make-fixtures.swift` generates PDFs at build-test time, never committed:
  `small.pdf` (12 pages, 2-level outline), `large.pdf` (1,500 pages, 3-level outline, real text
  on every page), `no-outline.pdf` (40 pages, no outline).
- **Simulator limits**: Pencil pressure, hover, double-tap and palm rejection cannot be tested in
  the simulator. A `-inkAnyInput` launch argument switches the drawing policy to any input so UI
  tests can draw. Real-device Pencil checks are listed in WP12 for the owner.
- A subagent that finds the design wrong or an API missing stops and reports; it does not invent
  a workaround that changes behaviour.

## Waves

| Wave | Packages (parallel within a wave) |
| --- | --- |
| 0 | WP0 scaffold (Sonnet) · WP1 core model (Opus) |
| 1 | WP2 persistence (Sonnet) · WP4 reader engine (Opus) |
| 2 | WP3 library and import (Sonnet) · WP5 sidebar (Sonnet) · WP6 page ink (Opus) · WP7 highlights (Sonnet) |
| 3 | WP13 note page: text with ink (Opus) · WP10 search (Sonnet) · WP11 annotated export (Opus, optional) |
| 4 | WP8 notes panel (Sonnet) · WP9 notebook and export (Sonnet) |
| 5 | WP12 integration, performance, polish (Opus) |

WP13 was added after the first plan, which is why its number is out of order. It sits before WP8
and WP9 because both of them display the note page it builds.

## Platform requirements added by the owner (every package)

`docs/DESIGN.md` gained two sections after this plan was written, "Windows and scenes" and "Apple
Pencil", plus principles 6 and 7. They bind every package. What each package adds because of them:

- **WP2**: one `ModelContainer` shared by all windows; repositories safe to use from several
  windows' sessions at once; a change hub (`InkChangeHub` or similar) that announces page-ink and
  note-ink writes and deletions so other windows can reload that surface.
- **WP3**: "Open in New Window" on a book (context menu and drag out of the grid); several Library
  windows show the same live list; deleting a book closes the windows showing it; a PDF arriving
  through "Open in" is imported and shown in a window.
- **WP4**: the scene architecture. `WindowGroup`s for Library, reader (by book ID) and Notebook
  (by book ID); one `ReaderSession` and one tool picker per reader window; per-window state
  restoration; a declared minimum window size; layout from window size only; the menu bar command
  set with keyboard shortcuts routed to the focused window; a `-alsoOpenWindow <title>` launch
  argument that opens a second reader window so UI tests can exercise two windows.
- **WP5, WP7, WP8, WP10**: every view reads and commands its own window's session, never a shared
  one, and shows changes made in another window on the same book.
- **WP6, WP13**: system `PKToolPicker` with its standard tools, default drawing policy, nothing
  that overrides Pencil double-tap, squeeze or hover; reload a surface when the change hub reports
  a write from another window unless a stroke or edit is in progress; ink only ever stored as
  `PKDrawing` data.
- **WP9, WP11**: PDF export draws ink as vector paths where the ink allows it; read-only note
  views render from the strokes at display scale.
- **WP12**: two-window UI tests (same book twice: ink, note and highlight made in one window
  appear in the other; two different books; close and restore a window), a resize pass from the
  minimum window size to full screen on both simulators, and the menu bar commands.

## Repository layout (WP0 creates it; later packages own the folders named)

```
project.yml                     XcodeGen spec
scripts/                        build.sh, test.sh, shot.sh, sim.sh
App/                            app target: entry point, assets, Info.plist keys
App/Features/Library/           WP3
App/Features/Reader/            WP4 (shell, PDF bridge, session)
App/Features/Sidebar/           WP5
App/Features/Markup/            WP6
App/Features/Highlights/        WP7
App/Features/NotePage/          WP13 (note text + ink surface, read-only renderer)
App/Features/Notes/             WP8
App/Features/Notebook/          WP9
App/Features/Search/            WP10
App/Features/Export/            WP11
Packages/ReaderCore/            WP1 (pure Swift)
Packages/ReaderStore/           WP2 (SwiftData, ink files)
Fixtures/                       fixture generator
UITests/                        one file per feature, owned by that feature's package
docs/                           DESIGN.md, WORK_PACKAGES.md
```

## Packages

### WP0 · Project scaffold and toolchain · Sonnet

- Record the installed Xcode version and available iPad simulators (`xcodebuild -version`,
  `xcrun simctl list devices available`); pick one 11-inch and one 13-inch iPad and write them to
  `scripts/sim.sh`. Confirm or correct the minimum OS in `docs/DESIGN.md`.
- `project.yml` with the app target, unit-test and UI-test targets, and the two local packages.
  PDF document type registered so "Open in" and Files work.
- The four scripts. `shot.sh` boots the simulator, installs, launches with arguments, and saves
  `build/shots/<name>.png` through `xcrun simctl io`.
- Fixture generator.
- App launches to an empty "Library" screen.
- **Done when** the gate passes on a clean clone and a Library screenshot exists.

### WP1 · Core model and outline engine · Opus

Everything else depends on these types, and heading identity is the riskiest decision in the app.

- `ReaderCore`: `OutlineNode`, building a tree from a flat list of raw entries (title, level,
  page index or none), derived page ranges, `headingPath(forPage:)`, merging user headings into
  the PDF outline, the stable `HeadingAnchor` and its re-matching rule.
- `NoteTarget` (page or heading), value types for note, highlight and bookmark, and the store
  protocols WP2 implements (`BookRepository`, `NoteRepository`, `HighlightRepository`,
  `InkStore`, `HeadingRepository`).
- `NotebookBuilder`: given the outline and all notes and highlights, produce the tree the
  Notebook and the note badges render (per-heading own note, page notes in range, highlights in
  range, rolled-up counts).
- `MarkdownExporter` over that tree, with a hook for a per-note image reference.
- `NoteBands`: the pure geometry behind note ink anchoring. Given the saved band layout
  (paragraph tops and heights) and the current one, return the vertical offset for each band;
  given a stroke's bounds, return the band it belongs to. No PencilKit types here, only rects, so
  WP13 can test its composition against it.
- **Cases the tests must cover**: entries with no destination; entries out of page order; several
  headings starting on one page; duplicate titles; a page before the first heading; a 4-level
  outline; an empty outline with user headings only; a user heading inserted between PDF
  headings; anchors unchanged after re-reading the same PDF. For `NoteBands`: a paragraph grows
  above a marked band; a paragraph is deleted; a paragraph is inserted; text is emptied; a stroke
  spans two bands; a stroke lies wholly below the text.
- **Done when** `swift test` passes and the public API has doc comments stating each rule.

### WP2 · Persistence · Sonnet

- `ReaderStore`: SwiftData models under `VersionedSchema` v1 and repository implementations of
  the WP1 protocols. Uniqueness of one note per target enforced.
- File-backed `InkStore` for page ink and note ink: atomic write, read, delete, per-book
  directory removal. A note's band layout is stored with the note record; deleting a note deletes
  its ink file.
- Cascade delete of a book and a count query for the delete confirmation.
- **Done when** repository tests pass against an in-memory container and a temp directory, and
  every test removes what it created.

### WP3 · Library and import · Sonnet

- Import through the Files picker, drag and drop, and "Open in". Copy into the container off the
  main thread with progress and cancellation; cover thumbnail from page one; page count and size.
  Importing the same file twice opens the existing book.
- Library grid, search by title, sort (recently opened, title, date added), Continue reading
  card, context menu with Rename and Delete.
- **Done when** a UI test imports `small.pdf`, sees it in the grid, opens and deletes it;
  importing `large.pdf` keeps the UI responsive (assert on a generous time bound for first frame).

### WP4 · Reader shell and PDF engine · Opus

The integration seam: a wrong lifecycle or threading choice here shows up as jank and lost state
in every later package.

- `PDFView` bridge with a coordinator: continuous scroll, zoom, page-changed tracking, go to
  page, go to heading, restore last position.
- `ReaderSession` (`@Observable`): current page, heading path, outline (loaded off the main
  thread), mode (reading or markup), panel visibility and notes-panel width, and a
  `MarkupSurface` registry: any ink canvas registers with the session, which owns the one shared
  tool picker and routes undo/redo to the surface last drawn on. This is the one object WP5 to WP10 read
  and command; publish its API early in the package so parallel work can start against it.
- Three-pane layout with the narrow-width behaviour from the design; toolbar per the mockup with
  placeholders for panels owned by later packages; page indicator pill with a go-to-page field.
- Memory warning handling; no full-document text extraction; outline load does not block first
  page.
- **Done when** UI tests open `large.pdf`, jump to page 1,200, relaunch and land on the same
  page; first page of `large.pdf` appears within a generous bound; screenshots match the reader
  mockups' structure.

### WP5 · Contents sidebar · Sonnet

- Contents tree with expand and collapse, current-section tracking, tap to jump, note badges from
  `NotebookBuilder` counts.
- Pages tab: lazy thumbnail grid with a cache and cancelled work for cells that scroll away.
- Bookmarks tab; bookmark toggle in the toolbar.
- "Add heading at page N", rename, delete for user headings (PDF headings are read-only).
- **Done when** UI tests cover jump, add heading on `no-outline.pdf`, and bookmark round trip.

### WP6 · Page ink markup · Opus

PencilKit over PDFKit has the least forgiving interplay in the app: overlay lifecycle, zoom
scale, gesture routing, and saving without stalls.

- Overlay provider that gives each visible page a canvas, loads its drawing, and saves when the
  page leaves the screen, on Done, and on backgrounding.
- Page canvases register as `MarkupSurface`s with the session's shared tool picker (WP4), shown
  only in markup mode; Pencil-only policy with the `-inkAnyInput` test switch; undo and redo
  through the session; ink read-only outside markup mode.
- Correct stroke scale at any zoom; no canvas retained for off-screen pages.
- **Done when** a UI test draws on page 3 of `small.pdf`, relaunches, and the stroke is still
  there; scrolling 200 pages of `large.pdf` in markup mode holds memory within a generous bound.

### WP7 · Text highlights · Sonnet

- Edit-menu actions on a text selection for four highlight colours; highlight stored with page,
  rects, colour and text; re-applied when a page is displayed.
- Tap a highlight for recolour and delete.
- If customising the PDF selection menu proves unreliable on the installed SDK, stop and report
  to the orchestrator rather than replacing the interaction.
- **Done when** a UI test highlights a known phrase in `small.pdf`, relaunches, finds it again,
  recolours and deletes it.

### WP13 · Note page: typed text with Pencil ink · Opus

Two input systems share one surface here, and the ink has to stay attached to text that keeps
changing. Getting the anchoring or the touch routing subtly wrong loses or misplaces a reader's
handwriting, which is the worst failure the app can have.

- `NotePageView`: the editable note surface from the design. Fixed logical width, grows downward,
  zoom from 100% to 200%, typed text below, ink above, one coordinate space.
- Touch routing: in markup mode the Pencil inks and a finger scrolls, zooms, or taps to place the
  text cursor; outside markup mode the canvas ignores input and the text view gets everything, so
  Scribble works. Registers as a `MarkupSurface` (WP4) to share the tool picker and undo/redo.
- Ink anchoring on `NoteBands` (WP1): strokes bucketed per paragraph band, the displayed drawing
  composed from current band positions, re-bucketed after each drawing change, band layout saved
  with the note. The blank area after the text is the last band and grows as it is drawn in.
- Debounced autosave of text and ink together; nothing lost when the panel changes page
  mid-stroke, when the app backgrounds, or when the note is emptied.
- `NotePageRenderer`: a read-only view and an image renderer of the same layout, for the
  Notebook, the section list, and export.
- **Done when** UI tests (with `-inkAnyInput`) draw over a word, insert a paragraph above it,
  and assert the stroke's bounds moved by the inserted height; draw, relaunch, and find the
  stroke; type with markup mode on by tapping; confirm the canvas takes no input with markup mode
  off. A screenshot matches the "Markup · page and note together" artboard's structure.

### WP8 · Notes panel · Sonnet

- Page note and Section note tabs per the mockups, level picker over the heading path, the
  WP13 `NotePageView` as the editor with a Saved indicator, "Highlights on this page",
  "Page notes in this section" (rendered with `NotePageRenderer`), and the "This page is in"
  shortcut.
- Draggable panel width up to half the screen, the zoom control, and the shrink button.
- Follows the current page while scrolling without dropping in-progress edits or strokes.
- Sheet presentation at narrow widths.
- **Done when** UI tests write a page note and a section note, scroll away and back, relaunch,
  and read both; the chapter-level note is reachable from a page inside a subsection; and
  widening the panel changes the note's zoom, not its line breaks.

### WP9 · Notebook and Markdown export · Sonnet

- Notebook screen per the mockup from `NotebookBuilder`: heading filter column, feed, type
  filter, search within notes, tap a row to open the reader there. Notes with ink are drawn with
  `NotePageRenderer` (WP13), so the ink shows over the text.
- Export through the share sheet: Markdown using `MarkdownExporter`, with an image of each
  marked-up note beside it; and the Notebook as a PDF with every note drawn as it looks.
- **Done when** a UI test with seeded notes checks grouping under the right headings, the
  exported Markdown matches a golden file and references an image for the seeded marked-up note,
  and the exported PDF opens with at least one page.

### WP10 · Search · Sonnet

- In-book text search that streams results, can be cancelled, and groups hits by heading; notes
  and highlights searched alongside. Selecting a hit jumps and marks it on the page.
- **Done when** a UI test finds a known phrase on page 1,400 of `large.pdf` while the UI stays
  responsive, and cancelling a search stops further results.

### WP11 · Annotated PDF export · Opus · optional for version 1

- Write a copy of the book with ink and highlights drawn in, page by page with bounded memory,
  progress and cancellation. The original stays untouched.
- **Done when** exporting `large.pdf` with annotations on 50 pages completes within a generous
  bound, the output opens in PDFKit with the same page count, and marked pages differ from the
  originals.

### WP12 · Integration, performance and polish · Opus

- End-to-end UI test of the main journey: import, read, mark up the page, highlight, page note,
  mark up the note, section note, notebook, export, relaunch.
- Launch and scroll performance on `large.pdf`; fix what the measurements show.
- Accessibility pass (VoiceOver labels, Dynamic Type in the panels), dark mode, keyboard
  shortcuts, pointer hover states.
- Screenshot every mockup state on both simulators and list remaining differences.
- A short real-device checklist for the owner: Pencil pressure and tilt, hover, double-tap tool
  switch, palm rejection, finger scrolling while in markup mode, writing on a note with the palm
  resting on the page beside it, Scribble into a note with markup mode off, and moving the Pencil
  from the page to the note mid-session without the tool changing.
- **Done when** the full gate passes from a clean clone and the checklist and difference list are
  committed under `docs/`.
