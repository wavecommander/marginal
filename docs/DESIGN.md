# Tactile Texts: design

The app's name is **Tactile Texts** (owner decision, 14 November 2026): that is the name on the
Home Screen, in the menu bar, in exported files' metadata and on the App Store. "Marginal" was
the working title and remains the internal name only: the repository, the Xcode target, scheme
and Swift module (`Marginal`), and the bundle identifier (`software.tactile.marginal`).

A native iPadOS app for reading large textbook PDFs, marking them up, and keeping notes attached
to pages and to headings.

Mockups: https://claude.ai/artifact/DGC3WWVFeVmNY7pSaKknpP (seven screens plus four first-run
onboarding screens; names below match the artboard titles). The mockups are drawn in HTML, so treat them as layout and behaviour intent.
System controls (segmented controls, sheets, the PencilKit tool picker) should be the real system
ones even where the mockup draws an approximation.

## Principles

1. **The PDF is never modified after import.** Ink, highlights, notes and bookmarks live in the
   app's own store beside the imported file. Exporting an annotated copy is an explicit action. A
   book converted from another format (see "Importing other formats") has its PDF generated once,
   during the import, and never touched after that; the original file is kept beside it, untouched.
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
| Library | Imported books in a grid with progress, search, sort, Import, and a "Continue reading" card with shortcuts to Resume and to the Notebook. |
| Reader · page note | The main reading layout: Contents sidebar (PDF outline with note badges), the page, and the Notes inspector on "Page note". |
| Markup with Apple Pencil | Markup mode: ink over the page, a tool palette, undo/redo, Done. (Superseded by the owner: undo/redo live in the tool picker and there is no Done button; see "Markup controls".) |
| Markup · page and note together | Markup mode with the notes panel widened to half the screen: the same tool palette inks the PDF page on the left and the note on the right. The note is zoomed to 140% for writing; ink sits over the typed text and in the blank space below it. |
| Reader · section note | Notes inspector on "Section note": the heading's note, with the level picker (the heading path) in a collapsible list under it. The mockup's level picker at the top and its list of page notes inside the heading were removed by the owner (see "Notes panel layout"). |
| Notebook · all notes by heading | Every note and highlight for one book, laid out along the outline, filterable, exportable. |
| Portrait · notes sheet | Narrow widths: the inspector becomes a resizable bottom sheet and the page stays scrollable behind it. |
| Onboarding · welcome sheet | First launch: a form sheet over the Library with three things worth knowing, "Open the Quick Guide", and "Not now". |
| Onboarding · empty Library after Not now | The Library with no books: Import PDF, Open the Quick Guide, and the drag hint. |
| Onboarding · Quick Guide, page 1 | The bundled six-page guide open in the ordinary reader, with a seeded page note that already carries ink. |

## Concepts

- **Book**: one imported PDF, copied into the app container. Has page count, file size, cover
  thumbnail, last-read page, and a progress fraction. A *converted* book was imported from another
  format (EPUB, a comic or images, and the other formats in "Importing other formats"): its PDF was
  generated at import and is read like any other, and the original file is kept unchanged beside
  it, so the book's file size counts both. A converted book records the format it came from and
  the original file's name, and says "Converted from …" in the Library's book menu and the
  reader's More menu. Converting the same file again makes a new book.
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
- **Note page**: the surface a note is laid out on. It is about 320 pt wide and grows downward.
  The side panel, bottom sheet and Notebook show that layout, scaled. A widened notes pane
  widens the page instead and the text re-wraps to it at the same size (TSOFT-226), so ink drawn
  over a word at one width can sit off it at another; ink always stays with its paragraph.
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
    a bookmark, a thumbnail, a search hit, a link inside the PDF, a row in the Notebook, the level picker's heading, first or last
    page. Scrolling,
    paging to the next or previous page, and zooming are never jumps.
  - A jump to a different section records the place being left (the page actually on screen at
    that moment and its section), drops any forward entries, and adds the destination. A jump
    that lands in the section the reader is already in moves the page without adding an entry.
    "Section" here is the deepest heading containing the page; a page before the first heading, or
    any page in a book with no outline, counts as its own place ("Page N").
  - Back returns to the previous entry at the exact place the reader left it: the same point of
    the same page at the top of the view, not the top of that page and not the section's first
    page. Forward undoes Back in the same way. Before either moves, the current entry is updated
    to the place on screen, so going back and forward again, any number of times and with jumps
    in between, always returns to the spot the reader left (owner bug report TSOFT-214,
    14 November 2026: after Back then Forward, following a link and going Back did not return to
    the page the reader had been on).
  - Pressing and holding either button lists the entries in that direction by section title and
    page, and choosing one jumps straight to it. The buttons are disabled when there is nothing in
    their direction, and they are visibly different from the "‹ Library" button.
  - The history belongs to the window: two windows on one book have separate trails. It is
    restored with the window and capped at a fixed length (oldest entries drop off). An entry
    whose heading was deleted or changed keeps working by its page.
  - Menu bar commands and keyboard shortcuts: Back ⌘[ and Forward ⌘].
- **The reading position is stable** (owner feedback from the first device build). Opening or
  closing the Contents sidebar or the Notes panel, dragging the panel divider, resizing or rotating
  the window, and showing or hiding the keyboard never move the reader's place in the book: the
  point of the page at the top of the view stays at the top of the view, exactly, and closing
  then reopening a panel returns to the identical position with no drift however often it is
  repeated. Only scrolling, zooming and jumps change the position.
- **No scroll-to-top** (owner feedback). Tapping the book's title, the navigation bar or the
  status bar never sends the reader to the first page. The system's tap-to-scroll-to-top gesture
  is switched off for the PDF: in a book of thousands of pages it loses the reader's place, and
  the first page is one command away (Go › First Page) when it is wanted.
- **The reader's own headings** (owner requirement). Readers can create section headings of
  their own in any book, and a PDF with no outline can be given a complete structure this way.
  - *Adding:* "Add Heading at This Page" is offered from the Contents sidebar (always, and as
    the main action of its empty state), the reader's More menu, the menu bar with a keyboard
    shortcut, the notes panel when the current page is in no section, and the text-selection
    menu ("Add as Heading", which uses the selected text as the title). It asks for a title and
    where the heading sits: top level, or under any heading that contains the page.
  - *Editing:* a reader's heading can be renamed, moved to another page, moved to another level
    or parent, and deleted. Deleting keeps its sub-headings (they move up one level) and its
    note (which stays in the Notebook as unfiled until it is re-attached). Headings from the PDF
    itself are read-only.
  - *Everywhere a heading matters:* a reader's heading behaves exactly like a PDF heading. It
    has a page range, appears in Contents, the heading path, the toolbar subtitle, the Section
    note tab and its level picker, the Notebook, search grouping, section history and exports.
  - Headings are saved with the book, appear in every window showing it, and are marked as the
    reader's own wherever they are listed.
- **Current page** is the page PDFKit reports as current while scrolling. The toolbar subtitle,
  the Contents selection, and the inspector all follow it.
- **Page note** tab always shows the note for the current page and changes as the reader scrolls.
  An empty note is a placeholder, not a stored record.
- **Section note** tab opens on the deepest heading in the current page's heading path. The level
  picker, under the note, lists the whole path, so a chapter note is one tap up (see "Notes panel
  layout").
- **Note badges** in Contents mark a heading that has its own note or any page note or highlight
  in its range.
- **Markup mode** shows the PencilKit tool picker and enables the per-page ink canvases. Drawing
  policy is the system default (see "Apple Pencil" below): with a Pencil in use only the Pencil
  draws, and fingers scroll and zoom. Leaving the mode hides the picker and makes the
  ink read-only. Ink saves when a page leaves the screen, on leaving markup mode, and when the app backgrounds.
- **Markup controls.** The toolbar's Markup button is the only switch for the mode, and it is
  always in the same place: outlined while markup is off, filled while it is on, and tapping it
  toggles. There is no Done button, and the rest of the toolbar is the same in both modes. Undo
  and Redo for ink are the system tool picker's own Undo and Redo buttons, not toolbar buttons;
  they act on the surface last drawn on, as do ⌘Z / ⇧⌘Z and Edit ▸ Undo/Redo. Only where the
  system picker has no Undo and Redo buttons (compact-width windows) does the toolbar show them.
- **Markup mode covers notes too.** There is one mode and one tool picker for the whole reader.
  While it is on, the Pencil inks whichever surface it touches, the PDF page or the open note, and
  undo/redo follow the surface last drawn on. While it is off, the Pencil in a note behaves as in
  any text field (Scribble, selection) and note ink is read-only. A finger always scrolls, and a
  finger tap in a note places the text cursor in either mode, so typing and inking can alternate
  without leaving markup mode.
- **Typing in markup mode** (owner decision, 15 November 2026). With the on-screen keyboard, the
  tool picker steps aside while the cursor is in the note, so the keyboard stays up and nothing
  overlaps it; when typing ends (the keyboard's own dismiss key, or a stroke on the note) the
  picker comes back exactly as it was: same tool, colour, width and place. With a hardware
  keyboard attached the picker stays on screen while typing, and inking does not end typing.
  The system picker cannot be shrunk or moved by the app, so stepping aside means hidden.
- **Writing room.** The notes panel can be dragged wider, up to half the screen, and the note
  is zoomed by pinching it (100% to 200%). There is no zoom button (owner decision,
  14 November 2026: pinching is enough). Widening the pane makes the note page wider, in
  proportion to the pane, without zooming it: the text keeps the size the reader pinched to and
  re-wraps to fill the page (owner decision, 15 November 2026, TSOFT-226).
  The handle on the pane's edge also closes it (owner requirement): sliding the handle towards
  the pane's own edge, past its narrowest width, collapses the notes pane, following the finger
  and snapping shut on release; a short slide that stops above the narrowest width just resizes.
  The toolbar's notes button brings the pane back at the width it had before.
- **Ink follows the text it annotates.** Each stroke belongs to the paragraph it was drawn over,
  or to the blank space after the text. When typing above makes a paragraph move down or up, its
  strokes move with it. Re-wrapping inside a paragraph does not move that paragraph's own strokes;
  the lasso tool is the fix for that case. Deleting a paragraph leaves its strokes in place,
  attached to the paragraph before it.
- **Notes shown elsewhere keep their ink.** The Notebook renders a note with its ink. Editing
  and inking happen in the notes panel.
- **Notes panel layout** (owner decisions, 14 November 2026; TSOFT-217 and TSOFT-218). The panel
  is the tabs, the note's title, the note, and as little else as possible:
  - *Header:* the Page note / Section note tabs, Delete Note, the shrink control when the pane
    is widened, then the title (the page number, or the heading's title and page range) and the
    save status. No zoom button, and no level picker here.
  - *Page note tab, under the note:* "Highlights on this page", only while the page has any.
    There is no "This page is in" list: the toolbar subtitle, the Contents sidebar and the
    Section note tab already say where the page sits.
  - *Section note tab, under the note:* the level picker, at the bottom of the panel. It is the
    heading path, shallowest first, with the shown heading marked and a mark on each level that
    has a note; choosing a level shows that heading's note. It can be collapsed to a single row
    that names the shown heading, it starts collapsed, and the choice is remembered. Below it,
    "Open in Notebook". There is no "Page notes in this section" list: the Notebook lists a
    section's page notes.
- **Highlights** are made from a text selection through the edit menu (colour choices). Tapping
  a highlight offers recolour and delete. **Text highlights are made with a finger, outside
  markup mode** (owner decision for now): on the current SDK text cannot be selected while the
  ink canvas is active, so in markup mode the reader marks text by hand with the picker's
  highlighter pen, and leaves markup mode to make a text highlight. Existing highlights stay
  visible in markup mode.
- **Select All selects the paragraph** (owner requirement). In the reader, Select All (the edit
  menu item and ⌘A) never selects the whole book: PDFKit's default tries to select every page,
  which on a book of thousands of pages is slow and useless. With text selected, Select All
  grows the selection to the whole paragraph that contains it, on that page; if the selection
  already covers a paragraph, or spans several, it grows to the whole paragraphs it touches and
  no further. With nothing selected it does nothing in the PDF. Paragraphs are found from the
  page's own text layout (line spacing and indentation), page by page, never by reading other
  pages. Select All inside a text field or a note keeps its normal meaning.
- **Ink is navigable like highlights and bookmarks** (owner requirement). Whatever the Pencil
  puts on a page, highlighter strokes and drawings alike, is something the reader can find and
  return to, not only something they see when they happen to scroll past it:
  - every page with ink is listed in the Notebook under its section, with a preview of the ink
    on its page, filterable as its own type, and included in the Notebook's PDF export;
  - tapping such a row jumps to the page through the reader's jump API, so section history
    records it; and the Notebook updates as ink is added or erased, in any window.
  - *Owner decision, 14 November 2026: ink navigation lives in the Notebook.* The earlier plan
    to also list inked pages in the sidebar, flag them in the Pages grid and count them in
    Contents badges is dropped.
- **The notes pane follows the system appearance** (owner requirement). In Dark Mode the whole
  notes pane is dark, including the note page itself: dark paper, light typed text, and ink that
  stays legible, using PencilKit's own light and dark ink rendering so a stroke drawn in one
  appearance reads correctly in the other (black ink shows light on dark paper and returns to
  black in Light Mode; the stored strokes are never changed by switching appearance). The pane
  switches live with the system setting. This replaces the first build's choice to keep the note
  page light in Dark Mode. Read-only notes in the Notebook follow the appearance too; exports (Markdown images, PDF) are always light, on white. PDF pages stay as
  the PDF draws them.
- **Deleting a note** (owner requirement). The notes pane has a visible control to delete the
  note it is showing, page note or section note: a Delete Note action in the note's header,
  disabled while the note is empty. It asks for confirmation, saying what will go (the typed
  text and any handwriting on the note; ink on the PDF page and highlights are not touched), then
  removes the note and its ink and leaves the empty placeholder. The same action is offered on a
  note's row in the Notebook. The change shows in every
  window.
- **Autosave** everywhere, debounced. There is no Save button; the inspector shows "Saved".
- **Deleting a book** removes its file and all of its notes, ink and highlights after a
  confirmation that states those counts.
- **Narrow width** (portrait, Split View, Stage Manager): Contents becomes an overlay and the
  inspector becomes a sheet with medium and large detents and background interaction enabled.
- **Notebook** rows open the reader at that page or heading.
- **Export.** Three formats, from the Notebook's Export menu, through the share sheet:
  - *Markdown*: one `.md` file, text only. If the export has a note with ink or a page with
    handwriting, the app first says that images are not included and offers the ZIP.
  - *Markdown (ZIP)*: a folder with the `.md` and the images it links: `images/` holds an image of
    each note with ink (text and ink together), `handwriting/` an image of each page with
    handwriting (the page of the book with its ink).
  - *PDF*: the faithful format, every note drawn exactly as it looks, ink included.
- **Choosing what to export.** Export takes the whole Notebook. "Select" puts a checkbox on every
  row (a heading's checkbox ticks everything shown under it; "Select All" ticks what the filters
  show); Export then takes only the ticked notes, highlights and handwriting, in any format. The
  selection is kept while the heading, type filter and search change, and ends with "Done".

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
- **One latest position per book** (owner decision, 15 November 2026). Readers of the same book
  are treated identically: every reader that loads a book (opened, woken from sleep, in another
  window, restored after a relaunch) opens at the book's latest position, the exact place and zoom
  any reader on it last left, unless it was opened at a particular page (a Notebook row, a link,
  "Open in New Window" at a page). The position is saved a moment after the reader stops moving,
  and at once when the reader is covered, popped or backgrounded.
- **Sleeping readers** (owner decision, 15 November 2026). A window keeps awake only the top
  screen of its stack and the one directly under it (so the back swipe shows a live reader). A
  reader further down falls asleep after a short delay (five seconds): it saves everything, then
  lets go of its document, views, ink canvases, notes, search and outline, keeping only what it
  needs to come back. It wakes as soon as it is the top screen or the one under it again, at the
  book's latest position with the window's panels and section history for the book; search
  results, a text selection and markup mode are not kept. A popped reader lets go the same way.
- **Closing and deleting.** A window that goes to the background or is closed saves pending text
  and ink first. Deleting a book closes every reader and Notebook window showing it.
- **State restoration.** Each window restores what it was showing (screen, book, panels, section
  history; the page is the book's latest position) after the system reclaims it or the app
  relaunches. Markup mode is not restored.
- **Any size.** Layout is driven by the window's own size and size class, never by the screen or
  the device orientation, so full screen, Split View, Slide Over, Stage Manager, freely resized
  windows and external displays all work. The "narrow width" rule above is about window width.
  A minimum window size is declared so no layout has to work below it.
- **System chrome.** Navigation bars and toolbars are the system ones, so window controls and the
  menu bar get their space without custom layout. Every reader action has a menu bar command with a
  keyboard shortcut, and commands act on the focused window.
- **Files and drag and drop.** A PDF opened from Files or another app is imported and shown in a
  window: Files lists Tactile Texts under a PDF's Open With, and the share sheet offers it too.
  PDFs can be dropped onto the Library to import them. The same holds for the formats the app
  converts, after the Convert to PDF sheet (see "Importing other formats"). A backup file
  (`.ttbackup`) opened the same ways starts the restore preview. The app declares that it opens
  documents in place (owner request, 15 November 2026: without that, Files shows "No Apps
  Available" under Open With); it still copies what it imports into the library, and the
  reader's own file is only ever read.

## Icon, accent and launch screen

Added by the owner (TSOFT-215, 14 November 2026).

- **App icon.** An Icon Composer file, `App/AppIcon.icon` (a sheet of paper with text lines, a
  yellow highlight and a red margin mark on a berry gradient, `#B4486A` to `#7E2742`, matching
  the raspberry accent; a near-black berry background, `#3A1E2A` to `#170C11`, in Dark Mode). It is a resource of the app target and `ASSETCATALOG_COMPILER_APPICON_NAME` names it;
  there is no `AppIcon.appiconset`. The system draws the Default, Dark, Clear and Tinted Home
  Screen styles from its layers. For the iPadOS 17 floor, Xcode flattens it into 1024 px Any,
  Dark and Tinted renditions in `Assets.car` plus `AppIcon60x60@2x.png` and
  `AppIcon76x76@2x~ipad.png` in the bundle.
- **Accent.** The accent is the reader's choice, from a fixed list of presets in Settings ▸
  Appearance (`AccentChoice` in `App/DesignSystem/Accent.swift`, stored under `settings.accent`):
  Raspberry (the default), Coral, Indigo, Viridian, Teal, Tobacco, Aubergine and Graphite. There
  is no free colour picker, because each preset is a hand-checked set of accent, accent tint and
  on-accent colours in both appearances. Raspberry is `#9C3656` in Light Mode and `#F4A3BE` in
  Dark Mode. The `AccentColor` asset holds the same raspberry; it is only the default and the
  tint of the launch frame before SwiftUI mounts. `AccentRoot` applies the choice at every
  window's root: `\.accentTheme` in the environment, `.tint`, and `UIWindow.tintColor` for UIKit
  surfaces (PDFKit selection, menus, alerts, the tool picker). It updates every open window live.
  Feature code reads `\.accentTheme` or the `.tint` shape style, never `Color.accentColor` or a
  static colour. Nothing in `App/` hard-codes another blue. Highlight colours, ink, the bookmark
  red, margin red, destructive red and book cloth are separate and do not follow the accent. The
  app icon stays berry whatever the choice.
- **Settings.** iPadOS has no system Settings entry for Marginal and there is no
  `Settings.bundle`, so preferences live in an in-app sheet (`SettingsView`). It opens from the
  Library's gear button and from "Settings…" (⌘,) in any window.
- **Text and icons on an accent fill use `accentTheme.onAccent`** (white in Light Mode, a deep
  shade of the accent's hue in Dark Mode, where every accent is light). This applies to
  `.borderedProminent` buttons, whose label the system draws white on any tint, and to the Pages
  grid's note/highlight flags. The toolbar's Markup toggle needs nothing: the system draws its
  selected glyph white on the light-mode accent and near-black on the dark-mode one.
  `DesignSystemTests` checks every preset in both appearances: accent text on the app's and the
  system's backgrounds and on the 15% selection fills, on-accent on the accent, and accent on its
  tint are all at least 4.5:1. The new presets are tuned to at least 5.0:1 (Light) and 5.6:1
  (Dark) against backgrounds. Raspberry keeps its original values: 4.88:1 at its lowest, on a 15%
  fill over the system grouped background.
- **Launch screen.** `UILaunchScreen` shows the `LaunchBackground` colour, `#F6F2EA` (light) and
  `#181612` (dark), with nothing on it. The first screen's background is the system one (white
  or `#F2F2F7` in Light Mode, black in Dark Mode), and the system cross-fades to it in about a
  quarter of a second; the two differ only slightly (1.0–1.16:1).

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
- **Handwriting to text in notes** (owner requirement; *confirmed working as is by the owner on
  14 November 2026, no further work planned*). Writing in a note with the Pencil and
  having it become typed text must work, and is treated as a feature to verify, not a side effect:
  - *Markup mode off:* Scribble works anywhere on the note page, including an empty note and the
    blank space below the text (the whole page is a writing target, not just the lines that
    already hold text), with the system's Scribble gestures (scratch out to delete, circle to
    select, tap and hold to insert).
  - *Markup mode on:* the Pencil inks by default, as designed. Where the system tool picker
    offers its handwriting tool (the Scribble pen, iPadOS 18 and later), choosing it writes typed
    text into the note while every other tool still inks; on older systems the reader leaves
    markup mode to Scribble.
  - Nothing in the note page may switch Scribble off, cover the text view with a view that
    swallows Pencil input outside markup mode, or steal its gestures. The reader's system setting
    for Scribble is respected.
  - The simulator cannot Scribble, so this is on the real-device checklist and is confirmed on
    the owner's iPad before it is called done.
- **Vector ink.** Ink is stored as PencilKit drawings (vector strokes), never as bitmaps, and is
  re-rendered from the strokes at the size it is shown: canvases stay sharp at any zoom, and
  read-only views (the Notebook) draw from the strokes at their display scale instead of
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
- **Testing.** Routine testing is on the iOS 27.0 simulator and the owner's iPad (iPadOS 27).
  An iOS 17.5 simulator runtime is installed (imported by the owner with `xcrun simctl runtime
  add`) and was used for every package until 13 November 2026; since then, by owner decision,
  iPadOS 17 is tested only occasionally. Its fallback paths are compiler-checked on every build
  and were last exercised on the packages merged up to that date (reader engine, library, note
  page, Notebook, search). Systems in between (18, 26) are covered by the compiler and review.

## Backup and restore

Added by the owner (15 November 2026). Everything a reader makes (notes, highlights, bookmarks,
their own headings, ink on pages and on notes) can be backed up and restored, with or without
the PDFs. This is backup, not sync: two iPads do not merge, and a restore replaces whole books.

- **What a backup is.** A snapshot archive, `*.ttbackup`, plus PDFs addressed by hash. The
  archive is a standard ZIP with every entry stored (no compression) and ZIP64, so it opens with
  any unzip tool: `manifest.json` (format version, date, device, and per book its record, its
  PDF's SHA-256 and size, counts, and every file with its size and SHA-256),
  `books/<bookID>/records.json`, the book's ink files and cover, and `pdfs/<sha256>.pdf` only
  when PDFs are embedded. A reader refuses a backup with a higher format version than it knows.
  A checked-in version 1 archive pins the format: a model change that would stop old backups
  restoring fails a test.
- **Two layouts.** A *single file* (PDFs embedded or not) for saving anywhere in Files. A
  *folder layout* for every folder-like destination: `Backups/<UTC time> <device>.ttbackup`
  (never with PDFs, so it stays small) and `PDFs/<sha256>.pdf`, written once per PDF and skipped
  when present. The newest 10 snapshots are kept; PDFs are never removed automatically.
- **Include PDFs is one choice** (owner decision, 15 November 2026). The backup-file switch,
  each destination's switch and the automatic backup's switch all show and change the same
  stored value, in every window at once, so a reader who has decided once is never caught out
  by another switch still set the other way. On by default. (Restore PDFs in the restore
  preview is a separate, per-restore choice.)
- **Not in a backup.** Window state, preferences and thumbnails. Backups are not encrypted by
  the app, except those to Tactile Texts Cloud (encrypted on the iPad; see below), and the
  Backup screen's footnote says which.
- **Destinations.** A file; a folder the reader picks in Files (for example in iCloud Drive),
  remembered across launches; the app's own iCloud container; Google Drive (the app can see only
  the files it creates); and an S3-compatible bucket the developer configures at build time (for
  example Cloudflare R2). The last three are switched on from `Config/Local.xcconfig` and are
  off, or reported as not available, in a build without them. **S3 credentials set at build
  time are compiled into the app and can be read out of it**: such a build is for the
  developer's own devices, with a token limited to one bucket, and is never distributed.
- **Linking PDFs by hash.** A book's identity is its sampled fingerprint, as before. A backup
  also records the SHA-256 of the whole PDF, kept beside the book in `document.sha256`. A book
  restored without its PDF is an ordinary book whose file is absent: the Library marks it
  "PDF missing" and offers Locate PDF…, and importing the right file by any route links it. A
  PDF is linked only when the fingerprint **and** the full SHA-256 match; a mismatch is refused
  with an explanation and there is no override (owner decision).
- **Converted books** (an EPUB, a comic, a document; see `FORMAT_IMPORT_PLAN.md`). The PDF the
  app generated is the book, so it is what "Include PDFs" backs up, and a restore with it gives
  the book back exactly. Three things differ from a book imported as a PDF:
  - *The kept original is not in a backup* (owner decision, 15 November 2026). It is the
    reader's own file, it can be as large as
    the PDF, and nothing reads it. A restored book therefore has no kept original, unless the
    restore replaced a copy on the same iPad, whose original is carried over (so is Undo Last
    Restore's). `conversion.json` (the text size) is small and is backed up.
  - *A missing PDF comes back in one of two ways.* The fingerprint of a converted book is that
    of the file it was made from, so Locate PDF… accepts that file and **converts it again**
    with the text size the book was made with; the prompt names the file and warns that pages
    can come out differently if iPadOS has changed since. It also accepts the generated PDF
    itself, which only the full SHA-256 can vouch for. Anything else is refused.
  - *Two separately converted copies are never merged.* The same file converted on two iPads,
    or with two text sizes, gives two PDFs whose pages need not match, and notes, highlights and
    ink are tied to pages. When this iPad's PDF is not the backup's, the preview leaves the
    book unticked, says why, and offers only Replace with Backup or Leave as Is.
- **Restore is per book, and an existing book is merged** (owner decisions, 15 November 2026;
  the first version could only replace). The preview lists each book in the backup as New or
  Already in Library (same ID or same PDF), with what each side holds. Every book is ticked; a
  book already in the Library is set to **Merge**, and a menu on its row switches it to Replace
  with Backup or Leave as Is (Leave as Is unticks it). The row says what the choice will do:
  for a merge, what it adds and combines, worked out from the backup before anything changes.
  - *Merge adds, and never removes.* The merged book keeps this iPad's ID, title, PDF and
    reading position. Everything the backup has that this iPad lacks is added; merging the same
    backup twice changes nothing the second time.
  - *Notes* are matched by the page or heading they are on. A note on both sides with different
    text is **combined**: paragraphs both sides have appear once, paragraphs only one side has
    are kept in order (this iPad's first), so an edited paragraph appears in both wordings.
    Handwriting from both sides is kept and stays with the paragraph it was written on;
    handwriting both sides put in the blank space after the text is placed one after the other.
  - *Ink on a page* is the union of both sides' strokes, each stroke once.
  - *Highlights* are matched by identity, and by same page, text and place; *bookmarks* by
    page; *headings the reader added* by identity, and by same title, page and parent (notes and
    sub-headings that point at a matched heading follow it). Where the two sides hold different
    versions of the same highlight or heading, this iPad's is kept: they carry no edit date.
  - *Deletions come back* (owner decision). A merge has no record of what was deleted here
    after the backup was made, so a note, highlight, bookmark, heading, pen stroke or paragraph
    that the backup still holds returns. The preview says so, and shows the counts a merge adds.
  - *Replace* swaps all of the book's notes, highlights and ink for the backup's, after a
    confirmation that names the book.
- **A restore can be undone.** Before a restore changes a book that is already in the Library
  (merge or replace), the app saves that book's notes and ink, without the PDF, inside its own
  storage, and keeps the newest five such copies. **Undo Last Restore** on the Backup screen puts
  those books back as they were and removes the books that restore added, after a confirmation
  that says work done on them since the restore will be lost. If the safety copy cannot be
  made, the restore stops with nothing changed.
- **Restore cannot leave a book half-applied.** The chosen books are extracted and every file
  verified first; a damaged backup restores nothing. Each book is then swapped in behind a
  journal, and a crash at any point is finished at the next launch, before the orphan sweep.
  Open reader and Notebook windows on a merged or replaced book close, as they do for a
  delete, and nothing they had pending is written over the restored book. A merge goes through
  the same commit: the merged book is built to one side, then swapped in.
- **One at a time.** One backup or restore runs for the whole app, with progress and Cancel in
  every window. Cancel is honoured until books are being swapped in.
- **Automatic backups** (owner decision: manual plus automatic). Off by default. When on, a
  backup to the chosen destination is due when the library has changed and the last success is
  at least a day old. It is checked when a window becomes active, every 15 minutes while the
  app stays in front, and from a background processing task scheduled when the app goes to the
  background (the system decides whether and when that runs). After a failure it waits an hour
  before trying again. The failure's message is shown, with the date of the last success.
- **Where it lives.** Settings › Backup & Restore, the menu bar's Back Up & Restore…, and a
  Restore from Backup… button in the empty Library. A `.ttbackup` file opened from Files (Open With, or
  Share) goes straight to the restore preview. There is no Library toolbar button for it.
## First-run onboarding

The app has three ideas a new reader will not guess: notes attach to a page or to a heading,
markup is a mode in which the Pencil writes and a finger still scrolls, and the PDF is never
changed. Onboarding teaches those three and nothing else. It never stands between the reader and
their own book: every step can be skipped, and skipping loses nothing that cannot be found again.

It has three parts, each optional.

### 1. Welcome sheet

- Shown once, on the first launch that lands on an empty Library. It is a sheet over the
  Library, not a full-screen takeover, so the app behind it is visible. A Library that already
  has books (an install from before onboarding existed) marks it as seen without showing it.
- One screen, no paging: the app name, a one-line description, and three rows (a note on every
  page and every heading; Pencil writes, finger scrolls; your PDFs stay untouched).
- Two actions: **Open the Quick Guide** (primary, captioned "Six short pages") and **Not now**.
  Swiping the sheet down counts as Not now.
- It is marked as seen the moment it appears, so a crash or force-quit never shows it twice.
- It is not shown when the first launch comes from "Open in" or a dropped PDF. That reader has a
  book in hand: the import proceeds, the sheet is marked as seen, and the Quick Guide stays
  one tap away in Settings.
- No permission prompts, no account, no settings. The app needs none of them to start.

### 2. Quick Guide

- A six-page PDF bundled with the app. Opening it imports it like any other book (copied into
  the container, listed in the Library) and opens it in the ordinary reader with Contents and
  the Notes panel showing. There is no tutorial mode and no overlay: the guide teaches by being
  a book the reader can try things on.
- One thing to try per page, three short paragraphs at most:

  | Page | Heading | What the reader tries |
  | --- | --- | --- |
  | 1 | 1.1 Start here | Scroll; read the page note that is already there; type in it. |
  | 2 | 1.2 Highlight a line | Select a sentence and pick a colour. One line is already highlighted. |
  | 3 | 2.1 Write on the page | Tap Markup, write with the Pencil, scroll with a finger, tap Done. |
  | 4 | 2.2 Notes for a page and a section | Switch to Section note; step up a level in the heading path. |
  | 5 | 3.1 Contents you build | Add heading at page 5; see it appear in Contents. |
  | 6 | 3.2 Notebook and export | Open the Notebook; ends with "Import your first PDF". |

- It arrives with a little content already in it, so the reader sees what a used book looks
  like before making anything: a page note on page 1 with ink over its text, a section note on
  "2 Writing", and one highlight on page 2. These are ordinary records. The reader can edit or
  clear them.
- Seeding happens only when opening the guide creates the book. Opening it again goes to the
  existing copy at its last-read page and never re-seeds or overwrites.
- The guide can be deleted like any book. Settings ▸ Help ▸ **Open the Quick Guide** brings it
  back, as new, with its seeded content (and opens the existing copy when there is one).
- The seeded ink is shapes generated in code (an underline, an arrow, a wavy line), not the
  handwriting the mockup shows.
- Leaving is the normal Back to Library. Nothing tracks whether the guide was finished.

### 3. Empty Library

- **Empty Library.** Whenever the Library has no books it shows "No Books Yet", **Import PDF**,
  **Open the Quick Guide**, and a line about dropping PDFs in. This is what a reader who tapped Not now sees, and what anyone sees after deleting
  their last book.
- There are no tips. A reader who skipped the guide finds it again under Settings ▸ Help ▸
  **Open the Quick Guide**, and the Contents sidebar of a book with no outline already says how
  to add headings.

### Rules that hold throughout

- **State.** "Welcome seen", the guide's book ID are per-device
  preferences (`OnboardingState`), not SwiftData records.
- **Narrow width.** The welcome sheet becomes a page sheet and its content scrolls. The guide
  opens with Contents closed and the notes sheet at its medium detent.
- **Accessibility.** The welcome sheet scrolls at large Dynamic Type sizes with both actions
  still reachable; VoiceOver reads title, the three rows, then the actions; nothing in onboarding
  is animated beyond the system sheet and popover transitions.
- **Tests.** `-resetState`, which every UI test starts with, also switches onboarding off and
  keeps it off for that test's later relaunches, so the welcome sheet never interferes
  with another feature's test. `-onboarding reset` forgets all onboarding state (with
  `-resetState`: a true first launch) for the onboarding tests themselves; `-onboarding skip`
  switches onboarding off without touching the library, for screenshots.

## Tactile Texts Cloud (the paid backup service)

Added by the owner (15 November 2026). An optional subscription that keeps the reader's backups
in the owner's Cloudflare R2 bucket. It is one more backup destination: the engine, the
snapshot format, restore, and automatic backups are the ones above. It is absent from a build
whose `BACKUP_SERVICE_HOST` and `BACKUP_PRODUCT_IDS` settings are empty, which is the default.

- **Why there is a server.** A long-lived storage key can never ship in an app (see the
  build-time S3 destination above). A small Cloudflare Worker (`Backend/backup-worker/`) decides
  who may write where and hands the iPad **temporary R2 credentials**: they last 15 minutes,
  reach one bucket and only that user's folder, and allow only the operations the user's
  standing permits. Backups then travel directly between the iPad and R2; no file data passes
  through the Worker. The Worker makes the credentials itself by signing with a parent R2 token
  it keeps as a secret, so issuing them costs no call to Cloudflare, and revoking the parent
  token ends every credential made from it.
- **Identity is the App Store subscription** (owner decision). There is no account, sign-in,
  email address or password. The iPad sends the signed subscription transaction Apple gave it;
  the Worker checks Apple's signature chain to a pinned Apple root, the bundle ID, the product
  and the environment. The user's folder is `users/<HMAC-SHA256(server secret, original
  transaction ID)>/`, so Restore Purchases on a new iPad finds the same backups. App Store
  Server Notifications keep the Worker's record current for renewals, expiry and refunds.
- **That it is the real app.** App Attest: each install registers a device key once and signs
  every request for credentials with it, so a copied subscription transaction alone cannot be
  used from a script. The simulator has no App Attest; only the Worker's `dev` deployment
  accepts a bypass, and the production deployment refuses to serve if the bypass is configured.
- **Encrypted on the iPad** (owner decision). Everything is encrypted before upload; the owner
  and Cloudflare hold only unreadable data. `EncryptedBackupDestination` (ReaderBackup) wraps a
  plain object store, so the engine is unchanged. Files are AES-256-GCM in 4 MiB chunks with the
  chunk position and a last-chunk mark authenticated, so tampering, reordering and truncation
  are detected; each file has its own key derived from the master key. Object names give
  nothing away: a PDF is named by a keyed hash of its SHA-256 (a well-known book cannot be
  recognised), and a snapshot keeps only its timestamp in the clear, with the device name
  encrypted. Sizes and times remain visible to the operator. The plaintext SHA-256 check on
  restore is unchanged.
- **The key.** A random 256-bit key in the Keychain, carried to the reader's other devices by
  iCloud Keychain, plus a **recovery key** (56 characters in 14 groups of 4, with typo
  detection) the reader can save. A small key-check object in the user's folder tells "wrong
  key" apart from damage. A device that finds backups but has no key asks for the recovery key
  and **never makes a new key while data exists**, because the key may simply not have arrived
  from iCloud Keychain yet. A reader who loses both the Keychain key and the recovery key
  cannot restore; nobody can.
- **When a subscription ends** (owner decision). Apple's grace and billing-retry periods count
  as subscribed. After the end: 30 days of read-only access (restore, no upload); then no
  access with the data kept, and resubscribing restores it; 60 days after the end a daily job
  deletes the folder. A refunded or revoked subscription gets no read-only period. Both periods
  are Worker settings.
- **Storage allowance.** Each product has an allowance in the Worker's settings. Usage is
  counted when credentials are issued (cached for five minutes); over the allowance the iPad
  gets credentials that can read and delete but not upload, and is told so. Credentials are
  bearer tokens for 15 minutes and R2 does not cap object size, so the allowance is enforced
  between sessions, not within one.
- **Deleting.** Delete My Cloud Backups empties the user's folder and the Worker's record of
  them, then removes the key from the Keychain (on every device, since it is synchronised).
- **Where it lives and what the reader sees.** The service is the last row under Destinations on
  the Backup screen, and opens its own page (not the generic destination page). Not subscribed:
  an offer saying what it is, the price and period from the App Store, that backups are
  encrypted on the iPad and nobody else can read them, why the recovery key matters, what
  happens when a subscription ends, Subscribe, Restore Purchases, and Terms of Use and Privacy
  Policy links (`BACKUP_TERMS_URL`, `BACKUP_PRIVACY_URL`; a link left empty is not shown).
  Subscribed: the plan, usage against the allowance, the renewal or end date, the last backup,
  Back Up Now, the backups (each opens the restore preview), Manage Subscription and Delete My
  Cloud Backups. Every state other than plain active has a banner saying what still works and
  until when, with the service's own dates (read-only, over the allowance, lapsed, refunded,
  deleted, needs the recovery key, not reachable with Try Again). The first backup, which makes
  the key, is followed by the recovery key (14 groups, monospaced, selectable, Copy, Share or
  Save…) and "I’ve Saved It"; a quiet reminder stays on the page until then. Enter Recovery Key
  accepts any case, spaces and dashes and names each mistake; when the iPad has no key at all it
  says first that the key may still be on its way through iCloud Keychain, with Try Again. "I’ve
  lost my recovery key: start over" there deletes everything, with a stronger warning: it is the
  only way to a new key. Delete My Cloud Backups says the subscription is not cancelled and
  points to Manage Subscription.
- **Testing without Apple or Cloudflare accounts.** The Worker's tests run in the Workers
  runtime with generated certificates; the app's tests use a StoreKit configuration file
  (`Config/Marginal.storekit`) and fakes. Purchases made in the sandbox, TestFlight or Xcode are
  kept apart from paying users' data, under `sandbox/`, with a 100 MB allowance. The UI tests
  launch debug builds with `-cloudBackupUITest <state>`, which builds the service from fakes in
  the app's debug code (a scripted StoreKit, a fake Worker and a folder standing in for R2); none
  of it is in a release build.

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
| Scenes | SwiftUI `WindowGroup`s: Library, and value-based groups for a reader and a Notebook keyed by book ID; one `ReaderSession` per awake reader screen (`ReaderSlot`); `@SceneStorage` or a user activity for restoration | Multiple windows, state restoration and "Open in New Window" from system APIs. |
| Reading position | `Book.lastReadPageIndex` plus the exact place and zoom in `UserDefaults` (`ReaderPositionStore`), used only while its page matches the stored one | One latest position for every reader on a book without a schema change; a restore or merge that moves the page wins. |
| Shared data across windows | One `ModelContainer` for the app, read on the main actor by every window; an in-process change hub announces ink and note-ink writes (book, page or note ID) so other windows reload that surface | SwiftData observation keeps structured data in step; ink lives in files and needs its own signal. |
| Drawing policy | `PKCanvasView.drawingPolicy = .default`, with the shared system `PKToolPicker` | Honours the reader's Pencil settings instead of overriding them. |
| Vector ink | `PKDrawing` data on disk; live `PKCanvasView` rendering; exports stroke paths as vector | Sharp at any zoom and in exported PDFs. |
| Backup format and network code | Three Foundation-only packages beside `ReaderCore`: `ReaderBackup` (archive, hashing, manifest, folder layout, restore plan), `GoogleDriveKit` (OAuth with PKCE, Drive REST), `S3Kit` (Signature Version 4, object operations); the app holds the engine, the destinations' app side and the UI | The format and every network request are tested with `swift test` on the Mac in seconds, against published test vectors and stubs, with no account needed. |
| Cloud backup service | A Cloudflare Worker (TypeScript, D1, a daily cron) that verifies the App Store subscription and App Attest and issues 15-minute R2 credentials limited to one user's folder; the iPad talks to R2 directly with `S3Kit` and encrypts with `ReaderBackup` | The only server code is the part that must hold a secret. File data never passes through it, so it stays small and cheap, and the storage holds nothing readable. |
| PDF content hash | A sidecar file `Books/<bookID>/document.sha256`, not a database column | No SwiftData migration touches the reader's data; the directory is already removed with the book. |
| Quick Guide | A PDF generated by `scripts/make-guide.swift` and committed at `App/Resources/Tactile Texts Quick Guide.pdf` (the file name is the book's title), imported through the normal import path; seeded notes, highlight and ink written through the repositories | The guide exercises the same code as a reader's own book, and the existing "same file opens the existing book" rule prevents duplicates. |
| Onboarding state | `UserDefaults` keys for "welcome seen", the guide's book ID | Device-local and trivially reset by the `-onboarding` launch argument; nothing to migrate. |
| Dependencies | None beyond Apple frameworks | |

Agents must check every Apple API named here against the installed SDK's documentation before
building on it. This table records intent, not verified signatures.

## Importing other formats

Added by the owner on 15 November 2026; the plan and its decisions are in
`docs/FORMAT_IMPORT_PLAN.md`. Books and documents that are not PDFs are converted to a PDF **once,
at import**, and from then on are ordinary books with every feature a PDF has.

- **What converts:** reflowable EPUB 2 and 3 without DRM; comic archives (CBZ, or a ZIP of
  pictures) and images; plain text, Markdown, HTML and web archives; Word, RTF and Pages
  documents; PowerPoint and Keynote presentations (one slide per page). Which of these a build
  accepts follows the converters it has; Settings ▸ Supported Formats lists them.
- **Ask first.** Any import that includes a file needing conversion shows one Convert to PDF sheet
  first, every time, saying what converting costs; Cancel leaves the Library and the disk as they
  were. Settings ▸ Supported Formats shows the same limitations at any time.
- **Not supported:** DRM-protected books (Kindle, Apple Books, Adobe DRM), Kindle MOBI and AZW3,
  DjVu, CBR (RAR) comics, fixed-layout EPUB and spreadsheets. The app names the kind of file when
  one is chosen.

## Not in version 1

iCloud sync (backup and restore to iCloud exist, see "Backup and restore"; keeping two devices in
step does not), collections or tags in the Library, OCR for scanned books, handwriting search,
automatic heading detection from page text, an in-window split of two pages or two books (two
windows cover this), sharing single notes, PaperKit shapes and text boxes on the page, and the
formats listed under "Importing other formats" ▸ Not supported (DRM-protected books, Kindle MOBI
and AZW3, DjVu, CBR, fixed-layout EPUB, spreadsheets). The store layout should not rule these out.

## Open questions for the owner

1. ~~App name and bundle identifier.~~ Settled: the app is "Tactile Texts", bundle identifier
   `software.tactile.marginal`.
2. Notes are plain text under the ink in version 1 (no bold, lists are typed dashes). Rich text
   changes line heights mid-note and makes ink anchoring harder; is plain text acceptable?
3. Should exporting an annotated PDF copy of the book (WP11) be in version 1?
4. The Quick Guide mockup shows handwritten words in the seeded note ("like this!"). The build
   seeds shapes generated in code; real handwriting has to be written once on an iPad by the
   owner and bundled. Does the owner want to supply it?
