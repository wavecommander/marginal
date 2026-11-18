# 08 · Single-Section & Single-Note Quick Share

Draft, 18 November 2026. Read `docs/DESIGN.md` ("Export", "Notes panel layout", "Not in version 1") and `App/Features/Notebook/NotebookPDFWriter.swift` first.

## Goal

Today, exporting notes or highlights requires opening the full **Notebook**, optionally entering **Select** mode, ticking rows, and choosing a format from the Notebook's Export menu (`Markdown`, `Markdown (ZIP)`, or `PDF`). In day-to-day study, readers frequently want to share or print **just the note they have open right now** (a Page note or Section note) or **just one chapter/section's notes and highlights** directly from the Reader without detouring through the Notebook's multi-select flow.

**Single-Section & Single-Note Quick Share** adds direct share actions to the **Notes panel** and the **Contents sidebar**, powered by the existing `MarkdownExporter`, `NotePageRenderer`, and `NotebookPDFWriter` pipelines.

---

## Principles & Invariants

1. **Same faithful rendering and formats as the Notebook (`Principle 5 & 7`).**
   - Single-note and single-section exports use the exact same renderers as the Notebook: always light appearance on white paper (`NotePageStyle.exportTraits`), vector ink paths in PDF exports (`NotePageRenderer`), and 3x bitmap images in Markdown ZIP exports.
2. **Pending edits flush first.**
   - Just like Notebook and Marked-Up PDF exports, triggering a quick share flushes any pending text or ink edits in all open windows for that book before building the export.
3. **Zero database or backup changes.**

---

## Behaviour Specification

### 1. Single-Note Share (from the Notes Panel & Notebook Context Menu)

- **Where:**
  1. **Notes panel header:** A **Share Note** button (`square.and.arrow.up`, disabled while the current note is empty: no text and no ink) next to Delete Note, or a header menu offering **Share Note** and **Delete Note**.
  2. **Notebook row & Library Search row context menu:** Long-pressing any note row offers **Share Note…** alongside **Open in New Window** and **Delete Note**.
- **Formats offered:**
  - **PDF** (`<Book Title> — <Note Target Title>.pdf`, e.g., `Linear Algebra — p. 312 Note.pdf` or `Linear Algebra — 5.2 The Characteristic Equation.pdf`):
    - One or more A4/Letter pages written by `NotebookPDFWriter` containing the book title, the target heading/page header, and the rendered note with its typed text and vector ink.
  - **Image (PNG)** (offered when the note fit on a single screen or has ink/sketches the reader wants to paste into another app, e.g., Messages, Mail, Freeform, or Anki flashcards):
    - Rendered at 3x scale via `NotePageRenderer` on white paper, with a subtle header caption (`<Book Title> · p. 312`).
  - **Markdown** (`.md` text, or `.zip` with the rendered note image when `note.hasInk` is true, matching the Notebook's Markdown rules).

### 2. Single-Section Export (from Contents Sidebar & Section Note Tab)

- **Where:**
  1. **Contents sidebar (`ContentsSidebar.swift`):** Context menu on any heading row that has a note badge (its own note, page notes, highlights, or page ink in its page range) offers **Export Section Notes…** (`square.and.arrow.up`).
  2. **Section note tab (`NotesPanel.swift`):** Next to `"Open in Notebook"` under the level picker, or in the panel header menu when viewing a Section note, offers **Export Section…**.
- **What it includes:**
  - Scoped to the chosen `OutlineNode` (its own section note, all sub-headings inside its tree, and all page notes, highlights, and page handwriting within `node.pageRange`), in standard Notebook order.
  - Uses the existing `NotebookExportSelection` filter in `ReaderCore`—pre-populated with the items under that `OutlineNode`—and offers the three standard Notebook formats (**PDF**, **Markdown**, **Markdown (ZIP)**), then presents the system share sheet anchored to the source button/row.
  - File name defaults to `<Book Title> — <Heading Title>.pdf` (or `.md` / `.zip`, sanitized for file systems).

---

## Packages & Implementation Plan

| Package | What it is | Where |
| --- | --- | --- |
| QS1 | Scoped export helpers in `ReaderCore`: `NotebookExportScope.singleNote(NoteTarget)` and `NotebookExportScope.section(HeadingAnchor)` + filename sanitizer (`<Book> — <Target>`) | `Packages/ReaderCore/Sources/ReaderCore/Export/` |
| QS2 | Single-note PNG/PDF/Markdown builder + UI actions in `NotesPanel` header, `ContentsSidebar` heading context menu, and `Notebook` row context menu, presenting the share sheet anchored to the triggering control | `App/Features/Notes/`, `App/Features/Sidebar/`, `App/Features/Notebook/` |

### Done when

- `swift test` in `ReaderCore` verifies `NotebookExportScope.singleNote` and `NotebookExportScope.section` include the exact expected notes, sub-headings, highlights, and inked pages, and generate clean localized filenames.
- UI test types and inks a Page note in the reader, taps **Share Note** in the Notes panel header, verifies the export format menu and share sheet appear, and right-clicks a heading with notes in the Contents sidebar to trigger **Export Section Notes…**.
