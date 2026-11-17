# Tactile Texts: cloud sync findings (C0)

Package C0 of `docs/CLOUD_SYNC_PLAN.md`, 17 November 2026. No feature code. Every later package
reads this first. Each finding says how it was established: **measured** (run here),
**read** (from the code or the installed SDK), **documented** (the vendor's documentation, not
run), or **not verified**.

Environment: Xcode 27.2, iOS 27.2 simulator SDK, wrangler 4 from the Worker's lockfile,
Node 24.21.

## Summary

| Question | Answer | How |
| --- | --- | --- |
| Do conditional writes behave as sync needs, under a race? | Yes, on the real development bucket with the Worker's temporary credentials, and on `wrangler dev`'s local S3 endpoint. | measured on both |
| Does `wrangler dev`'s local S3 endpoint honour them? | Yes, so C3 and C4 can test against it. | measured |
| Does `S3Kit` send conditional headers and return ETags? | ETags from list and head: yes. Conditional `PutObject`, the ETag of a put, and a 412 the caller can tell apart: no. C3 adds them. | read |
| Can a stroke be recognised as the same on another device? | Yes: identity is computed from the stroke's own data, and a three-way stroke merge with a base already exists for both page ink and note ink. One new risk found (ink from a newer iPadOS). | read; existing tests |
| Does Google return an ID token carrying our nonce? | Documented yes. Not run: this checkout has no Google client ID. `GoogleDriveKit` cannot send a nonce or read an ID token yet. | documented; read |
| How long does a background task get? | Not measurable here. Plan for seconds, not minutes, and for being cut off. | not verified |
| Is anything availability-gated? | No. Everything named exists at iPadOS 17.0. | read from the SDK |

## 1. Conditional writes

`Backend/backup-worker/scripts/prove-conditional-writes.ts` (new; `npm run prove:conditional`)
checks, in one throwaway folder that it empties afterwards:

- `PutObject` with `If-None-Match: *` creates an absent key and returns an ETag; a second one
  gets `412 PreconditionFailed` and changes nothing.
- Put, head, get and `ListObjectsV2` report the same ETag for an object, quotes included, so the
  one cheap listing sync polls with is enough to know which heads changed.
- `PutObject` with `If-Match: <current ETag>` replaces; with a stale ETag, or on a key that does
  not exist, it gets 412.
- Twelve concurrent creates of one key: exactly one 200, eleven 412. Twelve concurrent replaces
  from one ETag: exactly one 200, eleven 412, and the stored object is the winner's.
- Putting the same bytes twice without a condition succeeds both times with the same ETag, so
  re-uploading a content-named blob is harmless.

**Measured against `wrangler dev --port 8797` (local): all twelve checks pass.**

**Measured against the real development bucket (`tactile-texts-backups-dev`), 17 November
2026: all twelve checks pass**, with the same statuses and codes as locally, including one
winner in each race of twelve.

```sh
cd Backend/backup-worker && npm run prove:conditional
```

It uses the Worker's own `createTempCredentials` with the `read-write` action list and a
prefix limited to the test folder, so it also shows that those credentials need no new
permission for conditional writes. This agrees with Cloudflare's documentation ("Conditional
operations" and "Consistency model", read the same day): conditions are evaluated atomically at
commit, and competing conditional writes to one key are serialised. `npm run prove` (the
existing scoped-credentials proof) was run at the same time and also passes.

The parent token for these runs was made the same day with the owner's go-ahead: a user API
token named "tactile-texts-backups-dev: object read and write (local development)", limited to
that bucket's objects, kept only in the git-ignored `Backend/backup-worker/.dev.vars`.

Two things for C3 from writing the script:

- **Encode each path segment on its own.** A key sent with an encoded slash (`Sync%2Fv1%2F…`)
  was refused by the local endpoint with `SignatureDoesNotMatch`; the same key with literal
  slashes was accepted. `S3Kit` must be checked for which it sends before sync keys with three
  slashes go through it (today's keys have one).
- **A timed-out put is ambiguous.** Cloudflare documents the reconciliation: retry the same
  conditional request; on 412, read the object back and compare a write ID in its metadata.
  Sync heads should carry one (`x-amz-meta-write-id`), so a device can tell "I already won" from
  "someone else did".

## 2. `S3Kit`

Read from `Packages/S3Kit/Sources/S3Kit/`:

| Needed by sync | Today |
| --- | --- |
| ETag of every object in a listing | `S3ObjectSummary.eTag` (from `ListObjectsV2`). Present. |
| ETag from `HeadObject` | `S3ObjectHead.eTag`. Present. |
| `PutObject` with `If-Match` / `If-None-Match` | Missing. `put(data:key:metadata:)` takes no conditions. |
| ETag of the object a put stored | Missing. `put` returns nothing. |
| 412 as its own error | Missing for puts. (Ranged downloads already send `If-Match` and treat 412 as "the object changed, start again", and the signer already signs `If-Match`.) |
| A small object read into memory with its ETag | Missing. There is only `download(key:to:)` to a file. A head is a few kilobytes and is read with its ETag in one request. |

All four gaps are small additions to one file and are C3's, with stub-server tests beside the
existing ones. Nothing in `S3Kit` is R2-specific.

## 3. Stroke identity and the ink merge

Read from `App/Features/NotePage/NoteInk.swift`, `App/Features/Markup/StrokeMerge.swift` and
`PageInkMerge.swift`:

- **Identity** (`StrokeIdentity`) is the stroke path's creation date to the microsecond, its
  point count, the stroke's random seed, and its first and last points. All of it is read from
  the decoded `PKStroke`, nothing is assigned by the app, so the same drawing bytes give the
  same identities on any device. Equal identities are told apart by order of occurrence.
- **It survives encoding**: the existing tests decode a saved drawing and match strokes
  (`PageInkPersistenceTests`, `StrokeMergeOrderTests`, `BackupMergeTests`).
- **The three-way merge the plan asked C4 to write already exists.** `StrokeMerge.merge(local:
  remote:base:)` serves page ink and note ink, and is what keeps two windows consistent today.
  Its rules: a stroke added on either side is kept; a stroke erased on one side is removed only
  if the other left it unchanged; edited on one side, that side's version; edited on both, local
  wins; with no base, the union. Order is the remote order, then local-only strokes on top.
- **It converges across devices.** "Local wins" sounds as if two devices could disagree, but the
  base moves: after the first device pushes, its base is its own version, so when the second
  device's version arrives it reads as changed on the remote side only and is adopted. The last
  device to push wins a stroke both edited. The plan's table says "the account's version wins"
  for other fields; for strokes it is the reverse, and both settle.
- **Partial erasing** gives the remaining pieces new identities (different point counts and end
  points), which the merge reads as one stroke removed and others added. Correct.

So C4 needs no new ink merge. It needs the **base ink** for a page or note at merge time, which
is the plan's "fetch the base blob, else union".

**New risk: ink made on a newer iPadOS.** Nothing in the app reads PencilKit's content version
(`PKDrawing.requiredContentVersion`, no uses in `App/`). A drawing that uses an ink type from a
newer system may load on an older one with those strokes missing. Between windows on one iPad
that cannot happen; with sync it can, and it would be read as "erased here" and deleted on
every device. Rule for C4, to be confirmed on real devices: a page or note whose stored drawing
needs a higher content version than this system supports is shown as far as it can be, is not
editable, and is **never pushed**. This is a device check (two iPads on different iPadOS
versions) and goes in `docs/DEVICE_CHECKLIST.md` with C4.

## 4. Sign in with Google

- **Documented** (Google's OpenID Connect guide): the authorisation request accepts `nonce`, the
  token response to a code exchange with scope `openid` includes `id_token`, and the token
  carries the `nonce` claim. iOS clients use PKCE with no secret, as `GoogleDriveKit` does.
- **Not run.** `Config/Local.xcconfig` here sets only signing; there is no Google client ID, and
  the flow needs a person to sign in. First on C2's device checklist.
- **Read** from `Packages/GoogleDriveKit`: `GoogleAuthorizationRequest` builds a fixed parameter
  list with no `nonce`, and nothing parses `id_token` from the token response. C2 adds both.
  The scope list is already configurable (`GoogleOAuthConfiguration.scopes`), so asking for
  `openid email` instead of Drive access needs no change there.
- The Worker must check `aud` against the iOS client ID and should accept both of Google's
  issuer spellings (`accounts.google.com` and `https://accounts.google.com`).

## 5. Sign in with Apple and StoreKit, from the installed SDK

Read from the iOS 27.2 SDK's headers and Swift interface:

| API | Available from |
| --- | --- |
| `ASAuthorizationAppleIDProvider`, credential state, the revoked notification | iOS 13.0 |
| `ASAuthorizationOpenIDRequest.nonce` | iOS 13.0 |
| `ASAuthorizationAppleIDCredential.identityToken`, `.authorizationCode` | iOS 13.0 |
| `Product.PurchaseOption.appAccountToken(_:)` | iOS 15.0 |
| `Transaction.appAccountToken` | iOS 15.0 |

No availability-gated path is needed, so there is no fallback to describe and nothing
unverified at the 17.0 floor from this list. The authorization code is what the Worker
exchanges to revoke on account deletion and when leaving Apple.

Neither Sign in with Apple nor App Attest can be exercised usefully in the simulator; C1 and C2
test with generated keys and fakes, as the Worker's App Attest and App Store tests already do.

## 6. Background time

Not measurable in the simulator or without a device. What the code already does
(`BackupScheduler`): it takes a background task assertion, and when the system says time has
run out it cancels the run and schedules a `BGProcessingTask`. Sync follows the same shape, and
the design does not depend on the answer:

- a push is uploads of content-named blobs, then one small conditional put. Cut off anywhere,
  the next round skips blobs that are already there and carries on;
- the base moves only after the head is written, so an interrupted round is simply repeated.

What to measure on a device with C4: how much of a typical change (one note, one page of ink)
reaches the account in the time after the app is put away. If it is routinely not enough, the
remedy is to push sooner while in front (the plan's "a few seconds after a change settles"),
not to ask for more background time.

## What changes in the plan

- **C3** gains the four `S3Kit` additions in section 2, per-segment key encoding, and a write
  ID on heads.
- **C4** loses "three-way page-ink merging" (it exists) and gains the content-version rule in
  section 3.
- **C2** gains `nonce` and `id_token` in `GoogleDriveKit`.
- Nothing found stops the design, and nothing is owed from C0. Three answers wait for real
  devices and are listed with the package that needs them: Google's nonce (C2), ink from a
  newer iPadOS and background time (C4).
