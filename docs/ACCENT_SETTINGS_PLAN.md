# Tactile Texts: configurable accent colour plan

Draft, 15 November 2026. Read `docs/DESIGN.md` ("Icon, accent and launch screen") first. The plan
follows the owner's standing rules: Opus for every package, targeted tests only with the full gate
suspended, iOS 27 simulators only, at most three build/simulator agents at a time.

## Goal

Let the reader choose the app's accent colour in a Settings screen. The choice applies to every
window at once, survives relaunch, and never breaks the contrast guarantees in `DESIGN.md`.

## Where the app stands today

- `AccentColor` (asset) is raspberry: `#9C3656` in Light Mode, `#F4A3BE` in Dark Mode.
  `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` points at it, so the system tint is raspberry.
- `Palette.accent`, `Palette.accentTint` and `Palette.onAccent` (`App/DesignSystem/Palette.swift`)
  are static `let`s. They are used by `Components.swift` and `DesignSystemGallery.swift`.
- `Color.accentColor` is used in about 11 places (Sidebar, Library, Search, Notes, Notebook) and
  `.tint` as a shape style in the Sidebar views.
- `Color(.onAccent)` (the `OnAccent` asset) is used in `LibraryComponents.swift` and
  `LibraryScreen.swift`.
- There is no Settings screen. The only stored preference is `@AppStorage(LibrarySort.storageKey)`
  and the Notes panel's expanded flag.
- The app icon is the berry page (`94209ee`), tied to the default accent. It does not need to
  change when the reader picks another accent.

## Decision: presets, not a free colour picker

The contrast figures in `DESIGN.md` (accent text on the app's backgrounds at least 4.96:1,
`OnAccent` on the accent at least 6.8:1 in Light and 10.8:1 in Dark) hold only for hand-checked
colours. So the choice is a fixed list of presets, each a hand-tuned quad:

| Field | Meaning |
| --- | --- |
| accent (light, dark) | Controls, selection, links, progress |
| accentTint (light, dark) | Fill behind accent text (tonal buttons, selected rows) |
| onAccent (light, dark) | Text or icon on a solid accent fill |

About eight presets, reusing the bookcloth hues: Raspberry (default, today's values), Coral,
Indigo, Viridian, Aubergine, Onyx (the shipped list; Teal and Tobacco were dropped and Graphite became Onyx on 17 November 2026). A custom picker can follow later, with the
lightness clamped so the same checks pass.

Not affected by the accent: highlighter colours, margin red, destructive red, book cloth, ink and
paper.

## Slices (in order)

### 1. Model

- `AccentChoice` enum (`String`, `CaseIterable`, `Identifiable`) in `App/DesignSystem`, holding the
  quads above and a display name.
- Stored in `UserDefaults` under `settings.accent` (`@AppStorage` in views). Unknown or missing
  values fall back to Raspberry.
- An `AccentTheme` value (accent, tint, onAccent as `Color`s) derived from the choice and injected
  through the SwiftUI environment from `TactileTextsApp`.

Done when: unit tests cover the enum round trip and the fallback.

### 2. Apply it everywhere

- `Palette.accent`, `accentTint` and `onAccent` stop being static: they become reads of the theme
  (or `Palette` gains theme-taking variants and the components use those). The static `let`s cannot
  react to a change.
- Apply `.tint(theme.accent)` at all three `WindowGroup` roots in `TactileTextsApp.swift`.
- Migrate `Color.accentColor` (about 11 sites) and `Color(.onAccent)` (2 sites) to the theme.
  First check whether `Color.accentColor` follows `.tint`; if it does, only the `onAccent` sites
  and `Palette` need to move.
- Set `UIWindow.tintColor` for each scene, because UIKit surfaces (PDFKit selection handles,
  menus, alerts, the PencilKit tool picker) do not take the SwiftUI tint. `WindowSceneReader`
  in `WindowRootView` already has the scene and can do this, and update it when the choice changes.
- Keep the `AccentColor` asset as the default; it still drives the launch frame before SwiftUI
  mounts.

Done when: changing the stored value changes the tint in every open window without a relaunch,
including sheets, popovers, the Markup toggle and the tool picker.

### 3. Settings screen

- iPadOS has no system Settings entry for this app, so add an in-app Settings sheet: a gear button
  in the Library toolbar, and a `⌘,` command in `ReaderCommands` (`CommandGroup(replacing: .appSettings)`)
  that opens it.
- First section, Appearance: a grid of swatches (selected one marked with a check, with an
  accessibility label per preset), a live preview (primary button, tonal button, selected row,
  progress bar), and "Reset to Raspberry".
- No `Settings.bundle`, so there is one place for preferences, not two.
- New accessibility identifiers go in `AccessibilityIDs.swift`.

Done when: the sheet opens from the toolbar and from `⌘,`, and picking a swatch updates the
preview and the whole app at once.

### 4. Tests (targeted)

- Unit (extend `Tests/DesignSystemTests.swift`): for every preset and both appearances, accent
  text on `paper` and `surface` at least 4.5:1, `onAccent` on accent at least 4.5:1, accent text on
  `accentTint` at least 4.5:1.
- UI: open Settings, pick a swatch, check the tint changes in a second window, relaunch, check it
  persisted. Add a launch argument `-accent <preset>` for other UI tests and clear the key under
  `-resetState`.
- `DesignSystemGallery` shows every preset, so a screenshot review covers them all.

### 5. Docs

Update "Icon, accent and launch screen" in `docs/DESIGN.md`: the accent is the user's choice from
a preset list, Raspberry is the default, and the `AccentColor` asset is only the default and the
launch fallback. Its claim that "nothing in `App/` hard-codes another blue" stays true.

## Open questions

- Does `Color.accentColor` follow `.tint` on iOS 17 and 27? Answer this first; it decides the
  size of slice 2.
- Presets only, or a custom picker later? Recommended: presets first.
- Optional extra: an alternate home-screen icon per preset (`setAlternateIconName`). iOS shows a
  system alert on every icon change, so if it is added it should be a separate, opt-in control,
  not tied to the accent swatch.

## Risks

- A missed `Color.accentColor` or `Color(.onAccent)` site keeps the old raspberry or leaves
  low-contrast text on a new accent. Search for both before finishing slice 2.
- UIKit-hosted surfaces can ignore the SwiftUI tint; slice 2's `UIWindow.tintColor` is what
  covers them, so test the tool picker and the text selection handles explicitly.
- Light accents (the Dark Mode values) need the dark `onAccent`; the preset quads must include it,
  not assume white.
