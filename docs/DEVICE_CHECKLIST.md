# Tactile Texts: real-device checklist

For the owner, on the iPad with an Apple Pencil and a hardware keyboard. None of this can be
checked on the simulator (no Pencil, no hover, no squeeze, no palm, no Scribble). One sitting,
about 30 minutes, plus about 15 for "Importing other formats". Import `small.pdf`, `large.pdf` and `no-outline.pdf` first (Files › Open in, or
drag onto the Library). Tick each box; note anything that fails with the book, page and window
arrangement.

Pencil settings to start from: Settings › Apple Pencil › "Only Draw with Apple Pencil" **on**,
Scribble **on**, double-tap and squeeze set to their defaults.

## Pencil on the page

- [ ] **Pressure.** In markup mode, a pen stroke pressed lightly then hard gets visibly thicker.
- [ ] **Tilt.** The pencil tool shades wider when the Pencil is tilted.
- [ ] **Hover** (Pencil 2 / Pro on a supported iPad). Holding the Pencil just above the page in
      markup mode shows the tool's hover preview; nothing is drawn until the tip touches.
- [ ] **Double-tap / squeeze.** Double-tap (or squeeze on Pencil Pro) does what Settings says
      (switch to eraser, or show the palette), on the page and on a note.
- [ ] **Palm rejection.** Rest the hand on the page while writing: no stray marks, no scrolling.
- [ ] **Finger scrolls in markup mode.** With markup on, one finger scrolls the book and two
      fingers pinch-zoom; neither leaves a stroke.
- [ ] **Sharp ink when zoomed.** Zoom in six steps (⌘+): strokes stay sharp, not pixelated.

## Pencil on a note

- [ ] **Palm on the page beside the note.** With the notes pane widened, write on the note
      while the palm rests on the PDF page: the note gets ink, the page gets none and does not
      scroll.
- [ ] **Scribble, markup off.** With markup mode off, write a word with the Pencil anywhere on
      the note, including the blank space below the text and on an empty note: it becomes typed
      text. Scratch out deletes, circle selects.
- [ ] **Scribble pen, markup on** (iPadOS 18 and later). Choose the picker's handwriting tool: it
      types into the note; every other tool inks.
- [ ] **Page to note without the tool changing.** Choose the marker in yellow, draw on the page,
      then on the note, then on the page again: the same tool and colour throughout.
- [ ] **Ink follows text.** Draw a circle round a word on line 2 of a note, then type a new
      paragraph above it: the circle moves down with its word.

## Undo and redo

- [ ] **Tool picker's own Undo/Redo follow the surface last drawn on.** Draw on the page, then
      on the note: Undo removes the note stroke first; draw on the page again: Undo removes that
      page stroke. Repeat with a second page (scroll to it, draw, undo).
- [ ] **Second window.** Open the same book in a second window (⌥⌘N), draw in each: each
      window's Undo acts on its own last stroke only.
- [ ] **⌘Z / ⇧⌘Z** with the hardware keyboard do the same as the picker's buttons in markup
      mode, and undo typing while a note has the text cursor.
- [ ] **Narrow window.** In Slide Over or a narrow Split View, the toolbar shows Undo/Redo in
      markup mode (the picker has none there) and they act on the last surface drawn on.

## Keyboard

- [ ] **⌘A in the reader** with a word selected selects its paragraph only (never the book);
      a second ⌘A grows no further. ⌘A inside a note selects the note's text.
- [ ] **Edit › Select All** from the menu bar does the same.
- [ ] Hold ⌘ to see the shortcut list: nothing is listed twice, and ⌘[ / ⌘] step the section
      history.

## Section history and links

- [ ] **Links in a real textbook behave like Contents** (TSOFT-214, TSOFT-220). In a real
      textbook (one exported by a publisher and, if you have one, a LaTeX/hyperref PDF), scroll
      partway into a section and tap a link in the text that goes to another section (a figure,
      a glossary term, "see Section…"). Back returns to the same spot in the same section;
      Forward goes to the link's target again; press and hold Back / Forward lists the two
      places by section and page, as after choosing a heading in Contents. Repeat link → link →
      Back → Back. A web link opens outside the app and adds nothing to the history.

## Text, highlights and notes

- [ ] **Highlights by finger.** Markup off: long-press a word, drag the handles, choose
      Highlight › a colour. Tap the highlight: recolour and delete work. (In markup mode the
      Pencil highlighter is the way; text selection is off by design.)
- [ ] **Delete Note.** In the notes pane header, Delete Note asks first, then clears the note and
      its handwriting; the page's ink and highlights stay. Same from a note row's context menu in
      the Notebook.
- [ ] **Level picker.** On the Section note tab, the row at the bottom of the pane names the
      heading; tap it (finger, then the pointer: the row highlights under it) to list the
      heading path, choose the chapter, and its note shows. Collapse or expand it, quit the app
      and reopen: it is as you left it. VoiceOver reads the row with "Collapsed" or "Expanded".
- [ ] **Pinching the note.** Pinch a note to zoom it (100% to 200%), then change the text size
      (Settings › Display & Brightness › Text Size): the note returns to the zoom that follows the text size.
- [ ] **Sliding the notes handle shut.** Drag the pane's handle towards the edge past its
      narrowest width: the pane follows the finger and snaps shut on release; the toolbar's
      notes button brings it back at the old width. The reading position does not move.
- [ ] **Headings on a book with no outline.** On `no-outline.pdf`, add a heading from the empty
      Contents, another from the text-selection menu (Add as Heading), one from More › Add Heading
      at This Page; rename one, move one to another page, delete one.

## Notebook

- [ ] **Handwriting rows.** Draw on two pages of a book: the Notebook lists both pages as
      "Handwriting" rows with a preview of the ink on the page; the Handwriting filter shows only
      them; tapping one opens the reader at that page; erasing all the ink on a page removes its row.
- [ ] **Heading-note rows** open the reader with that heading's note in the notes pane.
- [ ] **Export.** Markdown and PDF export from the Notebook save to Files and open there; the PDF
      shows notes with their ink and the handwriting previews.

## Importing other formats

Have a real EPUB (a DRM-free one, for instance from Project Gutenberg or Standard Ebooks) and a
real comic archive (a `.cbz` of 100 pages or more) in Files, and one of each in a Mail message to
yourself. `Fixtures/out/small.epub` and `small.cbz` (from `scripts/fixtures.sh`) do for a first pass.

- [ ] **Files picker shows the formats.** Library › Import: EPUB, CBZ, images, Markdown and the
      other formats in Settings › Supported Formats can be chosen (not greyed out); a `.mobi` or
      `.cbr` is either greyed out or, when chosen, listed under "Can't Be Imported" with its reason.
- [ ] **Convert a real EPUB.** Import it: the Convert to PDF sheet shows the common block and the
      EPUB block; Convert. The Library stays responsive while it converts (scroll, open another
      book). The book opens with the cover and title from the EPUB, Contents is the book's own table
      of contents and each entry lands on its heading's page, text can be searched and highlighted,
      and the Library's book menu and the reader's More menu say "Converted from EPUB".
- [ ] **The first-conversion stall.** On the first conversion after launching the app, note any
      pause or hitch when it starts (the web view starts up then) and how long it lasts: the
      Library should still scroll. Note the book, its size and the seconds it took to convert.
- [ ] **Convert a real comic.** Import the comic: pages are in reading order (page 2 before page
      10), the page count matches the number of pictures, and the menus say "Converted from a comic
      archive".
- [ ] **Memory during a large comic.** While a comic of a few hundred MB converts, Xcode's memory
      gauge (Debug navigator, with the app run from Xcode) stays roughly flat rather than growing
      with the comic's size; note the peak.
- [ ] **Ink on a converted page survives relaunch.** In the converted EPUB and the comic, draw on a
      page with the Pencil, quit the app (swipe it away), reopen: the ink is in place on the same
      page.
- [ ] **"Open in" from Files and from Mail.** In Files, share an EPUB › Tactile Texts; in Mail,
      touch and hold a `.cbz` attachment › Share › Tactile Texts: the app opens, shows the Convert
      to PDF sheet in that window, and after Convert opens the book.
- [ ] **A drop from Files.** In Split View with Files, drag an EPUB (and, in a second try, an EPUB
      and a PDF together) onto the Library: one sheet for the EPUB; the PDF imports without waiting.
- [ ] **Cancel leaves nothing.** Import an EPUB and choose Cancel: no book appears, and Settings ›
      General › iPad Storage › Tactile Texts shows no growth in Documents & Data.

## Appearance and accessibility

- [ ] **Markup toggle with VoiceOver.** VoiceOver reads the toolbar's Markup button as "Markup"
      (not selected) and, after a double-tap, "Done with Markup" with "selected"; double-tap
      again leaves markup mode.
- [ ] **Dark Mode.** The book page stays white; the note page turns dark with light text, and
      black ink shows light on it; back in Light Mode the ink is black again.
- [ ] **Tool picker swatches over the white page in Dark Mode.** Look at the picker's colour
      swatches and the stroke preview while drawing on the white book page in Dark Mode.
      *Open owner decision:* should the picker use its light style while a white book page is
      the target (`toolPicker.colorUserInterfaceStyle`)? Today it follows the system appearance.
      Note what you see and decide.

## Icon, accent and launch screen

- [ ] **Home Screen icon in every style.** Touch and hold the Home Screen › Edit › Customize, and
      look at Tactile Texts in Default, Dark, Clear (light and dark) and Tinted (try a strong
      tint colour): the sheet, its folded corner, the text lines, the yellow highlight and the red
      margin mark are all there, nothing is clipped at the rounded corners, and the glass edges
      look right. In Clear and Tinted the highlight and margin mark turn faint grey (seen on the
      simulator): decide whether that is acceptable.
- [ ] **Small icons.** The icon in the dock, the App Library, Spotlight, Settings › Apps and the
      app switcher is sharp and recognisable at its small size.
- [ ] **Launch screen.** Quit the app (swipe it away in the app switcher) and open it, in Light
      Mode and then in Dark Mode: the launch screen is plain warm off-white (`#F6F2EA`) or warm
      near-black (`#181612`) with nothing on it, and it fades into the first screen without a
      flash of white, black or another colour.
- [ ] **Accent on the device's display.** In both appearances the raspberry accent reads well:
      toolbar icons, the Contents sidebar's current heading, the Resume button (white text in
      Light Mode, black in Dark Mode), the Pages grid's note and highlight flags, and the filled
      Markup toggle.

## Install

- [ ] **7-day expiry.** The build is signed with a free Personal Team profile, so it stops
      launching seven days after it was installed. Reinstall from Xcode (`scripts/device.sh`)
      before then; reinstalling keeps the library and notes.
