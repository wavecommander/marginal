# Tactile Texts: differences from the mockups

WP12, 14 November 2026. Every mockup artboard was screenshotted on the iOS 27.0 simulator
(`Marginal-A`, iPad Pro 11-inch (M5), landscape unless stated), in Light and Dark Mode, by
`UITests/MockupScreenshotUITests.swift` (reader states on `no-outline.pdf` seeded with
`-seedNotebook -seedNotebookPageInk`, whose user headings, notes, highlights and ink mirror the
mockups' page 312). The screenshots are in `docs/mockup-shots/` (`<artboard>.jpg` and
`<artboard>-dark.jpg`, downscaled); regenerate full-size PNGs with

    MARGINAL_SIM=<udid> scripts/test.sh --skip-packages -only-testing:MarginalUITests/MockupScreenshotUITests
    # Dark: xcrun simctl ui <udid> appearance dark, then shut the simulator down and boot it
    # again (on this iOS 27 simulator the setting took effect only after a reboot), then the
    # same command with TEST_RUNNER_MOCKUP_SUFFIX=-dark

The reader shots in `docs/mockup-shots/` were taken before the notes panel layout change
(TSOFT-217 and TSOFT-218, 14 November 2026: no zoom button, no "This page is in" or "Page notes
in this section", the level picker at the bottom); the tables below describe the app after it.

Each difference is **intentional** (the DESIGN.md rule that overrides the mockup is cited) or
**open** (not decided or not done). The fixture's text and page numbers differ from the
mockups' sample book by construction and are not listed.

## Everywhere

| Difference | Status |
| --- | --- |
| The app is called **Tactile Texts** (menu bar, Home Screen); the mockups have no app name. | Intentional: DESIGN.md opening paragraph. |
| Navigation bars, toolbars, segmented controls, sheets and menus are the system's own (iPadOS 27 glass toolbar groups, chevron-only back button whose accessibility label is "Library"), not the mockups' drawn approximations. | Intentional: "System controls … should be the real system ones"; "System chrome". |
| The tool palette is the system `PKToolPicker` (on iPadOS 27 it opens as the compact floating palette in the corner), not the drawn pen/highlighter/eraser/lasso/colour bar. | Intentional: "Apple Pencil › Defer to the system". |
| Dark Mode: every screen follows the system appearance; the PDF page stays white; the note page turns dark (dark paper, light text, ink re-rendered by PencilKit). The mockups are light only. | Intentional: "The notes pane follows the system appearance". |

## Library (`library.jpg`)

| Difference | Status |
| --- | --- |
| Import is a "+" toolbar button and sort is a "⇅" menu, not a text "Import PDF" button and a "Recently opened" label. | Open (cosmetic): both are labelled for VoiceOver ("Import PDF", "Sort"); the mockup's text buttons would be a toolbar style change. |
| Covers are the PDF's first page, not typographic covers. | Intentional: WP3 "cover thumbnail from page one". |
| The Continue reading card says "Page 312 of 1,500" (and the note/highlight count when there are any) but not the section ("5.2 The Characteristic Equation · …"). | Open: the card has no outline loaded; showing the section needs the book's outline at Library time. |
| Reading progress is a bar under each cover; the mockup draws a percentage ring on the cover. | Open (cosmetic). VoiceOver reads "N percent read" either way. |

## Reader · page note (`reader-page-note.jpg`)

| Difference | Status |
| --- | --- |
| Toolbar adds section history Back and Forward after the Contents button. | Intentional: "Section history". |
| The notes panel header adds Delete Note (trash). It has no zoom button: the note is zoomed by pinching it. | Intentional: "Deleting a note"; "Writing room"; "Notes panel layout" (TSOFT-217). |
| There is no "This page is in" list under the note; "Highlights on this page" is the only thing under it, and with no highlights on the page the note takes the whole panel. | Intentional: "Notes panel layout" (TSOFT-217). |
| Contents rows mark the reader's own headings with a person badge, and show the note badge as an icon beside the page number. | Intentional: "The reader's own headings … marked as the reader's own wherever they are listed". |
| "Highlights on this page" was missing from the Page note tab whenever the page had highlights. | **Fixed in WP12** (`NotesHighlightsSection` loaded its rows from a `.task` on an empty `Group`, which never ran); covered by `JourneyUITests`. |
| "Add Heading at Page N" is title case. | Intentional (system title case for buttons). |

## Reader · section note (`reader-section-note.jpg`)

| Difference | Status |
| --- | --- |
| The level picker is not above the heading's title: it is a collapsible row at the bottom of the panel, above "Open in Notebook", that names the shown heading and starts collapsed; expanded, it lists the heading path. | Intentional: "Notes panel layout" (TSOFT-218). |
| There is no "Page notes in this section" list; the Notebook lists a section's page notes. | Intentional: "Notes panel layout" (TSOFT-218). |

## Markup with Apple Pencil (`markup.jpg`)

| Difference | Status |
| --- | --- |
| No Done button and no toolbar Undo/Redo; the Markup toggle is filled while on and the rest of the toolbar is unchanged. Undo/Redo are the tool picker's. | Intentional: "Markup controls". |
| The subtitle reads "Markup · 5.2 …" as in the mockup. | Matches. |

## Markup · page and note together (`markup-page-and-note.jpg`)

| Difference | Status |
| --- | --- |
| Widening the panel by its handle zooms the note (to about 183% in the shot after a long drag; the mockup shows 140%); the shrink button appears in the header beside Delete Note. | Matches the rule ("Writing room"); the zoom depends on the width. |
| Same toolbar differences as Markup. | Intentional: "Markup controls". |
| The system picker's compact palette floats in the bottom-right corner, over the bottom of the notes pane. | Open (cosmetic): the reader can drag the palette to another corner; the app does not position it. |

## Reader · section note in portrait / notes sheet (`portrait-notes-sheet.jpg`)

| Difference | Status |
| --- | --- |
| The sheet's title is "Page 25" rather than "Page 312 in 5.2 The Characteristic Equation". The section is in the toolbar subtitle and on the Section note tab. | Open (cosmetic). |
| No "Close notes" button in the sheet; it closes by dragging it down or with the toolbar's notes button. | Open: DESIGN.md asks only for medium and large detents with background interaction. |
| The page pill sits at the top of the page in portrait (at the bottom in landscape). | Open (cosmetic): it moves out of the sheet's way. |

## Notebook (`notebook.jpg`)

| Difference | Status |
| --- | --- |
| The type filter has a fifth segment, "Handwriting", and pages with ink appear as Handwriting rows with a preview of the page and its ink. | Intentional: "Ink is navigable like highlights and bookmarks" (Notebook only). |
| Filter titles are title case ("Section Notes"). | Intentional (system segmented control style). |
| The back button is the system one; the toolbar adds "Open Book" beside Export. | Intentional: "System chrome"; Notebook rows and the book are one tap from the reader. |
| Note rows offer Delete Note (context menu and VoiceOver action); a heading note's row opens the reader with that note in the notes panel. | Intentional: "Deleting a note"; "Notebook rows open the reader at that page or heading". Added in WP12. |
| The search field's placeholder is cut off ("Search Notes and High…") at this window width. | Open (cosmetic): a shorter prompt ("Search Notebook") would fit. |
| In Dark Mode the handwriting previews show the book page white, as in Light Mode. | Intentional: "PDF pages stay as the PDF draws them". |

## Dark Mode (`*-dark.jpg`)

| Difference | Status |
| --- | --- |
| The book page stays white in every screen, including page previews in the Notebook; the note page, the notes pane, the sidebar and the Notebook are dark. | Intentional: "The notes pane follows the system appearance". |
| On the dark note page a yellow highlighter stroke is drawn as PencilKit's dark-appearance yellow (a darker olive), and black ink as near-white. | Intentional: "using PencilKit's own light and dark ink rendering"; the stored strokes are unchanged. |
| The tool picker's swatches follow the system appearance while the target is the white book page. | Open owner decision (`toolPicker.colorUserInterfaceStyle`); on the device checklist. |

## Largest accessibility text size (`*-xxxl.jpg`)

Not in the mockups; checked in WP12 at Accessibility XXXL (`TEST_RUNNER_MOCKUP_ARGS=
"-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL"`,
`TEST_RUNNER_MOCKUP_SUFFIX=-xxxl`).

| Finding | Status |
| --- | --- |
| Contents rows showed no title at all (badge, mark and page number took the 280 pt row). | **Fixed in WP12:** at accessibility sizes the title takes the row and the mark, badge and page number go under it; indentation stops growing with the text. |
| Notes pane header: tabs cut to "Page…" / "Sectio…", zoom wrapped to "200 / %", section titles and the level picker cut to "5.2…". | **Fixed in WP12:** the header is capped at Accessibility 1 like toolbar controls, and the page range goes under the section title. The note and the region below it keep the full size. "Section note" can still show as "Section n…". Since TSOFT-217/218 the zoom button is gone and the level picker sits at the bottom of the panel, where it wraps at full size. |
| "Add Heading at Page N" under Contents wrapped to five lines. | **Fixed in WP12:** capped at Accessibility 1. |
| The note page's default zoom follows Dynamic Type (200%), wider than the 330 pt pane, so the note scrolls sideways until the pane is widened. | Open: by design ("Dynamic Type sets the default zoom"); a cap at the pane's width is an owner choice. |
| The Notebook's filter column hyphenates long headings ("3 Matri-ces"). | Open (cosmetic). |
