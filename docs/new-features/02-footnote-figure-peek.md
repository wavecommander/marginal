# 02 · Footnote / Figure Peek (Link & Reference Preview Popover)

Draft, 18 November 2026. Read `docs/DESIGN.md` ("Section history", "Maximized page", "Windows and scenes") first.

## Goal

Academic textbooks constantly refer the reader elsewhere: *"see Figure 4.12 on p. 188"*, *"by Theorem 2.3"*, footnotes, bibliography entries (`[14]`), and end-of-chapter answers. While clicking a link and pressing Back (`⌘[`) works via Section History, jumping away for a 3-second equation check breaks reading flow. **Footnote / Figure Peek** lets the reader preview a destination page inside a floating popover without leaving their current scroll position, and optionally jump there or open it in a second window.

---

## Principles & Invariants

1. **Zero scroll drift (`ReadingPositionKeeper`).** Presenting or dismissing a Peek popover never moves the main `PDFView` or alters `ReaderSession.sectionHistory`.
2. **Only jumps go through `ReaderSession.jump(...)`.** If the reader taps **Go to Page** inside the Peek popover, it executes `session.jump(toPage:anchor:)` so Section History records the place being left.
3. **Low memory (`Principle 3`).** The Peek popover renders a single target page image (plus any stored highlights and page ink on that page) off the main thread from a lightweight renderer, rather than instantiating a second full `PDFView` with all page overlays.
4. **No database or backup changes.**

---

## Behaviour Specification

### 1. How Peek Is Triggered

1. **Internal PDF links on the page (`PDFAnnotation` of subtype `.link`):**
   - **Single tap** on an internal PDF link keeps its existing behaviour: it jumps immediately via `ReaderSession.jump(...)` so fast navigation is unchanged.
   - **Long press** (or secondary click / trackpad right-click / pointer hover + command-click) on an internal link pointing to another page in the same book opens the **Peek Popover** anchored to the link's rect on screen.
   - External URLs (`http://`, `https://`, `mailto:`) are unaffected.
2. **Page references inside Notes (`p. 312`, `pp. 312–315`, `page 312`):**
   - In the Notes panel (reading mode, or markup mode when not editing text at that character), page references matching explicit page-citation patterns (`p. 312`, `pp. 312–315`, `Page 312`, or localized equivalents) are underlined subtly with a dotted tint underline.
   - **Tap** on a page reference in a note opens the **Peek Popover** for that page (resolved through the book's `pageNumberOffset` if set, see [01-logical-page-number-offset.md](file:///Users/benw/dev/marginal/docs/new-features/01-logical-page-number-offset.md)), with **Go to Page** one tap away.

### 2. What the Peek Popover Shows

- **Header bar:**
  - Destination label: e.g., **Page 188 · 4.3 Eigenvalues** (the page's display number and deepest heading in `session.outline`).
  - Actions:
    - **Go to Page** (`arrow.right.circle`): dismisses the popover and calls `session.jump(toPage: targetPageIndex, point: targetPoint)`.
    - **Open in New Window** (`uiwindow.split.2x1`, shown when `supportsMultipleWindows` is true): opens the book in a new window at `targetPageIndex`.
- **Preview canvas (scrollable & zoomable 1x–3x inside the popover):**
  - Sized to ~380 × 480 pt on regular widths (compact sheet on narrow widths).
  - Shows the target PDF page rendered at display scale, **including the reader's existing highlights and page ink** on that page (read-only).
  - If the link's `PDFDestination` specifies a point `(x, y)` on the target page (for example, a specific equation or footnote at the bottom of page 188), the preview initially centers and subtly flashes a highlight band around that vertical region so the eye lands directly on the referenced item.
  - Adjacent page stepping (`‹ Prev` / `Next ›` chevron buttons in the popover footer) lets the reader peek at `targetPage + 1` when a proof or table spills onto the next page, without leaving their place.

---

## Packages & Implementation Plan

| Package | What it is | Where |
| --- | --- | --- |
| FP1 | Reference detector in `ReaderCore`: pure-Swift parser `PageReferenceDetector.findReferences(in:pageCount:offset:)` that locates `p. N`, `pp. N–M`, `page N` (and localized forms) in note strings and resolves them to valid `0..<pageCount` indices | `Packages/ReaderCore/Sources/ReaderCore/NotePage/PageReferenceDetector.swift` |
| FP2 | `PagePeekRenderer` & `PagePeekPopover`: off-main-thread single-page compositor (PDF page + stored `[Highlight]` + stored `PKDrawing` in light appearance) + SwiftUI popover view with zoom/pan, target-point indicator, Prev/Next page stepper, **Go to Page**, and **Open in New Window** | `App/Features/Reader/PagePeek/` |
| FP3 | Gesture & Note integration: long-press gesture recognizer on `ReaderPDFView` hit-testing internal link annotations (suppressing `MaximizeTapGestureDelegate` when a link long-press fires) + tappable page-reference interaction in `NotePageEditorView` | `App/Features/Reader/ReaderPDFController.swift`, `App/Features/NotePage/NotePageEditorView.swift` |

### Done when

- `swift test` in `ReaderCore` verifies `PageReferenceDetector` across English and localized page-citation formats, edge cases (out-of-range pages ignored, numbers inside words ignored), and logical page offsets.
- UI test long-presses an internal link on a fixture PDF, verifies the Peek popover appears without changing `session.currentPageIndex` or `viewportAnchor`, steps to the next page inside the popover, and taps **Go to Page** to confirm `ReaderSession.jump` navigates and enables Section History **Back**.
