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
| Quick Guide | A PDF generated by `scripts/make-guide.swift` and committed at `App/Resources/Tactile Texts Quick Guide.pdf` (the file name is the book's title), imported through the normal import path; seeded notes, highlight and ink written through the repositories | The guide exercises the same code as a reader's own book, and the existing "same file opens the existing book" rule prevents duplicates. |
| Onboarding state | `UserDefaults` keys for "welcome seen", the guide's book ID | Device-local and trivially reset by the `-onboarding` launch argument; nothing to migrate. |
| Dependencies | None beyond Apple frameworks | |

Agents must check every Apple API named here against the installed SDK's documentation before
building on it. This table records intent, not verified signatures.

## Not in version 1

iCloud sync, collections or tags in the Library, EPUB, OCR for scanned books, handwriting search,
automatic heading detection from page text, an in-window split of two pages or two books (two
windows cover this), sharing single notes, PaperKit shapes and text boxes on the page. The store layout should not rule these out.

## Open questions for the owner

1. ~~App name and bundle identifier.~~ Settled: the app is "Tactile Texts", bundle identifier
   `software.tactile.marginal`.
2. Notes are plain text under the ink in version 1 (no bold, lists are typed dashes). Rich text
   changes line heights mid-note and makes ink anchoring harder; is plain text acceptable?
3. Should exporting an annotated PDF copy of the book (WP11) be in version 1?
4. The Quick Guide mockup shows handwritten words in the seeded note ("like this!"). The build
   seeds shapes generated in code; real handwriting has to be written once on an iPad by the
   owner and bundled. Does the owner want to supply it?
