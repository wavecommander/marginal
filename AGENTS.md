# AGENTS.md

Tactile Texts, an iPadOS PDF reader with Pencil markup and notes. "Marginal" is the internal name only (repo, target, scheme, module, bundle ID `software.tactile.marginal`); user-facing text says "Tactile Texts".

## Read first

- `docs/DESIGN.md` is the behaviour spec, with dated owner decisions. If the design looks wrong or an API is missing, stop and report; do not invent a workaround that changes behaviour. Keep it in step when behaviour changes.
- `docs/WORK_PACKAGES.md` holds the owner's standing rules for agents. Feature plans: `docs/FORMAT_IMPORT_PLAN.md`, `docs/LOCALIZATION_PLAN.md`.
- `Backend/backup-worker/README.md` is the Worker's HTTP contract and setup.

## Layout

- `App/` app target (SwiftUI; UIKit only to bridge `PDFView` and `PKCanvasView`). Composition root is `App/Support/AppEnvironment.swift`; scenes are in `App/MarginalApp.swift`; one `ReaderSession` per reader window.
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
scripts/test.sh --skip-packages -only-testing:MarginalTests/NotesPanelRulesTests
scripts/test.sh --skip-packages "-only-testing:MarginalTests/NotesPanelRulesTests/levelPickerListsTheWholeHeadingPath()"
scripts/test.sh --skip-packages -only-testing:MarginalUITests/LibraryUITests/testImportOpenBackRenameDelete
scripts/shot.sh <name> [launch args...]            # screenshot to build/shots/<name>.png
(cd Packages/ReaderCore && swift test --filter OutlineRangeTests)
```

- **Do not run the full gate** (`scripts/test.sh` with no `-only-testing`) unless asked. It is very expensive. Owner rule: build, then run only the tests for the region you changed.
- Without `--skip-packages`, `test.sh` runs all five packages' tests before the app tests, even with `-only-testing`.
- Swift Testing IDs need the trailing `()` on a test function (quote it for zsh); XCTest UI test IDs do not.
- Owner rule: at most three agents building or using simulators at once. `MARGINAL_SIM` (name or UDID) picks a different simulator; the default is `iPad Pro 11-inch (M5)`.
- Timing-sensitive tests and the unit tests fail under load from parallel simulator clones; `test.sh` lists them in `MEASURING` and runs them alone. Add new timing tests to that list, and screenshot-only tests to `SCREENSHOTS`.
- Device builds: `scripts/device.sh` (needs `MARGINAL_TEAM` or `Config/Local.xcconfig`). Things only a real iPad can verify (Pencil, hover, Scribble, accounts) go in `docs/DEVICE_CHECKLIST.md`.

## Project file and config

- `Marginal.xcodeproj` is generated from `project.yml` and git-ignored. Never edit it. New files are picked up by folder on the next `xcodegen generate`.
- `App/Info.plist` is committed but generated: change `info.properties` in `project.yml`, regenerate, commit both.
- `Config/Signing.xcconfig` is committed and holds empty defaults; secrets and the team ID go only in the git-ignored `Config/Local.xcconfig`. In xcconfig, `//` starts a comment, so hosts and URLs are written without a scheme.
- Backup integrations (iCloud, Google Drive, S3, the cloud service) are off unless `Local.xcconfig` sets them; code must work with all of them empty.

## Swift conventions that bite

- The app target sets `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor` (Swift 6). Everything in `App/` is main-actor by default; value types and helpers used off the main actor are marked `nonisolated`. Packages and test targets do not have this default, so tests touching app types need `@MainActor`.
- Deployment target is iPadOS 17.0 and stays there. Newer API goes behind an availability check with a working fallback, in one small place per feature. Check availability against the installed SDK, not from memory. Only the iOS 27 simulator is tested routinely.
- The imported PDF is never modified. Ink is stored only as `PKDrawing` data in files, not in the database.
- All navigation in a reader goes through `ReaderSession.jump(...)` so section history records it. Never move the `PDFView` directly.
- SwiftData schema (`Packages/ReaderStore/.../Schema.swift`): released `VersionedSchema`s are frozen. A model change means a new version plus a stage in `MarginalMigrationPlan`.
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
- Live and end-to-end tests are off unless their environment variables are set (`S3KIT_LIVE_MINT`, `TEST_RUNNER_MARGINAL_BACKUP_SERVICE`); see the README.

## Repo habits

- `build-v1` is the integration branch (`main` is only the first commit). Feature branches merge into it with a merge commit.
- Commit subjects are `Area: what changed`, for example `Notes: hold a background task while a note flushes`.
- `.claude/worktrees/` holds about thirty full checkouts and `build/` holds DerivedData. Both are git-ignored; exclude them from `grep -r` and `find`, and do not edit files there by mistake.
