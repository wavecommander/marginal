# 03 · Subtle Paper Guides (Ruled / Grid / Dot Background for Notes)

Draft, 18 November 2026. Read `docs/DESIGN.md` (Principle 5: "A note is a page of its own", "The notes pane follows the system appearance") and `App/Features/NotePage/NotePageStyle.swift` first.

## Goal

In Tactile Texts, a note has typed text and Pencil ink over the whole note, and the blank space below the text grows downward as drawing space (`NotePageStyle.minimumWritingRoom = 220`, `inkGrowthRoom = 220`). Writing handwritten equations, derivations, or diagrams with Apple Pencil on completely blank paper often drifts diagonally. **Subtle Paper Guides** adds an optional faint **Ruled**, **Grid**, or **Dot** guide pattern to the note page that aligns mathematically with the 22 pt text line height, adapts live to Light and Dark Mode, and stays out of exports unless wanted.

---

## Principles & Invariants

1. **Exact alignment with `NotePageStyle.lineHeight` (22 pt).**
   - In `NotePageStyle`, `textInsets.top` is `14 pt`, `lineHeight` is `22 pt`, and `paragraphSpacing` is `6 pt`.
   - In the blank writing space below the typed text (starting at the top of the trailing band, or across the whole note page for Grid/Dot), horizontal rules/grid lines are spaced at **22 pt** in note-page coordinates (`11 pt` sub-grid for graph paper, `22 pt` for ruled and dot grids).
   - Because guides live in **note-page coordinates** inside `NotePageContentView`, pinching to zoom the note (100%–200%) scales the guides in lockstep with the text and ink, and widening the notes pane extends the pattern horizontally without shifting existing strokes.
2. **Follows system appearance (`Light` / `Dark`).**
   - Guides draw with a dynamic `UIColor` (`NotePageStyle.guideColor`): a whisper-faint warm grey (`alpha: 0.14`) on white paper in Light Mode, and a subtle cool highlight (`alpha: 0.14`) on `darkPaperColor` (`#1C1C1E`) in Dark Mode.
3. **Exports stay clean by default.**
   - `NotePageRenderer` (used by `NotebookPDFWriter`, `MarkdownExporter` ZIP images, and "Export Marked-Up PDF") renders notes on clean white paper without background guides by default so printed/exported study guides look like typeset documents, with an optional toggle in Settings if a reader wants guides in exported note images.

---

## Behaviour Specification

### 1. Guide Styles (`NotePaperGuide`)

| Style | Visual | Geometry in Note-Page Space |
| --- | --- | --- |
| **Plain** (default) | Clean paper (`NotePageStyle.paperColor`) | None |
| **Ruled** | Faint horizontal lines across the page width (`inset 14 pt` from left/right edges) | In the blank writing space below the text (starting at the first 22 pt step below the last text paragraph), a `0.5 pt` line every `22 pt` |
| **Grid** | Engineering / graph quad grid across the writing space (or full note) | `22 pt` major squares (`0.5 pt` stroke) with optional `11 pt` minor subdivisions |
| **Dots** | Dot-matrix grid at every `22 × 22 pt` intersection | `1.5 pt` diameter circles every `22 pt` horizontally and vertically |

> **Why Ruled starts below the typed text:** Because paragraphs have `paragraphSpacing = 6 pt` while lines inside a paragraph are `22 pt` apart, multi-paragraph typed text does not sit on a single uniform 22 pt grid across paragraph breaks—and typed text already forms its own visual lines. Drawing **Ruled** lines starting in the blank writing area below the text (while **Dots** and **Grid** either start in the blank writing space or fade to 40% opacity behind typed text bands) avoids visual clashes with `6 pt` paragraph gaps while giving the Pencil a rock-solid baseline for longhand notes and sketches.

### 2. Where the Reader Chooses It

- **Settings ▸ Appearance ▸ Note Paper:** `Plain`, `Ruled`, `Grid`, `Dots` (stored in `@AppStorage("settings.notePaperGuide")`, default `.plain`). Changes update every open window's note editor and read-only Notebook views live.
- **Quick switch in the Notes panel:** When Markup mode is active (or in the Notes panel's header/more menu), a compact Paper Guide menu item lets the reader switch between `Plain`, `Ruled`, `Grid`, and `Dots` without leaving the reader.

---

## Packages & Implementation Plan

| Package | What it is | Where |
| --- | --- | --- |
| PG1 | `NotePaperGuide` enum in `ReaderCore` + `NotePaperGuideLayer` (`CALayer` / `UIView.draw(_:)` in `App/Features/NotePage/`) that draws `Ruled`, `Grid`, and `Dots` in note-page coordinates below `textView` and `noteCanvas`, respecting `trailingBandTop` and dynamic `UITraitCollection` colours | `Packages/ReaderCore`, `App/Features/NotePage/NotePageStyle.swift`, `App/Features/NotePage/NotePageEditorView.swift` |
| PG2 | Settings picker in `SettingsView` (Appearance section) + live observation in `NotePageView` and `Notebook` read-only note previews + dark/light mode appearance unit tests | `App/Features/Settings/`, `App/Features/Notes/`, `App/Features/Notebook/`, `Tests/NotePageAppearanceTests.swift` |

### Done when

- Unit tests in `NotePageAppearanceTests` verify that switching `NotePaperGuide` between `.plain`, `.ruled`, `.grid`, and `.dots` in both Light and Dark mode never mutates `PKDrawing` strokes or `NoteBandLayout`, and that `NotePageRenderer` export output remains unchanged on white paper.
- UI test switches Note Paper to **Ruled** in Settings, opens a book's Page note, verifies the setting persists across relaunch, and confirms dark/light mode rendering.
