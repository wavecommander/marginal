# Tactile Texts: accounts, automatic backup and sync plan

Written 17 November 2026 for the owner's request: the paid version gets automatic, end-to-end
encrypted backup **and sync**, stored in Cloudflare R2, with Sign in with Apple and Sign in with
Google as the sign-in. Nothing here is built. The owner settled the seven open decisions the same
day ("Owner decisions" below); `docs/DESIGN.md` changes only as each package lands.

## What already exists, and is kept

Most of the backup half is built ("Tactile Texts Cloud" in `docs/DESIGN.md`,
`Backend/backup-worker/README.md`). The plan builds on it and does not replace it.

| Exists today | Where | Used by this plan as |
| --- | --- | --- |
| Worker that verifies the subscription and App Attest and signs 15-minute R2 credentials limited to one user's folder and to named S3 actions | `Backend/backup-worker` | Unchanged core. Gains accounts and sign-in in front of it. |
| Encryption on the iPad: AES-256-GCM in chunks, a key per file, keyed-hash object names, a key-check object | `ReaderBackup` (`BackupFileEncryption`, `EncryptedBackupDestination`, `BackupEncryptionKey`) | The same key and file format encrypt sync objects, with new derived sub-keys. |
| The key in iCloud Keychain plus a 56-character recovery key, and the "never make a new key while data exists" rule | `BackupKeyStore`, the recovery key views | Unchanged. Signing in never gives access to data; only the key does. |
| Snapshot backups, restore preview, per-book merge, Undo Last Restore, daily automatic backup | `App/Features/Backup` | The backup half. Sync is added beside it, not instead of it. |
| Merge of two copies of a book: notes paragraph by paragraph, ink by stroke identity, highlights, bookmarks, headings | `ReaderCore/Merge`, `App/Features/Backup/Merge` | The base of the sync merge. `NoteInk.merge(local:remote:base:)` already takes a common ancestor. |
| One change signal for records and ink, carrying who made the change | `StoreChangeHub` | How sync learns a book changed, and how windows learn sync changed a book. |
| A book whose PDF is absent ("PDF missing", Locate PDF…) | Library, `DocumentLinking` | How a synced book appears before its PDF has been downloaded. |
| ~~Google OAuth with PKCE, no SDK~~ | Removed with `GoogleDriveKit` on 17 November 2026 (the Google Drive destination went; Files reaches Drive). The code is in history at `bd7dd50^`. | Not available. C2 writes a small sign-in-only OAuth flow; see "Changes that landed underneath this plan". |

### Changes that landed underneath this plan

**17 November 2026, "Backup: iCloud Drive and Google Drive go through the Files pickers"**
(`bd7dd50`). The app's own iCloud container and Google Drive destinations are gone, with the
`GoogleDriveKit` package, the iCloud entitlements file and the Google client ID build setting.
What is left is the backup file, the folder picked in Files, the build-time S3 bucket and
Tactile Texts Cloud. Checked against this plan:

- **Sign in with Google loses the code it was going to reuse.** C2 now builds it: the
  authorisation request with PKCE and a nonce, the redirect check, and one code exchange that
  returns the ID token, shown in an `ASWebAuthenticationSession`. That is a fraction of what
  was removed (no Drive client, no refresh, no token store, since sign-in keeps no Google
  token), and the request builder, PKCE, form encoding and stub server can be taken from
  `bd7dd50^` rather than rewritten. It lives in a small Foundation-and-CryptoKit package so it
  is tested on the Mac like the rest.
- **The app again holds a Google OAuth client**, for identity only (`openid email`), not
  Drive. Owner decision, 17 November 2026, made after the removal: Sign in with Google stays.
- **No entitlements file is left in the repository.** Sign in with Apple needs one. C2 adds a
  committed file holding only the Sign in with Apple entitlement; `Config/Local.xcconfig` still
  switches it on through `TACTILE_ENTITLEMENTS`, and a build without it has no Apple button.
- **The key is not affected.** It travels by iCloud Keychain (a synchronisable Keychain item),
  which never used the iCloud container or its entitlement. Still a real-device check, as before.
- **Nothing in sync, the Worker or the formats changes.** The folder layout, `.ttbackup` files,
  `EncryptedBackupDestination` and the cloud service are as they were; the commit's edits to
  `ReaderBackup` are comments. C1, C3a and C3b, which were started from the commit before it,
  are unaffected apart from two one-line merges for C3b (the package list in `scripts/test.sh`
  and in `AGENTS.md`, now four packages plus `ReaderSync`).
- **A reader who used the removed destinations for automatic backup** now has none selected.
  Automatic cloud backup "on by default for a signed-in subscriber" covers them once they
  subscribe, and nothing else in the plan depended on those destinations.

What is missing is three things: an **account** (today the user is the subscription itself), a
**sync engine** (today two iPads never merge, and a merge brings deletions back), and the
**remote layout** that lets two devices write the same book safely with no server in the data
path.

## Owner decisions this plan replaces

Recorded in `docs/DESIGN.md`; the owner confirmed replacing them on 17 November 2026. The text
there changes with the package that builds each one.

1. **"Identity is the App Store subscription … There is no account, sign-in, email address or
   password"** (15 November 2026). Replaced by an account the reader signs in to with Apple or
   Google. The subscription becomes what pays for the account, not who the reader is. Still no
   password, and the service still stores no name or email address (see "Accounts").
2. **"This is backup, not sync: two iPads do not merge"** (15 November 2026) and "iCloud sync"
   under "Not in version 1". Sync is added for subscribers. Backup and restore keep working
   exactly as they do, for every destination.
3. **"Deletions come back"** in a merge. Still true for restoring a backup. Not true for sync,
   which carries deletions between devices (see "How a book is merged").

## Owner decisions (17 November 2026)

1. **No existing subscribers.** The app is pre-launch, so nothing is carried over from the
   subscription-named folders: the Worker's identity model is replaced outright, with no
   adoption path and no compatibility with the current `/v1/session` body.
2. **Sign-in is required for all of Tactile Texts Cloud**, backup and sync alike. Everything
   the service receives is behind the sign-in and encrypted on the iPad first; nothing readable
   leaves the device for it. The rest of the app stays account-free and the welcome sheet's "no
   account" stays true. (Read here as a rule for the service. Whether the other destinations,
   which are not encrypted by the app today, should be is a separate question and not planned.)
3. **Deleting a book on one iPad deletes it on the others**, and the account keeps it for 30
   days under Recently Deleted, restorable from any device.
4. **The reading position syncs**: the page only, applied when the book is next opened and
   never to a window that is open. The exact place and zoom stay per device.
5. **PDFs download automatically on Wi-Fi**, with a setting for "only when I open the book".
   Notes and ink always sync; they are small.
6. **Sync is part of the existing subscription products**: no new tier, one offer page, one
   allowance.
7. **An account has one sign-in at a time**, Apple or Google, never both. There are flows to
   change from one to the other and to sign out of every device, and neither they nor any other
   sign-in change removes or locks the readable library on an iPad (see "Changing the sign-in
   and signing out").

## Accounts and sign-in

- **What an account is.** A row in the Worker's database with a random ID, a random folder
  name, and exactly one identity. An identity is `HMAC(server secret, provider ‖
  subject)`, where the subject is the stable user ID inside Apple's or Google's signed ID
  token. The Worker stores no email address and no name; the app shows the email from the ID
  token on the device that signed in and nowhere else.
- **Signing in.** The app asks the Worker for a challenge, then asks Apple
  (`ASAuthorizationAppleIDProvider`) or Google (an authorisation-code flow with PKCE in an
  `ASWebAuthenticationSession`, scope `openid email`) for an ID token whose `nonce` is the
  SHA-256 of that challenge. The Worker verifies the token's signature against the provider's
  published keys (fetched and cached), the issuer, the audience (the bundle ID for Apple, the
  iOS client ID for Google), the expiry and the nonce, and the App Attest assertion as today.
  It answers with a **device session**: a random token whose hash it stores, kept on the iPad
  in the Keychain, this device only.
- **Every later request** carries the device session and an App Attest assertion. The signed
  subscription transaction is sent when the app has one, to attach or refresh the entitlement.
- **The subscription pays for one account.** Purchases made after this ships set StoreKit's
  `appAccountToken` to the account's token, so the signed transaction names its account. A
  transaction without one is bound to the first account that presents it. Moving a
  subscription to another account is allowed once every 30 days, so one subscription cannot
  serve many accounts. Lapse, read-only and deletion rules are unchanged and now hang off the
  account.
- **Devices.** The account screen lists signed-in devices (names are encrypted with the backup
  key, so the Worker cannot read them).
- **Deleting the account** (App Store guideline 5.1.1(v)) is in the app: it asks the reader to
  sign in again, empties the folder, removes the account and its identities, and for Apple
  exchanges the fresh authorization code and calls Apple's revoke endpoint. It says the
  subscription is not cancelled and points to Manage Subscription.
- **Apple's requirements.** Sign in with Apple is offered wherever Google is, at equal weight
  (guideline 4.8). Apple's server-to-server notifications (consent revoked, Apple Account
  deleted) end the sessions of that identity. The app checks `getCredentialState` at launch.
- **Build settings.** Off unless `Config/Local.xcconfig` sets them, as every integration is:
  the Sign in with Apple entitlement, in a committed entitlements file that C2 adds and
  `TACTILE_ENTITLEMENTS` names (the repository has had none since 17 November 2026), and
  `GOOGLE_SIGNIN_CLIENT_ID`. With either missing that button is absent; with both missing the
  service reports itself not available.

### Changing the sign-in and signing out

The rule under all of these (owner decision 7): **the library on an iPad is ordinary local
data, readable without an account, and no sign-in change touches it.** Signing out, changing
the sign-in, an expired session, a lapsed subscription and a deleted account all leave every
book, note and stroke on the iPad exactly as they were, open and editable. Only the service
stops.

- **Sign Out (this iPad).** Ends this device's session. Sync and automatic cloud backup stop;
  the library stays. The key stays in the Keychain and the sync base is kept, so signing back
  in to the same account carries on where it left off, sending what was done meanwhile, with
  no join. The confirmation says the books stay on this iPad and are no longer backed up.
- **Sign Out of All Devices.** Ends every session of the account at once. Each other iPad
  finds out at its next request, shows itself signed out, and keeps its library the same way.
  Nothing in the account's folder is removed.
- **Change to Sign in with Google / Apple.** From the account screen, while signed in: the
  reader confirms with the current sign-in, then signs in with the other one, and the Worker
  swaps the account's identity in one step, so the account, its folder, its subscription and
  its key are the same before and after and there is never a moment with two sign-ins or none.
  When leaving Apple, the Worker revokes the Apple authorisation with the code from that
  confirmation. Other devices stay signed in (sessions belong to the account, not to the
  provider); they need the new sign-in only the next time they sign in.
  - If the new Apple or Google identity already has an account of its own, the change is
    refused and says so; the reader deletes that account first if it is theirs.
  - If the second step is cancelled or fails, nothing changed and the old sign-in still works.
- **Signing in to a different account** on an iPad that has synced with another: the library
  stays, the first account's base is set aside, and the iPad joins the new account through the
  add-only merge after its confirmation, like any device with books of its own.
- **Lost access to the provider** (a closed Google account, say) with no device still signed
  in: the account cannot be reached and there is no back door, by design. Every iPad still has
  its library, and a new account can take it up by joining. The offer page and the account
  screen say this where they explain the recovery key.

## The key

Unchanged, and worth stating because sign-in makes it easy to assume otherwise: **the account
decides who may reach the folder; the key decides who can read it.** A new iPad signed in to
the account sees that data exists and waits for the key from iCloud Keychain or asks for the
recovery key, exactly as today. A reader who signs in with Google on an iPad using a different
Apple Account needs the recovery key there. Nobody, the owner included, can read or recover a
library without one of the two.

One change: the Keychain item is stored per account, so signing out and in to another account
on the same iPad cannot pair one account's key with another's data.

## Backup

The snapshot backup to Tactile Texts Cloud stays as it is and becomes **on by default for a
signed-in subscriber** (daily, when the library has changed). It is what protects a reader from
sync itself: a deletion or a bad merge that sync has faithfully copied everywhere is undone by
restoring a snapshot. Snapshots and sync share one set of PDF objects, so a PDF is stored once.

## Sync

### The model

Each device keeps, for every synced book, a **base**: the records and the hash of every ink
file as they were when that device last agreed with the account. A sync round compares three
things, base, this iPad and the account, and works out what each side did since:

- changed here only: upload it;
- changed in the account only: apply it here;
- changed on both: merge (rules below);
- present in the base and gone from one side: deleted there, so delete it on the other, unless
  the other side edited it since, in which case the edit wins.

Nothing has to record each edit as it happens. A deletion is "it was in the base and is not
here now", so the database needs **no schema change and no tombstones**, a crash loses nothing
(the base moves forward only after a round succeeds), and edits made by an older version of the
app with sync switched off are still found the next time a version with sync runs. The base
lives in `Application Support/Sync/<account>/`, outside the book's own directory, so backups,
restores and older versions never see it.

A device with no base for a book (a new iPad, or the first sync of a library that already has
books) **joins**: the existing add-only merge runs, so nothing is removed on either side, after
one confirmation that says how many books each side has and how many are the same.

### What is in R2

Under the account's folder, beside `Backups/` and `PDFs/`:

    Sync/v1/books/<book key>            the book's head: one small encrypted object
    Sync/v1/blobs/<keyed hash>          immutable encrypted content, named by its hash
    Sync/v1/history/<book key>/<n>      earlier heads, kept 30 days
    PDFs/<keyed hash>.ttenc             the PDF, shared with snapshot backups

- The **book key** is a keyed hash of the PDF's SHA-256, so two iPads that imported the same
  file separately find the same book. Two separately converted copies of an EPUB have different
  PDFs and are two books, as the restore rules already say.
- The **head** lists the book's metadata, a version number, and the hash of everything that
  makes up the book now: one records blob (the same JSON as a backup's `records.json`), one
  blob per inked page and per note's ink, the cover, `conversion.json`, and the PDF. A deleted
  book's head says so, with the date, for 30 days.
- A **blob** is written once and never changed. Uploading the same content twice is a no-op.

### How two devices write one book safely

R2 evaluates `If-Match` on `PutObject` atomically (Cloudflare's "Conditional operations",
confirmed 17 November 2026). A push uploads the new blobs, then writes the head **only if its
ETag is still the one this device read**. If another device got there first the write fails
with 412; this device pulls, merges and tries again. No server coordinates, no file data
passes through the Worker, and the temporary credentials need no new permissions.

Finding out what changed is one `ListObjectsV2` of `Sync/v1/books/`, which returns every head's
ETag; a head whose ETag this device already has is skipped.

### How a book is merged

Three-way, extending `BookMerge` with the base. When only one side changed something, that
side's version is taken. When both did:

| | Both sides changed it |
| --- | --- |
| Note text | Paragraphs merged three-way; a paragraph both sides reworded appears in both wordings, this iPad's first (the existing rule). |
| Note ink, page ink | By stroke: strokes either side added are kept, strokes either side erased are removed. If the base ink can no longer be fetched, the union (the existing rule; an erased stroke may return). |
| Highlight colour, heading title, page or parent, book title | The account's version wins, so every device settles on the one that synced first. |
| Bookmarks | A set of pages: additions and removals from both sides apply. |
| Edited on one side, deleted on the other | The edit wins. |
| Reading position | The later one, by date. |

The merge is a pure function in `ReaderCore` with the same kind of generated-archive tests as
`BookMerge`, plus the property that matters for sync: **two devices that apply the same changes
in either order end with the same book.**

### On the iPad

- **Applying a change.** Sync writes through `LibraryStore` with its own change origin, record
  by record and file by file, so open windows reload what they show exactly as they do for a
  change from another window. It never replaces a whole book, so windows stay open. A note or
  page with a stroke or edit in progress is skipped for that round and merged on the next.
- **One job at a time still holds.** Sync pauses while a backup or restore runs. After a
  restore, the next round carries the result to the account like any other local change, so
  Replace with Backup does replace the book everywhere; the restore confirmation says so when
  sync is on.
- **When it runs.** Shortly after a change settles (a few seconds, and at once when the app
  goes to the background, inside a background task); when a window becomes active; every two
  minutes while the app is in front; and from the existing background task. No push
  notifications in the first version.
- **PDFs.** Uploaded once per file. Downloaded per decision 5; until then the book shows in the
  Library with a download state in place of "PDF missing", and opening it downloads it first.
  Large transfers respect Low Data Mode.
- **Subscription states.** Read-only (lapsed) and over-allowance sessions pull but do not push;
  local work continues and is pushed when the state clears. The banners that exist say so.
- **What the reader sees.** A Sync switch and status line on the Tactile Texts Cloud page (up
  to date, syncing, waiting for the network, paused with the reason), a small state on each
  Library book that is not yet up to date, and Recently Deleted. No per-conflict prompts.

### Versions

Sync is a fourth kind of stored data and follows "Keeping data openable across versions":

- Heads and records carry a format version and the **level of the newest app that wrote them**.
  A newer app's unknown keys are ignored when reading, as in backups.
- An app older than a book's level **pulls but does not push that book**, because writing it
  back would drop what the newer app stored. It says the iPad needs updating to send changes.
- A higher format version than the app knows stops sync for that account with the same
  message, and changes nothing.
- Checked-in fixtures of a `Sync/v1` folder pin the format, as the `.ttbackup` fixtures do.

### What the operator can and cannot see

Cannot: any text, ink, title, file name, device name, or which PDF a book is. Can: how many
books and inked pages an account has, object sizes, and when each device syncs. A device
remembers the highest version of each head it has seen and refuses an older one, so the store
cannot silently roll a book back.

## Worker changes

- **Database** (new migration): `accounts` (one identity each, unique across accounts) and
  `device_sessions`; `subscribers` is keyed to the account it pays for. Pre-launch, so the
  subscription-named folders and `userKey.ts` go, with nothing to carry over.
- **Endpoints**: `POST /v1/auth/apple`, `/v1/auth/google`, `/v1/auth/change` (proof from the
  current identity and a token from the new one; one transaction), `/v1/auth/signout`,
  `/v1/auth/signout-all`; `GET /v1/account`; `POST /v1/account/delete`;
  `POST /v1/apple/signin-notifications`. `/v1/session` and `/v1/delete-my-data` take the
  device session in place of the bare transaction. Credentials, prefixes, modes, the allowance and the cron are unchanged.
- **Secrets and settings**: `IDENTITY_KEY_SECRET`; the Sign in with Apple key (key ID and
  private key, for the revoke call); `GOOGLE_CLIENT_IDS`. The Worker now makes outbound
  requests it did not before: the two providers' key sets, and Apple's token and revoke
  endpoints.
- `README.md` is the contract and changes in the same commits.

## Packages

**Status, 17 November 2026:** C0 is done; its answers are in `docs/CLOUD_SYNC_FINDINGS.md`,
and the rows below were corrected from it. C1, C3a (the three-way merge) and C3b (`S3Kit`
additions and the `ReaderSync` foundations) are built, each on its own agent branch with its
tests rerun and passing, and none is merged: `worktree-agent-abd5d46db9e349b2e` (C1),
`worktree-agent-a9f3116cda09011a5` (C3a), `worktree-agent-a0760c082fa584ef8` (C3b). C3c (the
sync round and the simulated-device tests) is in progress on top of C3a and C3b. C2, C4 and C5
are not started. Nothing has been checked on a real iPad or against real Apple or Google
sign-in.

C0 runs first and alone. C1 and C3 can then run in parallel (Worker and Swift packages share
nothing); C2 follows C1; C4 follows C2 and C3; C5 follows C4. Standing rules in `AGENTS.md`
apply to every package.

| Package | What it is | Where |
| --- | --- | --- |
| C0 | Findings, no feature code. Against the development bucket with real temporary credentials: `If-Match` and `If-None-Match` on `PutObject` behave as documented under a race, and whether `wrangler dev`'s local S3 endpoint honours them (if not, tests use a fake store and the real bucket). Whether `S3Kit` already sends conditional headers and returns ETags from list, head and get. That Google returns an ID token carrying our `nonce` to an iOS client with PKCE. How page-ink stroke identity is derived today and whether it survives a save and reload on another device. How long a background task really gets. | `docs/CLOUD_SYNC_FINDINGS.md` |
| C1 | Accounts in the Worker: the migration, ID token verification for both providers, device sessions, changing the sign-in, entitlement binding with `appAccountToken`, sign-out of one device and of all, account deletion with Apple revocation, Apple's sign-in notifications. | `Backend/backup-worker` |
| C2 | Sign-in in the app, and the existing cloud backup moved onto accounts: both sign-in buttons, the account screen (the sign-in and Change, devices, Sign Out, Sign Out of All Devices, delete), the per-account Keychain item, purchase with `appAccountToken`, Sign in with Google as a new small package `GoogleSignInKit` (PKCE, nonce, one code exchange for the ID token; `GoogleDriveKit` was removed on 17 November 2026, its OAuth pieces are in history at `bd7dd50^`), the Sign in with Apple entitlements file, automatic backup on by default for subscribers, `-cloudBackupUITest` states for signed-out and signed-in. | `App/Features/Backup/CloudService`, `App/Features/Backup/UI`, `Packages/GoogleSignInKit`, `Config/` |
| C3 | Sync core, testable on the Mac. In `ReaderCore`: the three-way book merge and the diff against a base. A new Foundation-and-CryptoKit package `ReaderSync`: head and blob formats, the encrypted object store with conditional writes, the push and pull round with retry on 412, the base store, rollback refusal, the version rules, a write ID on each head so a timed-out put can be reconciled. `S3Kit` (C0 found them missing): `If-Match` and `If-None-Match` on a put, the ETag a put stored, 412 as its own error, a small object read into memory with its ETag, and keys encoded segment by segment. | `Packages/ReaderCore`, `Packages/ReaderSync`, `Packages/S3Kit` |
| C4 | Sync in the app: the engine wired to `LibraryStore` and `StoreChangeHub`, page and note ink merged with the existing `StrokeMerge` given the base ink (C0: the three-way merge already exists), a page or note whose ink needs a newer PencilKit content version than this iPad has shown but never edited or pushed, applying changes under open windows, the join, scheduling, PDF upload and download, the download state in the Library, the Sync switch and status. | `App/Features/Sync`, hooks in `App/Features/Library` and `App/Features/Backup` |
| C5 | Safety and housekeeping: Recently Deleted, head history and "restore this book to an earlier day", removal of blobs and PDFs nothing refers to (only when older than seven days, so an upload in flight is never removed), the end-to-end test against `wrangler dev`, `docs/DEVICE_CHECKLIST.md` entries, `docs/DESIGN.md` brought in step. | App, `Backend/backup-worker`, `docs/` |
| Later | Silent push so another device syncs within seconds (needs an APNs key in the Worker and device tokens); a web or Mac reader, which is what Sign in with Google mostly prepares for. | |

Done when:

- **C1**: Worker tests sign in with generated Apple and Google key sets; refuse a wrong
  audience, issuer, nonce, expired token and a replayed challenge; change an account from
  Apple to Google and back with the folder and subscription unchanged, refuse a change to an
  identity that has an account, and leave the old sign-in working when the change fails
  half-way; never hold two identities on one account; end one session and all sessions; bind,
  refuse and move a subscription; delete an account and leave nothing in D1 or R2. `npm test`
  and `npm run typecheck` pass.
- **C2**: UI tests sign in with the fake service and back up; sign out, sign out of all
  devices, change the sign-in, and meet an expired session, and after each one open a book and
  edit a note with the library intact; sign back in and carry on without a join; delete the
  account. A build with all settings empty shows no sign-in anywhere.
- **C3**: `swift test` covers the merge properties (same result in either order; no change when
  both sides are equal; no base behaves as today's merge; a deletion travels; an edit beats a
  deletion) and the engine with two and three simulated devices doing random edits offline and
  online, with a fault injected at every step of a round, ending equal. The sync fixtures load.
- **C4**: an app test runs two libraries in one process against one store: a note, a highlight,
  page ink and a deletion each cross over; an edit in an open window on the receiving side
  is not lost. A UI test turns Sync on and sees a second book arrive.
- **C5**: a deleted book returns from Recently Deleted on the other device; housekeeping
  removes an orphaned blob and keeps a fresh one; the end-to-end test passes against the
  development bucket.

## Risks and what is not yet verified

- **Stroke identity across devices** is the one thing that could change the ink rules: if a
  stroke cannot be recognised as the same after a round trip, erasing would not sync and ink
  conflicts would always be unions. C0 answers it before C3 depends on it.
- **Sign in with Apple and App Attest do not work in the simulator** in a useful way. Tests use
  fakes; the real flows, key arrival through iCloud Keychain on a second iPad, and two real
  iPads syncing are device checks.
- **Background time** is the system's to give. A change made just before the iPad is put away
  may reach the account only when the app is next opened; the status line says when a device
  last synced.
- **Clocks** matter only for the reading position and for which wording comes first in the
  history view. No merge rule that keeps or drops work depends on a device's clock.
- **Availability-gated paths**: none planned. Everything named exists at iPadOS 17.0; C0
  confirms against the installed SDK.
- **Cost**: polling is one list request per device every two minutes while the app is open,
  well under a cent per device per month at R2's published prices. Ink history is bounded by
  the 30-day window and counts toward the reader's allowance.

## Not in this plan

Sharing a book or notes with another person, collaboration, a web reader, syncing preferences
or window state, syncing recognised text for scanned books (each device recognises its own
copy, as now), and sync to any destination other than Tactile Texts Cloud.
