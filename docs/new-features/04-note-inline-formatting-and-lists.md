# 04 · Lightweight Markdown-Style List & Heading Formatting in Notes

Draft, 18 November 2026. Read `docs/DESIGN.md` ("Ink follows the text it annotates", "Open questions for the owner #2") and `App/Features/NotePage/NotePageStyle.swift` first.

## Goal

Open Question #2 in `docs/DESIGN.md` notes:
> *"Notes are plain text under the ink in version 1 (no bold, lists are typed dashes). Rich text changes line heights mid-note and makes ink anchoring harder; is plain text acceptable?"*

We can give readers structured, readable notes—**bold**, *italic*, `inline code`, section subheadings, and automatic bulleted/numbered/checkbox lists—**without ever violating the fixed 22 pt line-height invariant** or changing the database schema. Because every styled span uses the exact same `22 pt` minimum/maximum line height and `6 pt` paragraph spacing, paragraph-band ink anchoring (`NoteBands`) remains 100% deterministic.

---

## Core Design Decision: Inline Markdown with Fixed-Line-Height Live Styling

1. **Storage remains plain `Note.text: String` (zero schema or backup breakage).**
   - `Note.text` continues to store UTF-8 text using lightweight Markdown conventions (`**bold**`, `*italic*`, `` `code` ``, `# Heading`, `- bullet`, `1. numbered`, `- [ ] task`).
   - Because `Note.text` is still a plain `String`, `TactileTextsSchemaV1`–`V3`, `.ttbackup` archives, Cloud Sync paragraph merging (`ReaderCore/Merge`), Library search, and `MarkdownExporter` work out of the box—and older app versions display the note as clean Markdown with every ink stroke still anchored to its exact paragraph band!
2. **Strict `22 pt` line height across every style (`NotePageStyle`).**
   - Whether a character is Regular, **Bold** (`UIFont.boldSystemFont(ofSize: 15)`), *Italic* (`UIFont.italicSystemFont(ofSize: 15)`), `Monospaced` (`UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)`), or a Subheading (`# `, `UIFont.systemFont(ofSize: 16, weight: .semibold)`), its `NSParagraphStyle` enforces:
     ```swift
     style.minimumLineHeight = 22
     style.maximumLineHeight = 22
     style.paragraphSpacing = 6
     ```
   - Delimiter characters (`**`, `*`, `` ` ``) are kept in the text storage (so character indices and cursor movement never shift unexpectedly) and styled in `.tertiaryLabel` (`alpha: 0.35`) while the cursor is on that paragraph, or dimmed when unfocused, so the text never reflows when the cursor enters or leaves a line.

---

## Behaviour Specification

### 1. Automatic List Continuation & Indentation

When typing in `NotePageEditorView`:
- **Unordered lists (`- `, `* `, `• `):**
  - Typing `- ` at the start of a line automatically converts `- ` to `• ` (or keeps `- ` with a hanging indent of `16 pt` so wrapped lines align cleanly under the text, not under the bullet).
  - Pressing **Return** at the end of a non-empty list item inserts `\n• ` on the next line (creating a new paragraph band, just as Return does today).
  - Pressing **Return** on an *empty* list item (`• `) removes the bullet prefix and returns the line to a normal paragraph without adding a blank line.
- **Numbered lists (`1. `, `2. `):**
  - Pressing **Return** after `1. First item` automatically inserts `\n2. `.
  - Pressing **Return** on an empty `2. ` removes the prefix.
- **Checkboxes (`- [ ] `, `- [x] ` or `☐ `, `☑ `):**
  - Rendered with a tappable leading checkbox glyph (`square` / `checkmark.square.fill` in the accent tint). Tapping the checkbox in reading mode (or with a finger tap) toggles `[ ]` ↔ `[x]` in place without changing line count or paragraph band heights.
- **Tab / Shift-Tab (and keyboard toolbar buttons):**
  - Indents or outdents the current list paragraph by one level (up to 3 levels, `16 pt` per level).

### 2. Inline Formatting Shortcuts & Edit Menu

- **Keyboard shortcuts:**
  - `⌘B`: wraps/unwraps selection in `**...**` (or inserts `****` with cursor inside).
  - `⌘I`: wraps/unwraps selection in `*...*`.
  - `⌘E` (or `` ⌘` ``): wraps/unwraps selection in `` `...` ``.
  - `⇧⌘L`: toggles bullet list on the selected paragraph(s).
  - `⇧⌘7`: toggles numbered list on the selected paragraph(s).
- **Edit menu / Selection bar:**
  - Selecting text in a note offers **Bold**, **Italic**, and **Code** in the standard `UIMenuController` / `UITextView. editMenu(for:suggestedActions:)` menu.

### 3. How Exports Render Formatted Notes

- **Markdown & Markdown (ZIP) (`MarkdownExporter`):**
  - Since `Note.text` is already valid Markdown, `MarkdownExporter` outputs it directly—lists, bold, italic, and code blocks render natively in any Markdown viewer!
- **Notebook PDF & Marked-Up Book Appendix (`NotePageRenderer` / `NotebookPDFWriter`):**
  - `NotePageRenderer` uses the same `NoteMarkdownHighlighter.attributedString(for:in:)` as `NotePageEditorView` (except in export light mode, delimiter marks like `**` can either be drawn in very faint grey at their exact glyph width or hidden with a fixed-width spacer so ink drawn over a word in the editor lands on the exact same `x, y` glyph coordinates in the PDF export).
  - **Crucial ink-registration rule:** In both the editor and `NotePageRenderer`, the horizontal advance of every character on a line must be identical so that an underline or circle drawn with Apple Pencil over a word in the note editor sits over the exact same letters in the Notebook read-only view and the PDF export. Keeping the syntax characters at their normal advance width (styled in faint `.quaternaryLabel` in the editor and faint grey in PDF export, or using inline keyboard shortcuts that toggle attributes) guarantees zero horizontal drift between editor and export.

---

## Packages & Implementation Plan

| Package | What it is | Where |
| --- | --- | --- |
| NF1 | Pure-Swift `NoteListBehavior` and `NoteMarkdownParser` in `ReaderCore`: parses inline spans (`**bold**`, `*italic*`, `` `code` ``, `# heading`, list prefixes `• `, `1. `, `☐ `/`☑ `), handles Return key list continuation/termination, and Tab/Shift-Tab indentation | `Packages/ReaderCore/Sources/ReaderCore/NotePage/` |
| NF2 | `NotePageStyle` attributed-string styling (`NoteStyledText`): applies bold, italic, monospaced (with background pill), heading weight, and list hanging indents while enforcing `minimumLineHeight = 22, maximumLineHeight = 22` everywhere; wires `⌘B`, `⌘I`, `⌘E`, and Return-key list continuation into `NotePageEditorView` and `NotePageRenderer` | `App/Features/NotePage/` |

### Done when

- Unit tests in `ReaderCore` and `Tests/NotePage*` prove:
  1. Applying bold, italic, code, or subheading styling to any paragraph in a note **never changes its line height (`22 pt`)** or shifts the vertical position of `NoteBands` when line wrapping is unchanged.
  2. Pressing Return at the end of `- item` or `1. item` inserts the next marker, and pressing Return on an empty marker clears it.
  3. Ink drawn over a formatted paragraph stays registered across edit, reload, Notebook preview, and PDF export.
