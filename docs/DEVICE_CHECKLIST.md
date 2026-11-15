# Tactile Texts: real-device checklist

For the owner, on the iPad with an Apple Pencil and a hardware keyboard. None of this can be
checked on the simulator (no Pencil, no hover, no squeeze, no palm, no Scribble). One sitting,
about 30 minutes. Import `small.pdf`, `large.pdf` and `no-outline.pdf` first (Files › Open in, or
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

## Backup and restore

The simulator tests cover the archive, the restore and its crash recovery, and every
destination against stand-ins. They cannot cover real Files providers, the Keychain, background
runs or very large files. Open Settings › Backup & Restore.

- [ ] **Backup file, without PDFs.** Save Backup File… with Include PDFs off, into "On My
      iPad". The file appears in Files with the `.ttbackup` extension and is a few megabytes.
- [ ] **Backup file, with PDFs, large.** With `large.pdf` and a real textbook in the Library,
      save with Include PDFs on. Progress moves, Cancel works part-way (no file is left behind),
      and a second attempt completes. If the iPad is short of space, the app says so before
      starting instead of failing part-way.
- [ ] **A file over 4 GB.** If the Library is large enough, a single-file backup over 4 GB
      saves and then restores. (Only a forced test covers this size on the simulator.)
- [ ] **Open With, backup.** In Files, touch and hold a `.ttbackup` file › Open With › Tactile
      Texts: the app opens on the restore preview for it. The same from Share › Tactile Texts,
      and from a file in iCloud Drive. Afterwards the file is still where it was in Files.
- [ ] **Open With, PDF.** In Files, touch and hold a PDF › Open With › Tactile Texts: the book
      is imported and opens. The PDF is still where it was in Files. Doing it again opens the
      same book without importing a second copy.
- [ ] **Restore replaces, per book.** Change a note, then restore the earlier backup: the book
      shows as Already in Library and unticked; ticking it warns that its notes will be replaced;
      after restoring, the note is the earlier one and ink on pages and notes is intact.
- [ ] **A book open during restore.** With a book open in a second window and a note half
      typed, restore that book from a backup: the window closes and the restored note is the
      backup's, not the half-typed one.
- [ ] **Delete and reinstall.** Back up with PDFs to a folder in iCloud Drive, delete the app,
      install it again (`scripts/device.sh`), choose the same folder, and restore: every book,
      note, highlight, bookmark, heading and drawing is back, and each book opens at the page
      it was on.
- [ ] **PDF missing, then linked.** Restore a backup made without PDFs into an empty Library:
      each book shows "PDF missing". Locate PDF… with the right file links it and the cover
      appears; with a different PDF it is refused with an explanation and nothing changes.
      Dropping the right PDF onto the Library also links it.
- [ ] **Folder in iCloud Drive.** Choose Folder… and pick a folder in iCloud Drive; Back Up
      Now; the files appear under `Backups/` and `PDFs/` in Files and on another device. Quit
      and relaunch, then restart the iPad: the folder is still remembered each time.
- [ ] **A backup that is only in iCloud.** On a second device, or after the system has evicted
      the local copy, the backup is still listed and restoring it downloads it first. In
      Aeroplane Mode the app reports that it cannot be downloaded instead of hanging.
- [ ] **Folder gone.** Delete or rename the chosen folder in Files: the destination says to
      choose the folder again and does not recreate it.
- [ ] **Another provider's folder.** Try Choose Folder… on the Google Drive app's location in
      Files. Note whether a folder can be picked at all; if not, that is expected.
- [ ] **Automatic backup.** Turn it on for the iCloud Drive folder, make a note, and leave the
      iPad for a day (on power overnight): the status line shows a backup with a new date. Make
      no change the next day: no new backup appears.

Only once the account side exists (see `Config/Local.xcconfig.example`):

- [ ] **iCloud container** (paid developer team). The destination is available, "Tactile Texts"
      appears in Files › iCloud Drive, and a backup made on one device is listed on another.
- [ ] **Google Drive** (OAuth client ID). Sign In… shows Google's page and returns to the app;
      this is the first real test of the redirect scheme. Back Up Now creates "Tactile Texts
      Backups" in Drive; a large PDF uploads and survives a brief loss of network; restoring on
      a fresh install works; Sign Out removes access. Quit and relaunch: still signed in (the
      Keychain has never been exercised on the simulator).
- [ ] **S3-compatible bucket** (for example Cloudflare R2). The destination appears under the
      configured name; Back Up Now uploads a snapshot and a PDF of several hundred megabytes;
      the objects are under `Backups/` and `PDFs/` in the bucket; restore works; a wrong key
      and a wrong device clock each give a clear message.

## Install

- [ ] **7-day expiry.** The build is signed with a free Personal Team profile, so it stops
      launching seven days after it was installed. Reinstall from Xcode (`scripts/device.sh`)
      before then; reinstalling keeps the library and notes.
