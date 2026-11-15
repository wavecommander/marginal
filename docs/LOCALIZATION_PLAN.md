# Tactile Texts: localization plan

Draft, 15 November 2026. Expanded the same day from French, Spanish and German to ten
languages. Read `docs/DESIGN.md` and `docs/WORK_PACKAGES.md` first. The plan uses the same
orchestrator/subagent model as the build plan, the owner's standing rules (Opus for every
package, targeted tests only with the full gate suspended, iOS 27 simulators only, at most three
build/simulator agents at a time), and the same "Done when" style.

## Languages

| Language | Xcode / App Store locale | Script | Direction | Plural forms (CLDR) | What it adds beyond French |
| --- | --- | --- | --- | --- | --- |
| French | `fr` / fr-FR | Latin | LTR | one (0 and 1), many, other | « » quotes, space before `: ; ! ?` |
| Spanish | `es` / es-MX and es-ES | Latin | LTR | one, many, other | Text runs longer |
| German | `de` / de-DE | Latin | LTR | one, other | Long compounds (+30–35% length) |
| Portuguese (Brazil) | `pt-BR` / pt-BR | Latin | LTR | one (0 and 1), many, other | Text runs long. Apple's Brazilian locale is `pt-BR`, not `pt` |
| Italian | `it` / it | Latin | LTR | one, many, other | Text runs long. Nothing new beyond French |
| Ukrainian | `uk` / uk | Cyrillic | LTR | one, few, many, other | Four plural forms (1 сторінка, 2 сторінки, 5 сторінок, 21 сторінка). Й and ї are letters in their own right, not accented letters (affects search). The apostrophe is part of words (п'ять) |
| Chinese (Simplified) | `zh-Hans` / zh-Hans | Han | LTR | other only | No word spaces, full-width punctuation, taller glyphs, CJK fonts |
| Japanese | `ja` / ja | Kanji and kana | LTR | other only | Counter words instead of plurals (312ページ, 5件). Voiced kana decompose into a base and a combining mark (affects search). Kanji need Japanese glyph forms, not Chinese ones (affects PDF fonts). 「」 quotes |
| Hindi | `hi` / hi | Devanagari | LTR | one (0 and 1), other | Combining vowel signs and virama (affects search), tall glyphs, danda (।) |
| Arabic | `ar` / ar-SA | Arabic | **RTL** | zero, one, two, few, many, other | Mirrored UI, bidirectional text, Arabic-Indic digits, Arabic punctuation (، ؟) |

Arabic is by far the largest piece of work, because the app's chrome must mirror while the PDF,
ink and note pages must not. Hindi is second, because of a search bug it exposes (see below).
Japanese and Ukrainian are affected by the same search bug in milder forms. The other eight
languages need no new layout model.

## Where the app stands today

The app is English only, with no localization in place.

- **No catalogs or `.lproj` folders.** `App/Info.plist` has no `CFBundleLocalizations`, and the
  packages have no `defaultLocalization`. iOS therefore runs the app in English on any device,
  and the **system UI inside the app (Edit menu, PencilKit tool picker, share sheet, document
  picker, standard alert buttons) stays English too**. Declaring the localizations is what turns
  that system UI on, so it is the first step.
- **About 24,000 lines of Swift.** Roughly 200 SwiftUI literal call sites, 170 UIKit/string
  property assignments (accessibility labels and values, menu titles, error text), 16 UIKit
  menus/commands and 165 interpolated strings. Estimate: **300–450 unique strings**, giving
  roughly 3,000–4,500 translations across ten languages. L0 produces the exact count.
- **Strings SwiftUI won't localize on its own.** These are the main extraction work:
  - `Text(verbatim:)` holding English words, such as `"of \(pageCount)"` and `"Page \(n)"`
    (`ReaderScreen.swift:626,644,650`, `BookmarksListView.swift:70`, `AddHeadingSheet.swift:104`,
    `NotesPanel.swift:119`).
  - Computed `String`s passed to `Text`, such as `LibraryLogic.swift:91–118`,
    `SearchPanel.swift:156–184`, `ImportError.swift`, `HighlightPalette.swift:21` (colour names)
    and `ContentsSidebar.swift:12` (tab names).
  - UIKit accessibility strings, such as `PageInkAccessibility.swift:67` and
    `NotePageEditorView.swift:626`.
  - Ternaries such as `Button(isShown ? "Hide Contents" : "Show Contents")`
    (`ReaderCommands.swift`), which string extraction can miss.
- **English plurals written by hand.** About 10 sites use `count == 1 ? "x" : "xs"`. This is
  wrong in French, Portuguese and Hindi, where 0 is singular. In Ukrainian, which has four plural
  forms, and Arabic, which has six, it fails completely.
- **Sentences built from pieces.** `"Searching… \(a) of \(b) pages · \(results)"`
  (`SearchPanel.swift:165`) and
  `"Notebook · \(n) notes · \(h) highlights · \(i) pages of handwriting"`
  (`NotebookPDFWriter.swift:219`) can't be translated in fragments. Word order differs too much,
  most of all in Chinese, Hindi and Arabic.
- **Typography baked into code.** Twelve places hard-code English curly quotes “…”, for example
  `ImportError.swift`. The `"p. 312"`/`"pp. 301–340"` abbreviations in `PageNumbering.label`
  (ReaderCore) also need translating, for example to "第 312 页" in Chinese and "ص 312" in
  Arabic.
- **Numbers printed without formatting.** Page numbers go through `Text(verbatim: "\(n)")` and
  plain interpolation in several places. These always show Western digits, while the rest of
  the app uses `.formatted()`, so an Arabic UI that uses Arabic-Indic digits would mix ١٢٣ and
  123 on one screen.
- **Search deletes Hindi vowel signs and viramas.** This affects book content today,
  independent of the UI language. `SearchEngine.swift:160–167` deletes every nonspacing mark
  (`generalCategory == .nonspacingMark`), both before and after folding. That's right for Latin
  accents and Arabic short vowels. In Devanagari, though, the virama ् and several vowel signs
  (ु ू े ै ं ँ) are nonspacing marks that change the word. "कुल" folds to "कल" and the conjunct
  "क्ष" to "कष", so a Hindi search returns false matches. The same applies to Bengali, Tamil,
  Telugu and the other Indic scripts on Apple's list. The same rule causes two smaller errors in
  the new languages:
  - **Japanese:** the compatibility decomposition turns voiced kana into a base and a combining
    voicing mark (が → か + U+3099), and the mark is then deleted. "は" matches "ば" and "ぱ".
  - **Ukrainian:** й decomposes to и plus a breve and ї to і plus a diaeresis, and both marks are
    deleted. These are separate letters in Ukrainian, so "мій" matches "мії" and "мии".
    Apostrophes are also not folded together: a Ukrainian PDF may use ', ’ or ʼ (U+02BC) inside
    the same word, so a query typed with one misses text set with another.
- **The layout assumes left-to-right.** These are the RTL work items:
  - **Panel divider drag.** The width math (`ReaderScreen.swift:573,586`) subtracts
    `translation.width` on the assumption that the Notes pane is on the right. In a mirrored
    layout the pane is on the left and the sign flips.
  - **Back-swipe guard.** `BackSwipeGuard.swift` and `MarkupSurface.swift:276–280` reason about
    a left-to-right back swipe and the left screen edge. In RTL the system back swipe runs right
    to left from the right edge.
  - **Notebook PDF layout.** `NotebookPDFWriter` places every line itself at
    `x: margin`, with page numbers and page ranges at the right edge (`:190,194,243,248`).
    CoreText orders the characters within a line, but the alignment is hard-coded left.
  - **Direction-sensitive code.** 19 more call sites use left/right, layout direction or writing
    direction and need an audit.
  - **Directional symbols.** `arrow.right.doc.on.clipboard`, `arrow.right.circle` and the
    "‹ Library" back affordance.
  - **Geometry tied to the page.** Ink, highlights, note bands and thumbnails
    (`PageInkGeometry`, `HighlightGeometry`, `NoteInk`, `NotebookHandwriting`, `PagesGridView`)
    use absolute x coordinates in PDF or note-page space. These must **not** mirror.
- **Fonts and glyph height.** The notebook PDF sets its text in Georgia
  (`NotebookPDFWriter.swift:358`), which has no Han, kana, Devanagari or Arabic glyphs. CoreText
  falls back silently, so the export looks mismatched. The fallback can also choose a Chinese
  font for Japanese text, which draws many kanji in their Chinese forms (Han unification).
  Cyrillic support in the installed Georgia needs checking. There are 13 fixed-height `frame`s;
  these clip Devanagari and Arabic text, whose marks sit above and below the Latin line height.
- **The note page's line height is fixed.** `NotePageStyle.swift:17–18,65–66` fixes the line
  height at exactly 22 pt for 15 pt text, so that ink stays registered to the text lines. Chinese
  and Japanese fit. Devanagari and Arabic marks may overlap the next line. The line height can't
  simply be changed: that would move existing text out from under its ink.
- **The note editor already handles input methods.** `NotePageEditorView.swift:554` waits for
  `markedTextRange == nil` before treating an edit as settled, which Japanese and Chinese input
  methods need. Only an on-device check is needed (L4).
- **Already locale-correct.** `localizedStandardCompare` sorting, `ByteCountFormatter`, most
  `.formatted()` number calls, and the notebook PDF paper size (`measurementSystem`). Note text
  uses TextKit 2 `UITextView`, which handles bidirectional text and line breaking for every
  script. Keyboard shortcuts use SwiftUI's automatic keyboard-layout localization. No dates are
  shown anywhere.
- **ReaderCore has user-visible text.** `PageNumbering.label`, `SectionHistory.swift:52`
  (`"Page N"`) and `MarkdownExporter` (`"Front matter"`, `"Unfiled notes"`,
  `"Untitled heading"`, `"Handwritten note"`, `"**Page N**"`). That package is tested with
  `swift test` on macOS and must stay Foundation-only, so its strings need their own catalog in
  `Bundle.module`.
- **Tests depend on English.** UI tests contain about 426 capitalised English literals, many of
  them used as element queries next to the 104 accessibility identifiers. About 21 unit-test
  assertions and the `Tests/Fixtures/Notebook/seeded.md` golden file expect English output.
- **Debug-only text** must stay out of the catalog: `ReaderPerfProbe`, `SidebarDebugStats`,
  `DesignSystemGallery`, the `*DebugSeed` files and `ReadingAnchor.debugDescription`.

## Decisions for the owner

Each decision has a recommendation, and packages assume the recommendation until the owner says
otherwise.

1. **App name.** Keep **"Tactile Texts"** untranslated in every language, as a brand, including
   in Chinese, Hindi and Arabic where it appears in Latin script. Only the App Store subtitle and
   description are translated.
2. **Language variants.**
   - **French, Spanish, German, Italian, Ukrainian, Japanese:** base `fr`, `es`, `de`, `it`, `uk`
     and `ja`.
   - **Portuguese:** `pt-BR`, which is the larger market. Portugal falls back to it until a
     `pt-PT` is added.
   - **Chinese:** **Simplified (`zh-Hans`) only in version 1.** Taiwan and Hong Kong need
     Traditional (`zh-Hant`), which is a separate translation and doesn't come from automatic
     conversion. Add it as a follow-up.
   - **Arabic:** Modern Standard Arabic as a single `ar`.
   - **Hindi:** `hi`.

   Write Spanish in neutral Spanish that avoids Spain-only words, so it reads well in Latin
   America. Regional variants can be added later as catalog entries without code changes.
3. **Voice.** Match the second-person form and register Apple's own iPadOS system text uses in
   each language. The L3 glossary records which form that is.
4. **Who translates.** Claude drafts all ten languages from a glossary and translator
   comments. A **paid native-speaker reviewer per language** then checks the strings in
   context, using the L4 screenshot sheets. For Arabic, the reviewer must also check mirrored
   layout and how mixed-direction text reads, not just the words. The Ukrainian reviewer must be
   a native Ukrainian speaker who checks specifically for Russian terms and calques, which machine
   drafts tend to produce. Machine-only translation is not
   enough for an App Store release.
5. **Export language.** Markdown and Notebook PDF exports use the **app's UI language at export
   time** for their fixed text. Book titles, headings and note text are the user's own and are
   never translated. An Arabic-UI notebook PDF is laid out right to left, while each note
   paragraph keeps its own direction.
6. **Numbers.** Show page numbers **without grouping separators** in every language ("page 1234"),
   but **always in the locale's digits**, through `.formatted(.number.grouping(.never))` rather
   than `"\(n)"`. Counts of results and notes keep locale grouping.
7. **RTL scope.** **Mirror the app's interface and never mirror content.** In an Arabic UI:
   - The sidebar, toolbar, Notes inspector, Library grid, menus and alerts mirror.
   - The PDF page, ink, highlights, page thumbnails and the note page's ink surface stay exactly
     as drawn.
   - Typed note text takes its direction from its own content, not from the UI language. So an
     English note in an Arabic UI stays left-aligned under its ink, and an Arabic note in an
     English UI stays right-aligned.
   - The Pages grid mirrors its order, with page 1 at the top right, which is how RTL readers
     expect a grid to flow.
8. **Release phasing.** Ship in **two releases**:
   - **Release A:** French, Spanish, German, Italian, Portuguese, Ukrainian, Chinese and
     Japanese. These need only string, length, font and search work, and all of it ships in
     Release A anyway.
   - **Release B:** Arabic and Hindi, once RTL (L2r) and the script-aware search fix (L1b) have
     soaked on device.

   All the code changes still land in Release A's codebase. Only their catalog entries and
   `CFBundleLocalizations` entries are held back until Release B. This decision only affects
   which waves gate which release; the packages are the same either way.

## Rules for every package

- **English output stays exactly the same.** English is the development language, and every
  package must leave English UI and English exports byte-identical. That makes the existing
  targeted tests the regression check for the string extraction work.
- **Use one localization API per kind of string.**
  - SwiftUI literals stay as `LocalizedStringKey` (`Text("…")`).
  - Model and logic code returns `LocalizedStringResource` or uses
    `String(localized: "…", comment: "…")`.
  - ReaderCore uses `String(localized: "…", bundle: .module, comment: "…")`.
  - `Text(verbatim:)` is only for user content and must never hold a bare number (see decision
    6).
- **Every key has a translator comment** that says where the string appears and roughly how much
  space it has, for example "Menu bar ▸ View; toggles the Contents sidebar." Strings with
  arguments name each argument.
- **Translate whole sentences.** Never concatenate translated fragments. A sentence with several
  counts becomes one key with plural substitutions in the String Catalog.
- **Plurals always come from the catalog** (`%lld` with plural variations), never from
  `== 1 ? :`. Arabic needs all six forms filled in.
- **Quote marks, ellipses, middle dots, separators and units live inside the translatable
  string**, so each language chooses its own typography.
- **Isolate user content inside sentences.** Book titles, file names and heading titles inserted
  into a localized sentence are wrapped in Unicode first-strong isolates (U+2068 … U+2069) through
  one helper, `BidiIsolated(_:)`. Without them, an English book title inside an Arabic sentence,
  or an Arabic title inside an English one, can reorder the punctuation around it.
- **Use leading and trailing, never left and right**, in SwiftUI (`.leading`/`.trailing`,
  `Edge.Set.horizontal`) and UIKit (`.natural`, `semanticContentAttribute`). Where code needs
  physical left or right in PDF or ink space, it says so in a comment and stays in that space.
- **Accessibility identifiers are never localized.** UI tests query by identifier, or by English
  label with the app pinned to English. Where a test currently queries a label that has no
  identifier, add an identifier rather than translating the query.
- **Never store a display string in the database.** If one is found (a default title saved as
  English text), store an empty value or a flag and produce the text at display time.

## Packages

### L0 · Localization scaffold · Opus

- `project.yml`: set `options.developmentLanguage: en`. Add `CFBundleDevelopmentRegion: en` and
  `CFBundleLocalizations` to the `info:` block. List the Release A languages
  (`en, fr, es, de, it, pt-BR, uk, zh-Hans, ja`) now, and add `ar` and `hi` when Release B is cut
  (decision 8). Add an empty `App/Localizable.xcstrings` and `App/InfoPlist.xcstrings` (for
  `CFBundleTypeName` "PDF Document"; the display name stays untranslated). Confirm XcodeGen 2.46
  puts the catalogs in the resources phase and writes `knownRegions` for all ten languages, and
  patch through `project.yml` if it doesn't. Check that `SWIFT_EMIT_LOC_STRINGS` is on for the
  app target.
- `Packages/ReaderCore/Package.swift`: add `defaultLocalization: "en"` and a
  `Resources/Localizable.xcstrings` processed resource. Confirm `swift test` on macOS still
  passes and that ReaderCore imports nothing beyond Foundation.
- **Pin tests to English.** In `UITests/Support/Fixtures.swift`, add
  `-AppleLanguages (en) -AppleLocale en_US` to every launch. In the unit-test targets, make
  English output explicit (pass `locale: Locale(identifier: "en_US")` where formatting happens,
  and read strings from the `en` bundle) so the suite passes on a simulator set to any language.
- `scripts/l10n-check.sh` uses `jq` on the `.xcstrings` JSON and fails when any of these holds:
  - a key has no value in one of the target languages;
  - a value is still in the `new` or `needs_review` state;
  - format specifiers differ from the English value;
  - a plural key is missing a form CLDR requires for that language (Ukrainian needs one, few,
    many and other; Arabic needs zero, one, two, few, many and other);
  - a key has no comment;
  - a value in a non-English language is identical to the English one and the key isn't marked
    "do not translate".

  It takes a `--languages` list so Release A can be checked on its own. Until L3, it runs in
  report mode and doesn't fail.
- `scripts/shot.sh` gains `--language <code>` (launch arguments `-AppleLanguages (<code>)`) and
  three pseudolanguage modes:
  - `--language double`: double-length strings;
  - `--language accented`: accented characters, to catch clipping above and below the line;
  - `--rtl`: `-AppleTextDirection YES -NSForceRightToLeftWritingDirection YES`, which mirrors
    the UI with the English strings, so RTL work can start before any Arabic text exists.
- Add `App/Support/BidiIsolated.swift`, the one isolation helper the rules require, with unit
  tests.
- Write the inventory to `build/l10n-inventory.md`: every user-facing string site by file, with
  the debug-only exclusions listed, plus every left/right, fixed-width, fixed-height and
  verbatim-number site. L1a–c, L2 and L2r use it as their checklist.
- **Done when**
  - the app builds and launches with the Release A localizations declared;
  - the system UI inside the app (Edit menu, tool picker) shows French, Japanese and Ukrainian on
    simulators set to those languages;
  - ReaderCore `swift test` passes;
  - the Library and Reader UI test classes pass on a simulator set to Arabic.

### L1a · Strings: library, import, commands, shell · Opus

Owns `App/Features/Library/`, `App/Support/` (except the accessibility-identifier files and
`BidiIsolated.swift`), `App/MarginalApp.swift`, `App/DesignSystem/Components.swift` and
`App/Features/Reader/ReaderHost.swift`.

- Turn every user-facing literal into a catalog key with a comment. This covers the menu bar
  (`ReaderCommands.swift`), including the `CommandMenu("Go")` title and the Hide/Show ternaries,
  written as two explicit keys.
- `ImportError`: `errorDescription` and `alertTitle` come from `String(localized:)`, with the
  file name as a `BidiIsolated` argument and the quote marks inside the translatable string.
- `LibraryLogic` labels become plural keys. That covers page counts, "Page X of Y" and the
  "notes and highlights" summary with its parts. All numbers go through the formatting in
  decision 6.
- **Done when** every site for these folders in the L0 inventory is ticked off, English UI is
  unchanged (Library and Journey UI tests pass), and the double-length pseudolanguage shows every
  string on these screens doubled, which proves none is still hard-coded.

### L1b · Strings and search: reader, sidebar, search · Opus

Owns `App/Features/Reader/` (except `ReaderHost.swift`), `App/Features/Sidebar/` and
`App/Features/Search/`. **Coordinate before starting.** The owner currently has uncommitted
edits in `ReaderPDFController.swift` and `UITests/ReadingPositionUITests.swift`, so this package
waits until those are committed, or leaves those files alone.

- Page pill and Go to Page: replace the `Text(verbatim: "of \(n)")` and `"Page \(n) of \(m)"`
  forms with keys. The "of N" fragment next to a text field becomes a full key such as
  `"%@ of %lld"`, laid out so that languages which put the number first or after a counter word
  (Chinese "共 N 页") still read correctly. Page-number digits follow decision 6.
- `SearchPanel` status lines become single keys with plural substitutions. This covers "Searching
  … X of Y pages · N results", "Cancelled after …", "First N matches, up to page P of T" and the
  results-group accessibility label.
- The names of the Contents, Bookmarks and Pages tabs, and the "Heading title" placeholder.
- **Make search folding script-aware** (`SearchEngine.swift:154–173`). Deleting a nonspacing mark
  should depend on the script of the base character it attaches to.
  - **Delete** the mark after Latin, Greek and Cyrillic letters (accents) and after Arabic letters
    (the harakat and the dagger alef). Also delete Arabic tatweel (U+0640).
  - **Except in Cyrillic:** keep the breve that makes й/Й and ў/Ў, and the diaeresis that makes
    ї/Ї, so those stay separate letters. Fold ё to е, which is how Russian-language search
    usually behaves and is harmless in Ukrainian text.
  - **Keep** the mark after Devanagari, Bengali, Gurmukhi, Gujarati, Odia, Tamil, Telugu,
    Kannada, Malayalam and Thai letters. In those scripts the marks are vowel signs and viramas
    that change the word.
  - **Keep** the kana voicing marks (U+3099, U+309A) after hiragana and katakana, so が stays
    different from か. Half-width katakana still fold to full width through the compatibility
    decomposition. Hiragana and katakana are not folded to each other; that is out of scope.
  - Fold apostrophes inside words (U+0027, U+2019, U+02BC) to one character, for Ukrainian and
    for English and French elisions.
  - Apply the same rule to the `folding(options:)` output, so that Foundation's diacritic
    folding can't remove an Indic mark either.
  - Keep `decomposedStringWithCompatibilityMapping`. It maps Arabic presentation forms
    (U+FB50–FEFF), which many Arabic PDFs contain, to the base letters, and full-width Latin to
    ASCII.
  - Also normalise Arabic hamza-carrying alefs (أ إ آ → ا) and alef maqsura (ى → ي) so searches
    match the way Arabic readers type. Leave ta marbuta alone, because folding it causes false
    matches.
- **Search tests.** Unit tests that should match:
  - *é*/*e*, *ñ*/*n*, German umlauts both ways, and *ß*/*ss* ("Straße" against "strasse"; if
    *ß* doesn't fold, add an explicit mapping on both the query and the page text);
  - "كَتَبَ" against "كتب";
  - presentation-form "ﻛﺘﺐ" against "كتب";
  - Chinese and Japanese substrings with no spaces;
  - half-width "ｶﾞｲﾄﾞ" against "ガイド";
  - "п'ять" against "п’ять" and "пʼять";
  - "ёлка" against "елка".

  Unit tests that should **not** match:
  - "कुल" against "कल";
  - "क्ष" against "कष";
  - "ば" against "は";
  - "мій" against "мии", and "їжа" against "іжа".

  Search matches the book's text, not the UI language, so this is a search correctness fix that
  ships in Release A whatever decision 8 says. Simplified/Traditional Chinese character folding
  is out of scope.
- Check that `OutlineText.matchKey` (ReaderCore) has the same Indic mark problem when it matches
  heading titles. If it does, move the shared folding into ReaderCore so both callers use one
  rule.
- **Done when** these folders are clean in the inventory, the Reader, Sidebar and Search UI
  classes pass in English, and the new folding tests pass.

### L1c · Strings: notes, note page, notebook, highlights, markup, ReaderCore · Opus

Owns `App/Features/Notes/`, `NotePage/`, `Notebook/`, `Highlights/` and `Markup/`, plus the
user-visible text in `Packages/ReaderCore/Sources`.

- `HighlightColor.displayName` returns a `LocalizedStringResource`.
- Accessibility values ("1 stroke", "N items", "Heading level, X") become plural keys.
- `NotebookPDFWriter`:
  - The header line becomes one key with three plural substitutions, plus a variant without the
    handwriting part.
  - Replace the bare Georgia font with a font descriptor whose cascade list goes Georgia (Latin,
    plus Cyrillic if the installed Georgia covers it; otherwise Times New Roman for Cyrillic),
    then Han, Kohinoor Devanagari (Devanagari), then SF Arabic (Arabic). Check that each font is
    embedded in the exported PDF.
  - Choose the Han font per paragraph to avoid Han unification errors. Use Hiragino Sans when the
    paragraph contains kana, or when the UI language is Japanese and the paragraph has no kana to
    decide by. Otherwise use PingFang SC. Also set the paragraph's language attribute
    (`kCTLanguageAttributeName`), so CoreText picks the locale's glyph forms.
  - Line height comes from the font actually used, not from a constant.
- ReaderCore: `PageNumbering.label` (both forms), `SectionHistory`, and all fixed text in
  `MarkdownExporter` go into the ReaderCore catalog with `bundle: .module`. Remove the duplicate
  "Untitled heading" in `NotebookFeed.swift:277` and use the ReaderCore one.
- Golden files: keep `seeded.md` as the English golden file and add one placeholder per target
  language (`seeded.fr.md` … `seeded.ar.md`), filled in once L3 lands. To run the exporter in a
  given language, pass the locale in explicitly (`MarkdownExporter.export(…, locale:)`) rather
  than relying on process state.
- **Done when** these regions are clean in the inventory, the NotePage and Notebook UI classes
  and ReaderCore `swift test` pass in English, and the English export matches `seeded.md`
  byte for byte.

### L2 · Layout under longer, taller and denser text · Opus

Runs after L1a–c are merged. German, Portuguese and Italian typically run 25–35% longer than
English, and Ukrainian 15–25%. Chinese and Japanese are shorter but have no spaces to break lines
at. Devanagari and Arabic need more height above and below the line.

- Run every screen in the **double-length** and **accented** pseudolanguages: Library, Reader
  with the Contents and Notes panels, Markup, Note page, Notebook, Search, Go to Page, Add Heading,
  the import alerts and the menu bar. Check each on the 11-inch and 13-inch iPad, at full screen,
  ⅓ split, Stage Manager minimum width and the largest standard Dynamic Type size.
- Audit the 29 fixed widths and 17 `lineLimit(1)`/`fixedSize` sites. Use `ViewThatFits` or
  wrapping where the text is the user's language, and allow two lines in compact buttons and
  segmented controls. In particular, check the Notes inspector's Page note / Heading note control
  ("Notiz zur Überschrift"), the page pill, the toolbar and the sidebar tabs.
- Audit the 13 fixed heights. Each one either becomes a minimum height or is derived from the
  font's line height, so Devanagari and Arabic marks aren't clipped.
- **Note page line height.** Type the 22 pt fixed line height test lines in Hindi, Arabic,
  Japanese and Ukrainian: stacked Devanagari conjuncts, Arabic with full harakat, Japanese mixed
  with Latin, and Cyrillic capitals with breves. If marks collide with the next line, don't change
  the global constant, because that would move text under existing ink. Raise it with the owner
  as a design decision instead. The likely answer is a per-note line height, stored with the note
  and taken from the script the note is first typed in, so that existing notes never move.
- **Done when** `build/shots/l10n-pseudo/` holds the screenshot set with nothing clipped or
  truncated without an ellipsis, and the English shots haven't changed.

### L2r · Right-to-left · Opus

Runs after L2, because both edit the same view files. Work against the `--rtl` pseudo mode (the
English strings, mirrored), so it needs no Arabic translation.

- **Pin content to left-to-right.** Give the page content its own layout direction:
  - Force left-to-right (`semanticContentAttribute = .forceLeftToRight` on `ReaderPDFView`, the
    page-ink and markup `PKCanvasView`s, and the highlight overlays;
    `.environment(\.layoutDirection, .leftToRight)` on their SwiftUI hosts).
  - Do the same for the note page's ink surface and band layout.
  - Add a test: a note inked in an English UI renders pixel-identical in the `--rtl` mode.
- **Notes text direction.** The note page's `UITextView` uses `.natural` alignment, with base
  writing direction taken from each paragraph's first strong character. It doesn't inherit the
  UI's direction, which keeps typed text under its ink (decision 7). For empty notes, the
  insertion point starts on the leading side of the UI.
- **Mirror the chrome.**
  - Fix the sign of the panel divider drag (`ReaderScreen.swift:573,586`) by using the
    environment's layout direction.
  - Make `BackSwipeGuard` and the markup-mode back-swipe suppression direction-aware: the swipe
    and its edge are on the right in RTL.
  - Use symbols that mirror automatically, or `.flipsForRightToLeftLayoutDirection(true)`, for
    every directional icon.
  - Work through the 19 left/right and writing-direction sites in the inventory.
- **Notebook PDF in RTL** (decision 5). The header, footer, page numbers and section page ranges
  swap sides. Each note paragraph's alignment follows its own direction. The thumbnails of
  inked pages stay unmirrored.
- **Markdown export** is plain text, so only check that headings and page labels in Arabic come
  out in the right logical order. No layout work is needed.
- **Done when**
  - `build/shots/l10n-rtl/` holds the full screen set with the chrome mirrored and the
    PDF/ink/notes untouched;
  - the ink-invariance test passes;
  - the Reader, Sidebar, NotePage and Notebook UI classes pass under `--rtl`;
  - the divider drag, back swipe and markup gestures work in the mirrored layout on the
    simulator.

### L3 · Glossary and translations · Opus

- **Glossary first.** Write `docs/l10n/GLOSSARY.md` with one row per core term: Library, Reader,
  Contents, Notebook, Note, Page note, Heading note, Highlight, Bookmark, Markup, Heading,
  Front matter, Unfiled, Import and Resume. Give each term its form in all ten languages,
  matched to Apple's own Books, Notes, Preview and Files terminology (check Apple's published
  localization glossaries). Record the voice decision (decision 3) and the typography rules:
  - **French:** «  » with non-breaking spaces, and a space before `: ; ! ?`.
  - **German:** „…“.
  - **Italian:** «…» or “…”. Pick the one Apple's Italian UI uses and record it.
  - **Ukrainian:** «…», and the typographic apostrophe ʼ inside words (пʼять).
  - **Japanese:** 「…」 for quotes, 、 and 。 as comma and full stop, and counter words in place
    of plurals (312ページ, 5件). Follow Apple's Japanese UI on spacing next to Latin words and
    digits.
  - **Chinese:** full-width punctuation (，。：“”), a space between Han characters and Latin
    letters or digits as Apple's Chinese UI does ("第 312 页"), and the ellipsis ……
  - **Hindi:** the danda (।) as the full stop.
  - **Arabic:** the Arabic comma (،) and question mark (؟), and no Latin punctuation next to
    Arabic text.
- **Drafts.** Translate in parallel without conflicts in the catalog file. Export one XLIFF per
  language (`xcodebuild -exportLocalizations -exportLanguage <code> …`) and run one agent per
  language on its own `.xliff` file. These are build-only and need no simulator. Run them in two
  batches: Release A's eight languages first (in groups of about four), then Arabic and Hindi. Import them one after another
  (`-importLocalizations`) and let `l10n-check` validate the result. Imported entries keep the
  `needs_review` state until L4.
- Fill the per-language golden Markdown files from the translated catalog.
- **Done when** `l10n-check` passes in strict mode apart from `needs_review` states for each
  batch, and the app builds with no missing-translation warnings.

### L4 · Review in context and locale smoke tests · Opus plus native reviewers

- Produce a screenshot sheet per language with `shot.sh --language`: every L2 screen, plus the
  alerts and the menu bar. Each screenshot sits next to its keys and the English source, ready to
  send to the reviewers. The Arabic sheet also covers:
  - mixed-direction cases: an English book title in an Arabic sentence, and an Arabic note in
    the Notebook;
  - the RTL Notebook PDF.
- Apply the reviewers' fixes, set entries to `translated` and turn on strict `l10n-check` for that
  release's languages.
- `LocalizationSmokeUITests`: one test per language, run serially on one simulator, that launches
  with `-AppleLanguages (<code>)`, opens Library → Reader → Notebook by accessibility identifier,
  and checks that a few known translated labels appear and that no English string from a short
  list of distinctive ones does. The Arabic test also checks that the Contents sidebar's frame is
  on the trailing (right) side and the PDF view's isn't mirrored.
- **Input methods in the note editor and search field.** On a device, type with the Japanese
  (Romaji and Kana), Chinese Pinyin and Ukrainian keyboards, and with a hardware keyboard.
  Composition must never be cut off, the band layout must not jump while text is marked, and the
  autosave must wait until composition ends.
- **Keyboard shortcuts** on these hardware layouts: French AZERTY, Spanish, Italian, Portuguese
  (Brazil), German QWERTZ, Ukrainian, Japanese (JIS), Chinese Pinyin, Hindi (Devanagari) and
  Arabic. Check ⌘+, ⌘-, ⌘0 and ⌘9
  for zoom, ⌥⌘0 for Notes, and the arrow-key page commands. With non-Latin layouts, iPadOS
  matches ⌘ shortcuts against a Latin layout, so check that the menu bar shows them and that they
  fire. If a shortcut is unreachable, choose an alternative per locale.
- **Done when** each release's reviewers have signed off, its smoke tests pass, and the per-app
  language picker (Settings ▸ Tactile Texts ▸ Language) switches the app correctly in every
  shipped language.

### L5 · App Store and release · Opus

- App Store Connect metadata for each shipped language: subtitle, description, keywords, what's
  new and screenshots taken from the L4 shot sets. The App Store locales are fr-FR (plus fr-CA if
  wanted), es-MX and es-ES, de-DE, it, pt-BR, uk, zh-Hans, ja, hi and ar-SA. The name stays "Tactile Texts".
- Add a localization section to `docs/DEVICE_CHECKLIST.md` that runs a real device in each
  language and covers:
  - Scribble and handwriting in the note editor. Scribble's language support varies, so first
    check Apple's current list for Hindi and Arabic, and record which languages fall back to the
    keyboard.
  - Searching a real Hindi, Arabic, Japanese and Ukrainian PDF.
  - Exporting the Notebook PDF in Arabic, Chinese and Japanese and opening it in Files. A
    Japanese notebook must show Japanese kanji forms.
- Add a "Localization" section to `docs/DESIGN.md` with the rules above (including leading and
  trailing over left and right, isolates and digits), so later packages create new strings and
  layouts localization-ready from the start. Add `l10n-check` to the build gate.

## Waves

| Wave | Packages (parallel within a wave) | Release |
| --- | --- | --- |
| 0 | L0 scaffold | A |
| 1 | L1a library/shell · L1b reader/sidebar/search (including script-aware search) · L1c notes/notebook/core (three agents, one simulator each, each in its own worktree) | A |
| 2 | L2 layout · L3 glossary, then the drafts for fr, es, de, it, pt-BR, uk, zh-Hans and ja (build-only, can overlap with L2) | A |
| 3 | L4 for Release A languages · L2r right-to-left (after L2 is merged) · L3 drafts for ar and hi (build-only) | A, then B |
| 4 | L5 for Release A | A ships |
| 5 | L4 for Arabic and Hindi (reviewers, smoke tests, keyboard layouts) · L5 for Release B, including adding `ar` and `hi` to `CFBundleLocalizations` | B ships |

Every L1 package changes code across one feature folder, so the three never edit the same
source file. They all add keys to the same `Localizable.xcstrings`, though. To avoid merge
conflicts in that JSON file, each L1 agent works only in Swift and lets Xcode extract the keys
at build time. The orchestrator then does one build after merging all three, which writes every
key into the catalog, and commits the catalog once. L2 and L2r edit the same view files, so they
run one after the other, never in parallel. In wave 3, L4's Release A simulator work and L2r use
two of the three simulator slots, and the ar/hi translation agents need none.
