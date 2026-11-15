# Tactile Texts: localization plan (French, Spanish, German)

Draft, 15 November 2026. Read `docs/DESIGN.md` and `docs/WORK_PACKAGES.md` first. The plan uses
the same orchestrator/subagent model as the build plan, the owner's standing rules (Opus for
every package, targeted tests only with the full gate suspended, iOS 27 simulators only, at most
three build/simulator agents at a time), and the same "Done when" style.

## Where the app stands today

The app is English only, with no localization in place.

- **No catalogs or `.lproj` folders.** `App/Info.plist` has no `CFBundleLocalizations`, and the
  packages have no `defaultLocalization`. iOS therefore runs the app in English on a French
  device, and the **system UI inside the app (Edit menu, PencilKit tool picker, share sheet,
  document picker, alerts' standard buttons) stays English too**. Declaring the localizations is
  what turns that system UI on, so it is the first step.
- **About 24,000 lines of Swift.** Roughly 200 SwiftUI literal call sites, 170 UIKit/string
  property assignments (accessibility labels and values, menu titles, error text), 16 UIKit
  menus/commands and 165 interpolated strings. Estimate: **300–450 unique strings**. L0 produces
  the exact count.
- **Strings SwiftUI won't localize on its own.** These are the main work:
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
- **English plurals written by hand.** About 10 sites use `count == 1 ? "x" : "xs"`. This fails in
  French, where 0 is singular ("0 résultat"), and the gender and case agreement in Spanish and
  German makes it worse.
- **Sentences built from pieces.** `"Searching… \(a) of \(b) pages · \(results)"`
  (`SearchPanel.swift:165`) and
  `"Notebook · \(n) notes · \(h) highlights · \(i) pages of handwriting"`
  (`NotebookPDFWriter.swift:219`) can't be translated in fragments.
- **Typography baked into code.** Twelve places hard-code English curly quotes “…”, for example
  `ImportError.swift`. French uses « … » with non-breaking spaces, German „…“, and Spanish usually
  «…». The `"p. 312"`/`"pp. 301–340"` abbreviations in `PageNumbering.label` (ReaderCore) also
  need translating, to "S. 312" in German and "pág. 312"/"págs." in Spanish.
- **ReaderCore has user-visible text.** `PageNumbering.label`, `SectionHistory.swift:52`
  (`"Page N"`) and `MarkdownExporter` (`"Front matter"`, `"Unfiled notes"`,
  `"Untitled heading"`, `"Handwritten note"`, `"**Page N**"`). That package is tested with
  `swift test` on macOS and must stay Foundation-only, so its strings need their own catalog in
  `Bundle.module`.
- **Already locale-correct.** `localizedStandardCompare` sorting, `ByteCountFormatter`, most
  `.formatted()` number calls, and the notebook PDF paper size (`measurementSystem`). Search
  folding is diacritic- and case-insensitive. Keyboard shortcuts use SwiftUI's automatic
  keyboard-layout localization. No dates are shown anywhere.
- **Tests depend on English.** UI tests contain about 426 capitalised English literals, many of
  them used as element queries next to the 104 accessibility identifiers. About 21 unit-test
  assertions and the `Tests/Fixtures/Notebook/seeded.md` golden file expect English output. Once
  the app follows the device language, these become locale-dependent.
- **Debug-only text** must stay out of the catalog: `ReaderPerfProbe`, `SidebarDebugStats`,
  `DesignSystemGallery`, the `*DebugSeed` files and `ReadingAnchor.debugDescription`.

## Decisions for the owner

Each decision has a recommendation, and packages assume the recommendation until the owner says
otherwise.

1. **App name.** Keep **"Tactile Texts"** untranslated in every language, as a brand. Only the
   App Store subtitle and description are translated.
2. **Language variants.** Ship `fr`, `es` and `de` as base languages, with no regional variants
   in version 1. iOS falls back from `fr-CA`, `es-MX`/`es-419`, `de-AT`/`de-CH` to these. Write
   Spanish in neutral Spanish that avoids Spain-only words such as *ordenador*, so it reads well
   in Latin America. Regional variants can be added later as catalog entries without code
   changes.
3. **Voice.** Match the second-person form Apple's own iPadOS system text uses in each language.
   The L3 glossary records which form that is and applies it consistently, so the app reads like
   the system around it.
4. **Who translates.** Claude drafts all three languages from a glossary and translator comments.
   A **paid native-speaker reviewer per language** then checks the strings in context, using the
   L4 screenshot sheets. Machine-only translation is not enough for App Store release.
5. **Export language.** Markdown and Notebook PDF exports use the **app's UI language at export
   time** for their fixed text ("Front matter", "Unfiled notes", page labels). Book titles,
   headings and note text are the user's own and are never translated.
6. **Page-number grouping.** Show page numbers **without grouping separators** in every language
   ("page 1234"). The library currently groups them (`formatted(.number)`) and the reader doesn't.
   Grouping would show "1 234" in French and "1.234" in German, which look odd as page numbers.
   Counts of results and notes keep locale grouping.

## Rules for every package

- **English output stays exactly the same.** English is the development language, and every
  package must leave English UI and English exports byte-identical. That makes the existing
  targeted tests the regression check for the string extraction work.
- **Use one localization API per kind of string.**
  - SwiftUI literals stay as `LocalizedStringKey` (`Text("…")`).
  - Model and logic code returns `LocalizedStringResource` or uses
    `String(localized: "…", comment: "…")`.
  - ReaderCore uses `String(localized: "…", bundle: .module, comment: "…")`.
  - `Text(verbatim:)` is only for text with no words, such as bare numbers and user content.
- **Every key has a translator comment** that says where the string appears and roughly how much
  space it has, for example "Menu bar ▸ View; toggles the Contents sidebar." Strings with
  arguments name each argument.
- **Translate whole sentences.** Never concatenate translated fragments. A sentence with several
  counts becomes one key with plural substitutions in the String Catalog.
- **Plurals always come from the catalog** (`%lld` with plural variations), never from
  `== 1 ? :`.
- **Quote marks, ellipses, middle dots and units live inside the translatable string**, so each
  language chooses its own typography.
- **Accessibility identifiers are never localized.** UI tests query by identifier, or by English
  label with the app pinned to English. Where a test currently queries a label that has no
  identifier, add an identifier rather than translating the query.
- **Never store a display string in the database.** If one is found (a default title saved as
  English text), store an empty value or a flag and produce the text at display time.

## Packages

### L0 · Localization scaffold · Opus

- `project.yml`: set `options.developmentLanguage: en`. Add `CFBundleDevelopmentRegion: en` and
  `CFBundleLocalizations: [en, fr, es, de]` to the `info:` block. Add an empty
  `App/Localizable.xcstrings` and `App/InfoPlist.xcstrings` (for `CFBundleTypeName`
  "PDF Document"; the display name stays untranslated). Confirm XcodeGen 2.46 puts the catalogs
  in the resources phase and writes `knownRegions`, and patch through `project.yml` if it
  doesn't. Check that `SWIFT_EMIT_LOC_STRINGS` is on for the app target.
- `Packages/ReaderCore/Package.swift`: add `defaultLocalization: "en"` and a
  `Resources/Localizable.xcstrings` processed resource. Confirm `swift test` on macOS still
  passes and that ReaderCore imports nothing beyond Foundation.
- **Pin tests to English.** In `UITests/Support/Fixtures.swift`, add
  `-AppleLanguages (en) -AppleLocale en_US` to every launch. In the unit-test targets, make
  English output explicit (pass `locale: Locale(identifier: "en_US")` where formatting happens,
  and read strings from the `en` bundle) so the suite passes on a simulator set to any language.
- `scripts/l10n-check.sh` uses `jq` on the `.xcstrings` JSON and fails when any of these holds:
  - a key has no `fr`, `es` or `de` value;
  - a value is still in the `new` or `needs_review` state;
  - format specifiers differ from the English value;
  - a key has no comment;
  - a value in a non-English language is identical to the English one and the key isn't marked
    "do not translate".

  Until L3, it runs in report mode and doesn't fail.
- `scripts/shot.sh` gains `--language <code>` (launch arguments `-AppleLanguages (<code>)`), plus
  the pseudolanguages `--language double` and `--language accented`.
- Write the inventory to `build/l10n-inventory.md`: every user-facing string site by file, with
  the debug-only exclusions listed. L1a–c use it as their checklist.
- **Done when** the app builds and launches with all four localizations declared, the system UI
  inside the app (Edit menu, tool picker) shows French on a French simulator, ReaderCore
  `swift test` passes, and the Library and Reader UI test classes pass on a simulator set to
  German.

### L1a · Strings: library, import, commands, shell · Opus

Owns `App/Features/Library/`, `App/Support/` (except the accessibility-identifier files),
`App/MarginalApp.swift`, `App/DesignSystem/Components.swift` and `App/Features/Reader/ReaderHost.swift`.

- Turn every user-facing literal into a catalog key with a comment. This covers the menu bar
  (`ReaderCommands.swift`), including the `CommandMenu("Go")` title and the Hide/Show ternaries,
  written as two explicit keys.
- `ImportError`: `errorDescription` and `alertTitle` come from `String(localized:)`, with the file
  name as an argument and the quote marks inside the translatable string.
- `LibraryLogic` labels become plural keys. That covers page counts, "Page X of Y" and the
  "notes and highlights" summary with its parts.
- **Done when** every site for these folders in the L0 inventory is ticked off, English UI is
  unchanged (Library and Journey UI tests pass), and the double-length pseudolanguage shows every
  string on these screens doubled, which proves none is still hard-coded.

### L1b · Strings: reader, sidebar, search · Opus

Owns `App/Features/Reader/` (except `ReaderHost.swift`), `App/Features/Sidebar/` and
`App/Features/Search/`. **Coordinate before starting.** The owner currently has uncommitted
edits in `ReaderPDFController.swift` and `UITests/ReadingPositionUITests.swift`, so this package
waits until those are committed, or leaves those files alone.

- Page pill and Go to Page: replace the `Text(verbatim: "of \(n)")` and `"Page \(n) of \(m)"`
  forms with keys. The "of N" fragment next to a text field becomes a full key such as
  `"%@ of %lld"`, laid out so that languages which put the number first still read correctly.
- `SearchPanel` status lines become single keys with plural substitutions. This covers "Searching
  … X of Y pages · N results", "Cancelled after …", "First N matches, up to page P of T" and the
  results-group accessibility label.
- The names of the Contents, Bookmarks and Pages tabs, and the "Heading title" placeholder.
- **Search behaviour** (in this package because it owns `SearchEngine`): add unit tests showing
  that folding with `locale: nil` matches *é/e*, *ß/ss* ("Straße" against "strasse"), *ñ/n* and
  German umlauts both ways. Search matches the book's text, not the UI language, so it shouldn't
  change with the UI language. If *ß* doesn't fold, add an explicit mapping on both the query and
  the page text.
- **Done when** these folders are clean in the inventory, the Reader, Sidebar and Search UI
  classes pass in English, and the new folding tests pass.

### L1c · Strings: notes, note page, notebook, highlights, markup, ReaderCore · Opus

Owns `App/Features/Notes/`, `NotePage/`, `Notebook/`, `Highlights/` and `Markup/`, plus the
user-visible text in `Packages/ReaderCore/Sources`.

- `HighlightColor.displayName` returns a `LocalizedStringResource`.
- Accessibility values ("1 stroke", "N items", "Heading level, X") become plural keys.
- `NotebookPDFWriter` header line: one key with three plural substitutions, plus a variant without
  the handwriting part. Check that Georgia renders all French, Spanish and German characters.
- ReaderCore: `PageNumbering.label` (both forms), `SectionHistory`, and all fixed text in
  `MarkdownExporter` go into the ReaderCore catalog with `bundle: .module`. Remove the duplicate
  "Untitled heading" in `NotebookFeed.swift:277` and use the ReaderCore one.
- Golden files: keep `seeded.md` as the English golden file and add `seeded.fr.md`, `seeded.es.md`
  and `seeded.de.md`. These start as placeholders and are filled once L3 lands. To run the
  exporter in a given language, pass the locale in explicitly
  (`MarkdownExporter.export(…, locale:)`) rather than relying on process state.
- **Done when** these regions are clean in the inventory, the NotePage and Notebook UI classes
  and ReaderCore `swift test` pass in English, and the English export matches `seeded.md`
  byte for byte.

### L2 · Layout under longer text · Opus

Runs after L1a–c are merged. German typically runs 30–35% longer than English, and French
punctuation needs non-breaking spaces.

- Run every screen in the **double-length pseudolanguage**: Library, Reader with the Contents and
  Notes panels, Markup, Note page, Notebook, Search, Go to Page, Add Heading, the import alerts and
  the menu bar. Check each on the 11-inch and 13-inch iPad, at full screen, ⅓ split, Stage
  Manager minimum width and the largest standard Dynamic Type size.
- Audit the 29 fixed widths and 17 `lineLimit(1)`/`fixedSize` sites. Use `ViewThatFits` or
  wrapping where the text is the user's language, and allow two lines in compact buttons and
  segmented controls. In particular, check the Notes inspector's Page note / Heading note control
  ("Notiz zur Überschrift"), the page pill, the toolbar and the sidebar tabs.
- Use leading/trailing instead of left/right everywhere it's cheap. This isn't needed for these
  three languages, but it keeps RTL support possible later.
- **Done when** `build/shots/l10n-pseudo/` holds the screenshot set with nothing clipped or
  truncated without an ellipsis, and the English shots haven't changed.

### L3 · Glossary and translations · Opus

- **Glossary first.** Write `docs/l10n/GLOSSARY.md` with one row per core term: Library, Reader,
  Contents, Notebook, Note, Page note, Heading note, Highlight, Bookmark, Markup, Heading,
  Front matter, Unfiled, Import and Resume. Give each term its French, Spanish and German form,
  matched to Apple's own Books, Notes, Preview and Files terminology (check Apple's published
  localization glossaries). Record the voice decision (decision 3) and the typography rules: «  »
  with non-breaking spaces and a space before `: ; ! ?` in French, „…“ in German.
- **Drafts.** Translate in parallel without conflicts in the catalog file. Export one XLIFF per
  language (`xcodebuild -exportLocalizations -exportLanguage fr …`), run one agent per language
  on its own `.xliff` file (these are build-only and need no simulator), then import them one
  after another (`-importLocalizations`) and let `l10n-check` validate the result. Imported
  entries keep the `needs_review` state until L4.
- Fill the French, Spanish and German golden Markdown files from the translated catalog.
- **Done when** `l10n-check` passes in strict mode apart from `needs_review` states, and the app
  builds with no missing-translation warnings.

### L4 · Review in context and locale smoke tests · Opus plus native reviewers

- Produce a screenshot sheet per language with `shot.sh --language`: every L2 screen, plus the
  alerts and the menu bar. Each screenshot sits next to its keys and the English source, ready to
  send to the reviewers.
- Apply the reviewers' fixes, set entries to `translated` and turn on strict `l10n-check`.
- `LocalizationSmokeUITests`: one test per language, run serially on one simulator, that launches
  with `-AppleLanguages (fr)` (then `es`, `de`), opens Library → Reader → Notebook by
  accessibility identifier, and checks that a few known translated labels appear and that no
  English string from a short list of distinctive ones does.
- Check the menu-bar shortcuts on the French AZERTY, Spanish and German QWERTZ hardware layouts:
  ⌘+, ⌘-, ⌘0 and ⌘9 for zoom, and ⌥⌘0 for Notes. If a shortcut is unreachable, choose an
  alternative per locale or rely on the automatic remapping.
- **Done when** all three reviewers have signed off, the smoke tests pass, and the per-app
  language picker (Settings ▸ Tactile Texts ▸ Language) switches the app correctly.

### L5 · App Store and release · Opus

- App Store Connect metadata for French, Spanish and German: subtitle, description, keywords,
  what's new and screenshots taken from the L4 shot sets. The name stays "Tactile Texts".
- Add a localization section to `docs/DEVICE_CHECKLIST.md` that runs a real device in each
  language, including Scribble with French, Spanish and German handwriting in the note editor and
  the system handwriting recognition language.
- Add a "Localization" section to `docs/DESIGN.md` with the rules above, so later packages
  create new strings localized from the start, and add `l10n-check` to the build gate.

## Waves

| Wave | Packages (parallel within a wave) |
| --- | --- |
| 0 | L0 scaffold |
| 1 | L1a library/shell · L1b reader/sidebar/search · L1c notes/notebook/core (three agents, one simulator each, each in its own worktree) |
| 2 | L2 layout · L3 glossary, then the French, Spanish and German drafts (build-only, can overlap with L2) |
| 3 | L4 review and smoke tests (waits on the native reviewers) |
| 4 | L5 App Store and release |

Every L1 package changes code across one feature folder, so the three never edit the same
source file. They all add keys to the same `Localizable.xcstrings`, though. To avoid merge
conflicts in that JSON file, each L1 agent works only in Swift and lets Xcode extract the keys
at build time. The orchestrator then does one build after merging all three, which writes every
key into the catalog, and commits the catalog once.
