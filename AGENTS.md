# AGENTS.md

Tactile Texts, an iPadOS PDF reader with Pencil markup and notes. The Xcode project, target, scheme and Swift module are `TactileTexts` and the bundle ID is `software.tactile.texts` (renamed from the working title "Marginal"; only the book-fingerprint salts keep the old name); user-facing text says "Tactile Texts".

The app is built and largely feature complete for the MVP (version 1). The initial build plan is finished and retired (16 November 2026); work now goes in as features and fixes against `docs/DESIGN.md`.

## Read first

- `docs/DESIGN.md` is the behaviour spec, with dated owner decisions. If the design looks wrong or an API is missing, stop and report; do not invent a workaround that changes behaviour. Keep it in step when behaviour changes.
- Feature plans still in progress: `docs/SCANNED_BOOKS_PLAN.md`, `docs/FORMAT_IMPORT_PLAN.md`, `docs/LOCALIZATION_PLAN.md`.
- `Backend/backup-worker/README.md` is the Worker's HTTP contract and setup.

## Owner's standing rules

These apply to every change, alongside the build, test and convention rules below.

- Every agent runs on Opus.
- Test only the region you changed (see "Build and test"); the full gate is suspended until the owner says otherwise.
- At most three agents build or use simulators at once, one booted simulator each.
- Test on the iOS 27 simulator. iPadOS 17 testing is suspended, but the deployment target stays 17.0 and fallbacks must compile. A report lists every availability-gated path it added, what its fallback does, and what is unverified at the floor.
- Windows: every view reads and commands its own window's `ReaderSession`, never a shared one, and shows changes made in another window on the same book. Ink surfaces reload when the change hub reports a write from another window, unless a stroke or edit is in progress.
- Pencil: the system `PKToolPicker` with its standard tools and the default drawing policy; nothing overrides Pencil double-tap, squeeze or hover.
- PDF exports draw ink as vector paths where the ink allows it; read-only note views render from the strokes at display scale.
- Data stays openable across versions (`docs/DESIGN.md` "Keeping data openable across versions"). It is a standing feature, not finished work: every change to the database schema, the backup format or the files beside a book keeps it working in the same change: updates never strand a library, an older version can open a newer library and a newer backup, and the tests that pin this (`LibraryDatabaseTests`, `NewerAppBackupTests`, the `.ttbackup` fixtures) pass and grow with it. A change that cannot keep that goes to the owner first.

## Layout

- `App/` app target (SwiftUI; UIKit only to bridge `PDFView` and `PKCanvasView`). Composition root is `App/Support/AppEnvironment.swift`; scenes are in `App/TactileTextsApp.swift`; one `ReaderSession` per reader window.
- `Packages/` five local SwiftPM packages, all testable on the Mac with `swift test`:
  - `ReaderCore`: pure Swift. No PDFKit, SwiftData, UIKit or PencilKit imports.
  - `ReaderStore`: SwiftData models and ink files.
  - `ReaderBackup`, `GoogleDriveKit`, `S3Kit`: Foundation and CryptoKit only.
- `Tests/` app-hosted unit tests (Swift Testing). `UITests/` XCTest UI tests.
- `Backend/backup-worker/` Cloudflare Worker (TypeScript, D1, R2), separate npm project.
- No third-party Swift dependencies. Do not add one.

## Build and test

Use the scripts, not raw `xcodebuild`: they run XcodeGen, generate fixtures, pick the simulator and write full logs to `build/`. Their console output is a filtered summary; read `build/xcodebuild-test.log` or `build/build.log` for detail.

```sh
scripts/build.sh                                   # simulator build
scripts/test.sh --packages-only                    # swift test in all five packages
scripts/test.sh --skip-packages -only-testing:TactileTextsTests/NotesPanelRulesTests
scripts/test.sh --skip-packages "-only-testing:TactileTextsTests/NotesPanelRulesTests/levelPickerListsTheWholeHeadingPath()"
scripts/test.sh --skip-packages -only-testing:TactileTextsUITests/LibraryUITests/testImportOpenBackRenameDelete
scripts/shot.sh <name> [launch args...]            # screenshot to build/shots/<name>.png
(cd Packages/ReaderCore && swift test --filter OutlineRangeTests)
```

- **Do not run the full gate** (`scripts/test.sh` with no `-only-testing`) unless asked. It is very expensive. Owner rule: build, then run only the tests for the region you changed.
- Without `--skip-packages`, `test.sh` runs all five packages' tests before the app tests, even with `-only-testing`.
- Swift Testing IDs need the trailing `()` on a test function (quote it for zsh); XCTest UI test IDs do not.
- Owner rule: at most three agents building or using simulators at once. `TACTILE_SIM` (name or UDID) picks a different simulator; the default is `iPad Pro 11-inch (M5)`.
- Timing-sensitive tests and the unit tests fail under load from parallel simulator clones; `test.sh` lists them in `MEASURING` and runs them alone. Add new timing tests to that list, and screenshot-only tests to `SCREENSHOTS`.
- Device builds: `scripts/device.sh` (needs `TACTILE_TEAM` or `Config/Local.xcconfig`). Things only a real iPad can verify (Pencil, hover, Scribble, accounts) go in `docs/DEVICE_CHECKLIST.md`.

## Project file and config

- `TactileTexts.xcodeproj` is generated from `project.yml` and git-ignored. Never edit it. New files are picked up by folder on the next `xcodegen generate`.
- `App/Info.plist` is committed but generated: change `info.properties` in `project.yml`, regenerate, commit both.
- `Config/Signing.xcconfig` is committed and holds empty defaults; secrets and the team ID go only in the git-ignored `Config/Local.xcconfig`. In xcconfig, `//` starts a comment, so hosts and URLs are written without a scheme.
- Backup integrations (iCloud, Google Drive, S3, the cloud service) are off unless `Local.xcconfig` sets them; code must work with all of them empty.

## Swift conventions that bite

- The app target sets `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` (Swift 6). Everything in `App/` is main-actor by default; value types and helpers used off the main actor are marked `nonisolated`. Packages and test targets do not have this default, so tests touching app types need `@MainActor`.
- Deployment target is iPadOS 17.0 and stays there. Newer API goes behind an availability check with a working fallback, in one small place per feature. Check availability against the installed SDK, not from memory. Only the iOS 27 simulator is tested routinely.
- The imported PDF is never modified. Ink is stored only as `PKDrawing` data in files, not in the database.
- All navigation in a reader goes through `ReaderSession.jump(...)` so section history records it. Never move the `PDFView` directly.
- SwiftData schema (`Packages/ReaderStore/.../Schema.swift`): released `VersionedSchema`s are frozen. A model change means a new version plus a stage in `TactileTextsMigrationPlan`. A new version only adds optional attributes or new models (no renames, removals or type changes), so an older build can open the store with Open in This Version (`LibraryDatabase`); set `SchemaFactory.currentVersion` to it, and `LibraryDatabaseTests.everyVersionConvertsDownToTheOneBefore` covers it.
- `Packages/ReaderBackup/Tests/.../Fixtures/*.ttbackup` pin the backup format. Never regenerate one; add a new fixture when the format version rises.
- `CFBundleDocumentTypes` in `project.yml` and `ImportContentTypes.importable` list the same formats; change them together.

## UI tests

- Launch arguments are the test contract, parsed only in `App/Support/LaunchArguments.swift` (`-resetState`, `-importFixture <host path>`, `-openBook`, `-inkAnyInput`, `-onboarding`, `-cloudBackupUITest`, and more). Add new switches there.
- The simulator cannot use the Pencil: UI tests that draw pass `-inkAnyInput`.
- Accessibility identifiers live in `App/Support/AccessibilityIDs.swift`. UI tests cannot import the app, so they repeat the strings; change both sides.
- Fixtures are generated into `Fixtures/out/` (git-ignored) by `scripts/fixtures.sh`, which `test.sh` runs. Tests read them by host path. Edit `Fixtures/make-fixtures.swift` to change them. `Tests/Fixtures/` is the committed set.
- `App/Resources/Tactile Texts Quick Guide.pdf` is generated by `scripts/make-guide.swift` and committed. `QuickGuide` looks up headings by the strings in that script; keep them in step.

## Backend (`Backend/backup-worker`)

```sh
npm test                                  # unit (Node) and worker (workerd) projects, no account needed
npx vitest run --project unit test/unit/x509.test.ts
npm run typecheck                         # src and test
```

- Top level of `wrangler.jsonc` is the `dev` deployment; `env.production` is separate. Secrets go in `.dev.vars` (git-ignored) or `wrangler secret put`, never in the file.
- Live and end-to-end tests are off unless their environment variables are set (`S3KIT_LIVE_MINT`, `TEST_RUNNER_TACTILE_BACKUP_SERVICE`); see the README.

## Repo habits

- `build-v1` is the integration branch (`main` is only the first commit). Feature branches merge into it with a merge commit.
- Commit subjects are `Area: what changed`, for example `Notes: hold a background task while a note flushes`.
- `.claude/worktrees/` holds about thirty full checkouts and `build/` holds DerivedData. Both are git-ignored; exclude them from `grep -r` and `find`, and do not edit files there by mistake.
