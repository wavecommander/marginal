# Tactile Texts cloud backup service

A Cloudflare Worker that lets the production app back up to the owner's R2 bucket without the
app ever holding a storage key. Design: `docs/DESIGN.md`, "Cloud backup service", and
`docs/CLOUD_SYNC_PLAN.md`, "Accounts and sign-in".

The reader signs in with Apple or Google to an **account**. The App Store subscription pays for
the account; it is not who the reader is. The iPad asks the Worker for a session. The Worker
checks the device's session, the account's subscription and that the request comes from the
genuine app (App Attest), then returns R2 credentials that last 15 minutes and reach only the
account's folder. Backups then go directly between the iPad and R2. They are encrypted on the
iPad first, so neither this service nor Cloudflare can read them.

The service stores no name, no email address and no provider user ID: an identity is kept only
as a keyed hash, and every other name for an account is random.

## Layout

| Path | What it is |
| --- | --- |
| `src/index.ts` | Entry point: `fetch` and the daily `scheduled` cron. |
| `src/service.ts` | The routes, the session and delete-my-data endpoints, App Store notifications, the cron. |
| `src/accounts.ts` | Sign-in, changing the sign-in, sign-out, the account screen, account deletion, Sign in with Apple notifications. |
| `src/requestAuth.ts` | The checks every attested request goes through: challenge, App Attest, device session. |
| `src/entitlement.ts` | Which account a subscription pays for: binding, refusing and moving subscriptions. |
| `src/contract.ts` | The HTTP contract below, as exported TypeScript types and error codes. |
| `src/idToken.ts` | Verifies Apple's and Google's ID tokens (and, in `dev` only, the dev test issuer's) and Apple's sign-in notifications; fetches and caches their key sets. |
| `src/appleSignIn.ts` | Revokes a Sign in with Apple authorization (client secret, token exchange, revoke). |
| `src/identity.ts` | Keyed hashes of identities and subscriptions; random account, folder and session names. |
| `src/appleJws.ts` | Verifies App Store JWS: transactions, renewal info, server notifications. |
| `src/appAttest.ts` | Verifies App Attest attestations and assertions. |
| `src/x509.ts`, `src/der.ts`, `src/cbor.ts` | Minimal, strict certificate, DER and CBOR readers. |
| `src/appleRoots.ts` | Apple's pinned root certificates. |
| `src/subscription.ts` | Subscription state, "newest wins" updates, the lapse policy. |
| `src/storage.ts`, `src/usage.ts` | The account's folders in R2: usage counting, deletion in bounded batches. |
| `src/db.ts` | D1 queries. |
| `src/tempCredentials.ts` | Mints the short-lived, scoped credentials (R2 local signing). |
| `src/env.ts` | Bindings, settings and secrets, parsed and checked (`readSettings`). |
| `src/http.ts`, `src/log.ts` | Responses, body limits, refusals; logging that cannot leak. |
| `migrations/` | D1 schema. `0003_accounts.sql` replaces the subscription-keyed table with accounts; `0004_deleted_folders.sql` keeps deleted accounts' folder names until their last credentials expire. |
| `test/unit/` | Plain Node tests of the pure modules (includes Apple's own App Attest sample). |
| `test/worker/` | Tests inside the Workers runtime with local D1 and R2, generated sign-in keys and a stand-in for Apple's revoke endpoints. |
| `scripts/prove-scoped-credentials.ts` | Checks the credentials against a real development bucket. |
| `wrangler.jsonc` | The `dev` deployment (top level) and `env.production`. |

## Working on it

```sh
npm install
npm test             # unit and Workers-runtime tests, no account needed
npm run typecheck    # source and tests
npm run migrate:local
npm run dev          # wrangler dev: local D1 and a local R2 bucket (needs .dev.vars)
```

`wrangler dev` also serves the local bucket over S3 at
`http://localhost:8787/cdn-cgi/local/r2/s3` with the fixed keys in `wrangler.jsonc`, so the
app's S3 client can be tested against it. That endpoint does not evaluate session tokens, so
the scoping itself is proved against a real bucket:

```sh
cp .dev.vars.example .dev.vars    # fill in; a development bucket and a token limited to it
npm run prove
```

### The app against `wrangler dev` (end to end)

`TactileTextsTests/BackupCloudServiceEndToEndTests` runs the app's own client against a local
`wrangler dev` that mints real temporary credentials for the real development bucket: a backup,
restore and account deletion, and sync between two libraries in one process (including Recently
Deleted and housekeeping). It removes everything it wrote. The
simulator has neither App Attest nor a way to get a real Apple or Google ID token for a test
run, so the test uses the `dev` deployment's two development switches: the App Attest bypass,
and the dev test issuer (below), which it signs in through by minting its own tokens. What it
needs in `.dev.vars`, beyond the bucket:

- `APP_ATTEST_BYPASS_SECRET`: any 32+ random characters (`openssl rand -hex 24`). The
  simulator has no App Attest.
- `DEV_TEST_SIGNIN_SECRET`: any 32+ random characters (`openssl rand -hex 24`), different from
  the bypass secret. Turns on the dev test issuer.
- `APPLE_TEAM_ID`: required by the settings check even when App Attest is bypassed; any 10
  uppercase letters or digits will do locally.
- `IDENTITY_KEY_SECRET`: any 32+ random characters.
- `GOOGLE_CLIENT_IDS`: the app's iOS OAuth client ID, to sign in with real Google tokens. Not
  needed for dev test tokens, which stand in for Google without it.
- `XCODE_STOREKIT_CERT`: the certificate StoreKit Testing signs transactions with. **Getting it
  without the Xcode UI:** a test-session transaction's JWS carries it as the only entry of its
  header's `x5c` (base64 DER, self-signed, "StoreKit Testing in Xcode"). The app's test
  `writeStoreKitTestCertificate` buys through an `SKTestSession` and writes that entry to a file:

  ```sh
  TEST_RUNNER_TACTILE_STOREKIT_CERT_OUT=/tmp/storekit-cert.txt \
    scripts/test.sh --skip-packages \
    "-only-testing:TactileTextsTests/BackupCloudServiceEndToEndTests/writeStoreKitTestCertificate()"
  echo "XCODE_STOREKIT_CERT=$(tr -d '\n' < /tmp/storekit-cert.txt)" >> .dev.vars
  ```

  Measured (Xcode 27, iOS 27 simulator): the certificate is the same across test sessions and
  runs on one simulator, valid for a year from when it was made; another simulator or Mac may
  have its own, so take it from the simulator the tests run on. It is public, not a secret.

Then:

```sh
npm run migrate:local
npx wrangler dev --port 8797 --ip 127.0.0.1
# in the repository root, with the two secrets from .dev.vars:
TEST_RUNNER_TACTILE_BACKUP_SERVICE=127.0.0.1:8797 \
TEST_RUNNER_TACTILE_BACKUP_SERVICE_BYPASS=<APP_ATTEST_BYPASS_SECRET> \
TEST_RUNNER_TACTILE_BACKUP_SERVICE_DEV_SIGNIN=<DEV_TEST_SIGNIN_SECRET> \
  scripts/test.sh --skip-packages -only-testing:TactileTextsTests/BackupCloudServiceEndToEndTests
```

To sign in from the app itself in the simulator against `dev` (a local `wrangler dev` or the
development deployment), a debug build can set `BACKUP_SERVICE_DEV_SIGNIN` to the
`DEV_TEST_SIGNIN_SECRET` in `Config/Local.xcconfig`. That is for development only: the value
ends up in the built app, so never set it for a build that leaves your Mac, and never reuse a
secret that a deployment you care about holds.

### The dev test issuer

A sign-in identity provider for development only, so the simulator and end-to-end tests can sign
in without a real Apple or Google ID token. It is on only on the `dev` deployment with
`DEV_TEST_SIGNIN_SECRET` set; production refuses to start if that setting exists at all, and
the Worker checks the environment again each time it sees such a token. It does not change how
Apple's and Google's tokens are verified.

Wherever an endpoint takes an ID token (`idToken` of `/v1/auth/apple`, `/v1/auth/google` and
`/v1/account/delete`; `currentIdToken` and `newIdToken` of `/v1/auth/change`), a dev test token
may be sent instead and **stands in for the provider that endpoint expects** (the one the path
names, the account's current provider, or `newProvider`). The account's `provider` is then that
provider, and everything else (sessions, the authorization code needed when leaving Apple, the
revocation, which is skipped with a log line without a Sign in with Apple key) works as for a
real sign-in. Sign in with Apple notifications never accept dev test tokens.

**Its own identities.** A dev test token's subject is hashed in its own namespace,
`dev-test:apple` or `dev-test:google` in place of `apple` or `google` (see `src/identity.ts`).
So a dev test token can never reach, prove or take over an account made with a real Apple or
Google sign-in, even with the same `sub`: signing in makes a separate account, and as proof for
a real account (or a real token as proof for a dev test account) it is `identity-mismatch`.
Google sign-in with dev test tokens works even without `GOOGLE_CLIENT_IDS`.

**The token**, which the app's debug build and its end-to-end test mint themselves: a compact
JWS (JWT), `base64url(header) "." base64url(payload) "." base64url(signature)`, unpadded
base64url (RFC 7515), at most 8 KiB.

- Header, exactly: `{"alg":"HS256","typ":"JWT"}` (`typ` may be left out; no `crit`).
- Signature: HMAC-SHA256 over the ASCII bytes of `base64url(header) "." base64url(payload)`,
  keyed with the **UTF-8 bytes of `DEV_TEST_SIGNIN_SECRET`** as given (not hex- or
  base64-decoded); 32 bytes.
- Payload claims:

  | Claim | Value |
  | --- | --- |
  | `iss` | `tactile-texts-dev-test`, exactly. |
  | `aud` | `APP_BUNDLE_ID` (`software.tactile.texts`), as a string (or a one-element array), for Apple and Google alike. |
  | `sub` | The test identity: 1 to 255 characters, no NUL. Same `sub`, same account (per provider). |
  | `nonce` | As for real ID tokens: lower-case hex SHA-256 of this request's base64-decoded challenge bytes. |
  | `iat` | Issue time, seconds since 1970 (a number). Not more than a minute in the future. |
  | `exp` | Expiry, seconds; after `iat` and at most 600 seconds (10 minutes) after it; refused from a minute past it. |
  | `email` | Optional, ignored. Any other claim is ignored too. |

Anything else (another algorithm, issuer, audience, nonce, a bad signature, an expired or
too-long-lived token) is `401 id-token-invalid`, as is any dev test token in production or in
`dev` without the secret. An HS256 token claiming Apple's or Google's issuer is refused
everywhere. A `signed-in` log line made through it says `"issuer": "dev-test"`; logs never hold
the secret, the token or its subject.

Two things differ from a deployment, because `wrangler dev`'s `BUCKET` binding is the *local*
bucket while the credentials reach the real one: usage always counts 0, and
`/v1/delete-my-data` and `/v1/account/delete` empty the local folders (answering `done` at
once), so a test removes the real objects itself with the folder's credentials. Test purchases
land under `sandbox/<folder key>/`.

## HTTP contract

All request and response bodies are JSON (`Content-Type: application/json`, UTF-8). Times are
ISO 8601 in UTC. Base64 is standard base64 with padding unless it says base64url. Bodies over
64 KiB are refused. Every response carries `Cache-Control: no-store`. Unknown fields in a
request are ignored. The TypeScript types are in `src/contract.ts`.

### Errors

Every non-2xx response has this shape:

```json
{ "error": { "code": "subscription-lapsed", "message": "Your subscription has ended. ..." },
  "subscription": { ... } }
```

`code` is stable and is what the app branches on; `message` is a sentence for a person.
`subscription` (the `SubscriptionInfo` object below) is present only with
`subscription-revoked`, `subscription-lapsed` and `data-deleted`. Errors never contain internal
details.

| Status | `code` | Message | When |
| --- | --- | --- | --- |
| 400 | `bad-request` | The request was not understood. | Malformed JSON, a missing or mistyped field, `action` not matching the endpoint, a field a step needs (for example Apple's authorization code). |
| 404 | `not-found` | No such endpoint. | |
| 405 | `method-not-allowed` | That method is not allowed here. | Wrong method; the `Allow` header lists the right one. |
| 413 | `body-too-large` | The request is too large. | Over 64 KiB. |
| 415 | `unsupported-media-type` | Send the request as JSON. | Content type is not `application/json`. |
| 401 | `challenge-invalid` | The request expired. Try again. | Challenge unknown, already used, or older than five minutes. Get a new one. |
| 401 | `attestation-invalid` | This copy of the app could not be verified. | `/v1/attest` refused the attestation. |
| 409 | `device-already-attested` | This device is already registered. | The key ID is already registered; use it. |
| 401 | `device-unknown` | This device needs to be registered again. | No attested key with that ID: generate a key and attest again. |
| 401 | `assertion-invalid` | This copy of the app could not be verified. | Assertion missing, invalid, or its counter did not increase. |
| 401 | `id-token-invalid` | The sign-in could not be verified. Try again. | An ID token failed verification: signature, key, issuer, audience, expiry, issue time, subject, or its `nonce` is not this request's challenge. |
| 403 | `provider-disabled` | This way of signing in is not available. | Google sign-in on a deployment with no `GOOGLE_CLIENT_IDS`. |
| 503 | `provider-unreachable` | Apple or Google could not be reached. Try again later. | The provider's signing keys could not be fetched. |
| 401 | `session-invalid` | You have been signed out. Sign in again. | No such device session (signed out, signed out everywhere, ended by Apple, or the account was deleted), or it was made with another App Attest key. |
| 403 | `identity-mismatch` | Confirm with the sign-in this account uses now. | The ID token given as proof is not the account's current sign-in. |
| 409 | `identity-in-use` | That sign-in already has an account of its own. | Changing to an Apple or Google identity that has its own account. |
| 409 | `account-deleting` | This account is being deleted. | The account's deletion has started (sign-in, session, account screen, delete-my-data, change). |
| 403 | `not-subscribed` | This account has no subscription to Tactile Texts Cloud. | `/v1/session` for an account with no subscription; send the transaction. |
| 403 | `subscription-other-account` | This subscription was bought for another account. | The newest transaction's `appAccountToken` is another existing account's. |
| 403 | `subscription-in-use` | This subscription is in use by another account. | Bound to another account less than `SUBSCRIPTION_MOVE_DAYS` ago. |
| 401 | `transaction-invalid` | The subscription could not be verified. | The signed transaction or renewal info failed verification (signature, chain, bundle, fields, a malformed `appAccountToken`), or the renewal info is for another subscription. |
| 403 | `product-unknown` | This purchase does not include cloud backup. | Not an auto-renewable subscription to a product in `PRODUCT_ALLOWANCES`. |
| 403 | `environment-not-accepted` | Purchases from this environment are not accepted here. | E.g. a `Production` purchase sent to the `dev` deployment. |
| 403 | `subscription-revoked` | This subscription was refunded or revoked. | Apple refunded it or revoked it (Family Sharing). No access. |
| 403 | `subscription-lapsed` | Your subscription has ended. Resubscribe to restore access to your backups before they are deleted. | Ended `READ_ONLY_DAYS` or more ago, less than `DELETE_AFTER_DAYS`. Data kept until `subscription.deleteAfter`. |
| 403 | `data-deleted` | Your subscription ended and its backups have been deleted. | Ended `DELETE_AFTER_DAYS` or more ago. |
| 401 | `notification-invalid` | The notification could not be verified. | `/v1/apple/notifications` and `/v1/apple/signin-notifications` only. |
| 500 | `internal` | Something went wrong. Try again later. | Includes a misconfigured deployment. |

### `GET /v1/health`

`200 {"ok": true, "environment": "dev" | "production"}`. Answers `500 internal` if any setting
is missing or malformed, so a bad deployment shows at once.

### `POST /v1/challenge`

No body (or `{}`). Returns a single-use challenge valid for five minutes, used by `/v1/attest`
and by every attested request, and bound into sign-in ID tokens as their `nonce`.

`200 {"challenge": "<base64 of 32 random bytes>", "expiresAt": "2026-11-15T12:05:00.000Z"}`

### `POST /v1/attest`

Registers this app install's App Attest key, once (after `DCAppAttestService.generateKey`).

```json
{ "keyId": "<base64 key ID from generateKey>",
  "challenge": "<from /v1/challenge>",
  "attestation": "<base64 attestation object>" }
```

The app calls `attestKey(keyId, clientDataHash:)` with
`clientDataHash = SHA-256(base64-decoded challenge bytes)`.

`201 {"keyId": "<as sent>", "environment": "production" | "development"}`

Errors: `bad-request`, `challenge-invalid`, `attestation-invalid`, `device-already-attested`.
The production deployment accepts only production App Attest keys from App Store or TestFlight
builds; `dev` also accepts development keys and builds.

### Attested requests

Every endpoint below except `/v1/apple/*` is an attested `POST`. The body always has:

```json
{ "action": "<names the endpoint, see each>",
  "challenge": "<from /v1/challenge, single use>",
  ... }
```

and its exact bytes are the App Attest `clientData`. Headers:

| Header | Value |
| --- | --- |
| `X-App-Attest-Key-Id` | The attested key ID (base64). |
| `X-App-Attest-Assertion` | `generateAssertion(keyId, clientDataHash: SHA-256(body bytes))`, base64. |
| `X-App-Attest-Bypass` | `dev` deployment only, instead of the two above (the simulator has no App Attest): the `APP_ATTEST_BYPASS_SECRET`. Production ignores it. |

Requests made while signed in also carry `"deviceSessionToken": "<from sign-in>"` in the body
(not a header, so the assertion covers it). A device session works only with the App Attest
key that signed the sign-in; on another key it is `session-invalid` (in `dev`, a session made or
used through the bypass is not tied to a key).

The order of checks: body and fields; the challenge (consumed even if a later check fails);
the assertion (signature over the body, App ID, counter strictly greater than the last one
seen); the device session; then the endpoint's own checks (ID tokens, signed transaction).

**ID tokens.** Wherever an endpoint takes an ID token, it must be fresh from Apple
(`ASAuthorizationAppleIDCredential.identityToken`, UTF-8) or Google (the `id_token` from the
code exchange, scope `openid`), requested with
`nonce = lower-case hex SHA-256(base64-decoded challenge bytes)` of this request's challenge.
For Apple, set `ASAuthorizationAppleIDRequest.nonce` to that string; for Google, pass it as the
`nonce` parameter. The Worker checks the RS256 signature against the provider's published keys,
the issuer (`https://appleid.apple.com`; Google `accounts.google.com` or
`https://accounts.google.com`), the audience (Apple: the bundle ID; Google: one of
`GOOGLE_CLIENT_IDS`, and `azp` too when present), the expiry and issue time (a minute's skew)
and the nonce. So a token is good for one request only. On the `dev` deployment with
`DEV_TEST_SIGNIN_SECRET` set, a dev test token may stand in for either provider's (see "The dev
test issuer").

### Signing in: `POST /v1/auth/apple`, `POST /v1/auth/google`

```json
{ "action": "auth-apple" | "auth-google",
  "challenge": "...",
  "idToken": "<ID token, nonce from this challenge>",
  "authorizationCode": "<Apple only, optional: accepted, not used at sign-in>",
  "deviceLabel": "<optional: base64, at most 1,024 characters>" }
```

Signs in to the identity's account, creating it on the first sign-in, and starts a device
session. `deviceLabel` is this device's name encrypted by the app (with the backup key); the
Worker stores it as given, cannot read it, and shows it in the account's device list.

`200`:

```json
{ "deviceSessionToken": "<43 characters, base64url>",
  "sessionId": "<32 hex digits>",
  "newAccount": true,
  "account": { ...AccountResponse, see /v1/account } }
```

`deviceSessionToken` is shown once: keep it in the Keychain, this device only. The Worker keeps
only its hash. A session lasts until it is signed out (it has no expiry of its own).

Errors: `bad-request`, `challenge-invalid`, `device-unknown`, `assertion-invalid`,
`id-token-invalid`, `provider-disabled`, `provider-unreachable`, `account-deleting`.

### `POST /v1/auth/change`

Changes the account's one sign-in to the other provider. The reader confirms with the current
sign-in, then signs in with the other one; both ID tokens carry this request's challenge as
`nonce` (so both are fetched after the challenge, within its five minutes).

```json
{ "action": "auth-change",
  "challenge": "...",
  "deviceSessionToken": "...",
  "currentIdToken": "<fresh ID token from the account's current sign-in>",
  "currentAuthorizationCode": "<required when the current sign-in is Apple>",
  "newProvider": "apple" | "google",
  "newIdToken": "<fresh ID token from the new provider>" }
```

`newProvider` must differ from the current one (`bad-request` otherwise). The swap is one
database statement: the account never holds two identities or none, and if any step fails
nothing changed and the old sign-in still works. The account, its folder, its subscription,
its `appAccountToken` and every device session stay as they were; other devices need the new
sign-in only the next time they sign in. The old identity no longer reaches the account
(signing in with it makes a new, empty account). When leaving Apple, after the swap the Worker
exchanges `currentAuthorizationCode` and revokes the Apple authorization; a failure there is
logged and does not undo the change.

`200`: the `AccountResponse`, with the new `provider`.

Errors: `bad-request`, `challenge-invalid`, `device-unknown`, `assertion-invalid`,
`session-invalid`, `account-deleting`, `id-token-invalid`, `identity-mismatch` (the current
token is not the account's sign-in), `identity-in-use` (the new identity has its own account:
delete that account first if it is the reader's), `provider-disabled`, `provider-unreachable`.

### `POST /v1/auth/signout`, `POST /v1/auth/signout-all`

```json
{ "action": "auth-signout" | "auth-signout-all", "challenge": "...", "deviceSessionToken": "..." }
```

`signout` ends this device's session; `signout-all` ends every session of the account, this
one included. Each other device finds out at its next request (`session-invalid`). Nothing in
the account or its folders changes.

`200 {"ok": true, "endedSessions": 1}`

Errors: `bad-request`, `challenge-invalid`, `device-unknown`, `assertion-invalid`,
`session-invalid`.

### `POST /v1/account`

The account screen. `POST`, not `GET`, because App Attest signs a body.

```json
{ "action": "account", "challenge": "...", "deviceSessionToken": "...",
  "deviceLabel": "<optional: sets this device's encrypted name>" }
```

`200` (`AccountResponse`):

```json
{
  "accountId": "<32 hex digits>",
  "provider": "apple" | "google",
  "appAccountToken": "6f9619ff-8b86-d011-b42d-00c04fc964ff",
  "createdAt": "2026-11-15T12:00:00.000Z",
  "devices": [
    { "sessionId": "<32 hex>", "createdAt": "…", "lastUsedAt": "…", "label": "<as sent>" | null, "current": true }
  ],
  "subscription": { ...SubscriptionInfo } | null,
  "usage": { ...UsageInfo } | null
}
```

- `accountId` is random; it names the account to the app (for example its Keychain item).
- `appAccountToken`: pass it on **every** purchase,
  `Product.PurchaseOption.appAccountToken(UUID(uuidString:))`, so the signed transaction names
  the account (see "Which account a subscription pays for").
- `devices`, oldest first; `current` marks the one asking.
- `subscription` and `usage` are what a session without a transaction would be served from
  (see `/v1/session`), or null without a subscription. Usage is counted as for a session.

Errors: `bad-request`, `challenge-invalid`, `device-unknown`, `assertion-invalid`,
`session-invalid`, `account-deleting`.

### `POST /v1/account/delete`

Deletes the account (App Store Review Guideline 5.1.1(v)): empties both its folders, then
removes its device sessions, its subscription entitlements and the account itself. It does not
cancel the App Store subscription; say so and point to Manage Subscriptions.

```json
{ "action": "account-delete", "challenge": "...", "deviceSessionToken": "...",
  "idToken": "<first call: fresh ID token from the current sign-in>",
  "authorizationCode": "<first call, Apple only: that sign-in's authorization code>" }
```

The **first call** needs the ID token (`identity-mismatch` if it is another identity's) and, for
an Apple account, the authorization code (`bad-request` without either). It is the point of no
return: the account is marked as being deleted, every other device's session ends, and for
Apple the Worker exchanges the code and revokes the Apple authorization (a failure is logged and
the deletion goes on). Each call then deletes a bounded batch (up to 100,000 objects). Call
again, with a new challenge and assertion but no new sign-in, until `done` is true. While the
deletion runs, sign-in with the identity, `/v1/session`, `/v1/account`, `/v1/auth/change` and
`/v1/delete-my-data` answer `account-deleting`; `/v1/auth/signout` and
`/v1/auth/signout-all` still work. A Sign in with Apple `consent-revoked` notification (which
the Worker's own revocation causes) does not end the deleting device's session. If the app
stops before `done`, the daily cron finishes the deletion (after 15 minutes).

When `done` is true the account is gone: its identity, its `appAccountToken`, its sessions (this
one included) and its subscription binding. The same person can sign in again at once and gets a
new, empty account with a new folder; the subscription binds to it as for any first presenter (a
token naming the deleted account counts as no token). Credentials minted before the deletion
started still work for up to `CREDENTIAL_TTL_SECONDS`, so the Worker keeps the deleted account's
**folder name only** (no account ID, identity or token) in `deleted_folders` until
65 minutes after the deletion started (the one-hour maximum `CREDENTIAL_TTL_SECONDS` may be set
to, plus 5 minutes, whatever it is set to now); the next daily cron after
that empties both folders once more and forgets the name. No account can reach those folders
meanwhile: folder names are random and never reused. A `/v1/session` request that was under way
when the deletion started looks at the account again just before minting and answers
`account-deleting` (or `session-invalid` if the account is already gone), so no credential is
minted after a deletion starts.

`200 {"done": true | false, "deletedObjects": 2300}`

Errors: `bad-request`, `challenge-invalid`, `device-unknown`, `assertion-invalid`,
`session-invalid`, `id-token-invalid`, `identity-mismatch`, `provider-unreachable`.

### `POST /v1/session` → `200`

```json
{ "action": "session",
  "challenge": "...",
  "deviceSessionToken": "...",
  "signedTransaction": "<optional: StoreKit Transaction.jwsRepresentation of the backup subscription>",
  "signedRenewalInfo": "<optional, only with signedTransaction: its RenewalInfo JWS>" }
```

Send `signedTransaction` whenever the app has one (the current entitlement): it binds the
subscription to the account and brings the stored state up to date. Without it, the session is
served from what the account already has; an account with nothing answers `not-subscribed`.
Send `signedRenewalInfo` when the app has it (`Product.SubscriptionInfo.Status.renewalInfo`):
without it, Apple's billing-retry and grace periods cannot count until a server notification
reports them.

```json
{
  "mode": "read-write",
  "credentials": {
    "accessKeyId": "…",
    "secretAccessKey": "…",
    "sessionToken": "…",
    "expiresAt": "2026-11-15T12:15:00.000Z"
  },
  "storage": {
    "endpoint": "https://<account id>.r2.cloudflarestorage.com",
    "host": "<account id>.r2.cloudflarestorage.com",
    "region": "auto",
    "bucket": "tactile-texts-backups",
    "prefix": "users/<64 hex digits>/"
  },
  "subscription": {
    "state": "active",
    "environment": "Production",
    "productId": "software.tactile.texts.backup.standard",
    "expiresAt": "2026-12-01T00:00:00.000Z",
    "endedAt": null,
    "readOnlyUntil": null,
    "deleteAfter": null
  },
  "usage": {
    "bytes": 123456,
    "allowanceBytes": 10737418240,
    "overAllowance": false,
    "countedAt": "2026-11-15T12:00:00.000Z"
  }
}
```

- **Credentials.** Sign S3 requests (SigV4, region `auto`, service `s3`) with `accessKeyId` and
  `secretAccessKey`, and send `sessionToken` as `X-Amz-Security-Token` (signed). They work only
  under `storage.prefix`, only in `storage.bucket`, only for the mode's operations, and until
  `expiresAt` (`CREDENTIAL_TTL_SECONDS`, 15 minutes). Ask for a new session before then.
- **`mode`** and the S3 operations it allows:
  - `read-write`: HeadObject, GetObject, ListObjectsV2, PutObject, DeleteObject,
    CreateMultipartUpload, UploadPart, CompleteMultipartUpload, AbortMultipartUpload.
  - `read-delete` (active but over the allowance, so the user can make room): HeadObject,
    GetObject, ListObjectsV2, DeleteObject, AbortMultipartUpload.
  - `read-only` (ended less than `READ_ONLY_DAYS` ago: restore only): HeadObject, GetObject,
    ListObjectsV2.
- **`storage.prefix`**: each account has two folders with the same random name, its folder key:
  `users/<folder key>/` for `Production` purchases and `sandbox/<folder key>/` for `Sandbox`
  (App Review, TestFlight) and `Xcode` ones, which also get the small `SANDBOX_ALLOWANCE_BYTES`.
  The presented transaction's environment picks the folder; without one, the folder whose
  subscription gives the most access (the `users/` one on a tie). Every object key the app uses
  must start with the prefix. The folder key never changes, whatever happens to the sign-in or
  the subscription.
- **`subscription.state`**: `active`; `grace-period` (Apple's billing grace period);
  `billing-retry` (Apple retrying a failed renewal, counted as active for at most 60 days after
  the expiry); `ended` (expired, gave up retrying, or the subscription moved to another
  account); `revoked`. `expiresAt` is the end of the paid period Apple last reported; `endedAt`,
  `readOnlyUntil` and `deleteAfter` are null while active.
- **`usage`**: the sum of object sizes under the prefix, counted through the bucket binding and
  reused for `USAGE_CACHE_SECONDS` (5 minutes). `overAllowance` is `bytes > allowanceBytes`
  (exactly at the allowance is still within it). A folder of more than 100,000 objects is not
  counted in full and is treated as over the allowance.

The lapse policy, measured from when access ended (`endedAt`: the expiry, or when Apple's
billing retry or grace period ended, or the revocation date, or when the subscription moved to
another account):

| Time since `endedAt` | Result |
| --- | --- |
| before it (active, grace period, billing retry) | `200`, `read-write` (or `read-delete` over the allowance) |
| 0 to `READ_ONLY_DAYS` (exclusive) | `200`, `read-only` |
| `READ_ONLY_DAYS` to `DELETE_AFTER_DAYS` (exclusive) | `403 subscription-lapsed` with the dates; resubscribing restores access to the same folder |
| `DELETE_AFTER_DAYS` and after, or once deleted | `403 data-deleted`; the daily cron deletes the folder |
| refunded or revoked | `403 subscription-revoked`; the cron deletes the folder `DELETE_AFTER_DAYS` after the revocation |

A subscription that becomes active again after its data was deleted starts with an empty folder.

Errors: `bad-request`, `challenge-invalid`, `device-unknown`, `assertion-invalid`,
`session-invalid`, `account-deleting`, `not-subscribed`, `subscription-other-account`,
`subscription-in-use`, `transaction-invalid`, `product-unknown`, `environment-not-accepted`,
`subscription-revoked`, `subscription-lapsed`, `data-deleted`.

#### Which account a subscription pays for

A subscription is found by a keyed hash of its environment and original transaction ID (never
the raw ID). When a verified transaction is presented:

1. **Its `appAccountToken`** (the token on the newest transaction the Worker knows for that
   subscription) decides first. A token that is another existing account's is refused,
   `subscription-other-account`, always. This account's token binds the subscription here,
   moving it at once if another account held it. A token that names no existing account (one
   deleted since the purchase) counts as no token.
2. **Without a token**, the subscription binds to the first account that presents it. Held by
   another account, it moves here only once `SUBSCRIPTION_MOVE_DAYS` (30) have passed since it
   was bound there; before that, `subscription-in-use`. So one subscription cannot serve many
   accounts.
3. **One subscription per folder.** If this account's folder for that environment is already
   paid for by a different subscription giving at least as much access, that one stays and the
   presented one is not bound (the session is served from the account's own). Otherwise the
   presented one takes the folder over.
4. **When a subscription moves**, the account it leaves keeps its folder, its data and an
   entitlement that ended at that moment: read-only, then the lapse policy, as for any ended
   subscription.

App Store Server Notifications update the subscription wherever it is bound.

#### `POST /v1/delete-my-data` → `200`

```json
{ "action": "delete-my-data", "challenge": "...", "deviceSessionToken": "..." }
```

Deletes every object in both of the account's folders. The account, its sign-in and its
subscription stay (the usage counts zero again); deleting the account is
`/v1/account/delete`. Each call deletes a bounded batch (up to 100,000 objects); call again,
with a new challenge and assertion, until `done` is true. Works whatever the subscription's
state, and without one.

`200 {"done": true | false, "deletedObjects": 2300}`

Errors: `bad-request`, `challenge-invalid`, `device-unknown`, `assertion-invalid`,
`session-invalid`, `account-deleting`.

### `POST /v1/apple/notifications`

App Store Server Notifications V2. Configure this URL in App Store Connect (production URL for
the production deployment; the sandbox URL may point at either).

`{"signedPayload": "<JWS>"}` → `200 {"ok": true}`

The payload, and the transaction and renewal info inside it, are verified like the app's
(Apple's chain; bundle ID; in `Production`, `appAppleId` = `APP_APPLE_ID`). Then, for
`SUBSCRIBED`, `DID_RENEW`, `DID_CHANGE_RENEWAL_PREF`, `DID_CHANGE_RENEWAL_STATUS`,
`OFFER_REDEEMED`, `DID_FAIL_TO_RENEW`, `GRACE_PERIOD_EXPIRED`, `EXPIRED`, `REFUND` (no subtype),
`REFUND_REVERSED`, `REVOKE` and `RENEWAL_EXTENDED`, the stored subscription is updated wherever
it is bound, newest information winning (a transaction for a later period, or the same period
signed later; renewal info signed later). Replays and late arrivals therefore change nothing.
Other types, a subscription no account has presented and products outside `PRODUCT_ALLOWANCES`
are acknowledged with `200` and no effect. A payload that fails verification gets
`401 notification-invalid` and changes nothing.

### `POST /v1/apple/signin-notifications`

Sign in with Apple server-to-server notifications. Configure this URL as the "Server-to-Server
Notification Endpoint" of the app's Sign in with Apple configuration (Certificates, Identifiers
& Profiles).

`{"payload": "<JWT>"}` → `200 {"ok": true}`

The JWT is verified like an Apple ID token (Apple's keys, issuer, audience = the bundle ID,
issue time; no nonce). Its `iat` must be at most **24 hours** old (room for Apple's delivery
retries and clock differences); an older one is refused, so a captured notification cannot be
replayed later.

For `consent-revoked` (the person stopped using Sign in with Apple with this app) and
`account-delete` (their Apple Account was deleted), the device sessions of that Apple identity's
account that were **made at or before the event** end. The event's time is its `event_time`
(seconds, or milliseconds when the value is above 10^12), never later than the notification's
`iat`; the `iat` without one. So a replay within the 24 hours cannot sign out a session made
after the person signed back in. The account and its data stay: the lapse policy and account
deletion own data removal, and signing in again with the same Apple ID reaches the same
account. An account whose deletion has started is left alone (the deletion owns its sessions,
and the Worker's own revocation causes this event).

Other event types (`email-disabled`, `email-enabled`, anything new) and identities without an
account are acknowledged with no effect. A payload that fails verification, or is too old, gets
`401 notification-invalid`; `503 provider-unreachable` if Apple's keys cannot be fetched (Apple
retries).

## The daily cron

At 03:17 UTC: removes expired challenges; finishes account deletions the app started more than
15 minutes ago and did not finish (empties the folders, then removes the account's rows,
keeping its folder name in `deleted_folders`); empties once more, and then forgets, the folders
of deleted accounts whose `purge_after` has passed (deletion start + 65 minutes: the
one-hour maximum credential life plus 5 minutes); then, for entitlements whose data is still there and whose access ended
`DELETE_AFTER_DAYS` or more ago (or were revoked that long ago), deletes the folder in batches
of 1,000 objects and marks the row (`data_deleted_at`). One run spends at most 600 R2
operations (300,000 objects) and looks at most at 2,000 entitlements, 50 account deletions and
50 deleted folders, well inside the Workers limits even on the Free plan; the next run resumes
where it stopped. A row that changed meanwhile (for
example a resubscription) is not marked.

## Configuration

Variables (in `wrangler.jsonc`, per deployment):

| Name | Meaning |
| --- | --- |
| `ENVIRONMENT` | `dev` or `production`. |
| `R2_ACCOUNT_ID` | The Cloudflare account owning the bucket (32 hex digits). |
| `R2_S3_HOST` | The bucket's S3 host, `<account id>.r2.cloudflarestorage.com` (or the jurisdiction form). `dev` also accepts a local host. |
| `R2_BUCKET_NAME` | The bucket. |
| `APP_BUNDLE_ID` | The app's bundle ID; also the audience of Apple ID tokens and the Sign in with Apple client ID. |
| `APPLE_TEAM_ID` | The 10-character App ID prefix; App Attest checks `<team ID>.<bundle ID>`; the issuer of the Sign in with Apple client secret. |
| `APP_APPLE_ID` | The app's numeric Apple ID (App Store Connect). Required in production. |
| `GOOGLE_CLIENT_IDS` | Comma-separated Google OAuth client IDs (`<digits>-<id>.apps.googleusercontent.com`) whose ID tokens are accepted: the app's iOS client ID. Empty: Google sign-in is off (`provider-disabled`). |
| `SUBSCRIPTION_MOVE_DAYS` | Days before a subscription without a token may move to another account, 1 to 3650 (30). |
| `CREDENTIAL_TTL_SECONDS` | Credential lifetime, 60 to 3600 (900). |
| `READ_ONLY_DAYS`, `DELETE_AFTER_DAYS` | The lapse policy (30, 60). |
| `PRODUCT_ALLOWANCES` | JSON: backup product ID to allowance in bytes. |
| `SANDBOX_ALLOWANCE_BYTES` | Allowance for Sandbox and Xcode purchases (100 MB). |
| `USAGE_CACHE_SECONDS` | How long a usage count is reused (300). |
| `XCODE_STOREKIT_CERT` | `dev` only: base64 DER of Xcode's StoreKit test certificate. |

Secrets (`wrangler secret put <NAME>`, add `--env production` for production; `.dev.vars`
locally):

| Name | Meaning |
| --- | --- |
| `R2_PARENT_ACCESS_KEY_ID`, `R2_PARENT_SECRET_ACCESS_KEY` | The parent R2 token (object read and write on the one bucket). |
| `IDENTITY_KEY_SECRET` | At least 32 characters. Keys the hashes of sign-in identities and of subscriptions. |
| `APPLE_SIWA_KEY_ID`, `APPLE_SIWA_PRIVATE_KEY` | Optional, both or neither: a Sign in with Apple key (Certificates, Identifiers & Profiles > Keys, with Sign in with Apple enabled for the app's App ID): its 10-character key ID and its `.p8` file's contents (PKCS#8 PEM; line breaks may be written as `\n`). Used only to revoke Apple authorizations. |
| `APP_ATTEST_BYPASS_SECRET` | `dev` only, optional, at least 32 characters. |
| `DEV_TEST_SIGNIN_SECRET` | `dev` only, optional, at least 32 characters: turns on the dev test issuer and is its HMAC key (see "The dev test issuer"). Empty or absent: off. |

**Without the Sign in with Apple key**, Apple sign-in, sign-in changes and account deletion all
work, but the Worker cannot revoke the Apple authorization when an account leaves Apple or is
deleted: it logs `apple-revoke-skipped` and goes on. Apple requires revocation on account
deletion, so production should have the key before release.

Every setting is checked on each request; a missing or malformed one makes every endpoint answer
`500` and logs which setting (never its value). In production, the mere presence of
`APP_ATTEST_BYPASS_SECRET` or `DEV_TEST_SIGNIN_SECRET` (even empty), or a non-empty
`XCODE_STOREKIT_CERT`, is such an error: the development switches cannot be turned on there by
mistake, and the code checks the environment again before honouring any of them.

Changing `IDENTITY_KEY_SECRET` loses every sign-in (each identity would make a new, empty
account) and every subscription binding. The folders themselves are named randomly and would be
orphaned, not renamed. Set it once and keep it.

The Worker makes outbound requests to exactly four fixed addresses: Apple's and Google's key
sets (`https://appleid.apple.com/auth/keys`, `https://www.googleapis.com/oauth2/v3/certs`,
cached as their `Cache-Control` says, kept between 5 minutes and 24 hours, fetched again at most
once a minute when a token names an unknown key, and used for up to a day past expiry if a
refresh fails; after a failed fetch the next one waits a minute, and lookups meanwhile get the
stale set or fail at once without a request) and Apple's
`https://appleid.apple.com/auth/token` and `/auth/revoke`.

## Security notes and limits

- **Apple's signatures** are verified as Apple's App Store Server Library does without online
  checks: a three-certificate chain whose root is byte-for-byte the pinned Apple Root CA - G3,
  Apple's marker extensions on the leaf and intermediate, validity at the payload's
  `signedDate`, ES256. It does not ask Apple's OCSP responders whether a certificate was
  revoked, and it does not call the App Store Server API; refunds and other changes arrive
  through server notifications.
- **App Attest** follows Apple's "Validating apps that connect to your server". The receipt's
  fraud-risk metric is not used. Where Apple's documentation is unclear (the encoding of the
  validation category; extension key names in assertions; older systems sending no extensions)
  the choices are documented in `src/appAttest.ts`.
- **Who the reader is** is the account, proved at sign-in by Apple's or Google's signed ID
  token bound to a single-use challenge, and afterwards by the device session token together
  with the App Attest key it was made with. A stolen session token alone does nothing on
  another device; a stolen token and a copy of the device's App Attest key would reach the
  account's folder (whose contents are encrypted). Sign out of all devices ends every session.
- **What is stored** about a person: a keyed hash of their Apple or Google user ID, which
  provider it is, random IDs, session token hashes, an encrypted device label the Worker cannot
  read, and the subscription's state keyed by a hash of its transaction ID. No email, name or
  raw identifier, and none of them in logs. After an account is deleted, only its random folder
  name stays, for 65 minutes (the longest a credential can be configured to last, plus 5) and
  until the next daily cron.
- **Deleting an account cannot leave data behind**: credentials are never minted once a deletion
  has started, and the folders are emptied again after the last credential minted before it
  has expired.
- **A subscription serves one account at a time.** Purchases should carry the account's
  `appAccountToken`; a purchase without one goes to the first account that presents it and can
  move only every `SUBSCRIPTION_MOVE_DAYS`.
- **Lost access to the provider** (a closed Google account, say) with no device still signed in
  leaves the account unreachable: there is no other way in, by design.
- **Sandbox purchases** are accepted by production (App Review and TestFlight need them). Any
  TestFlight tester can make them for free, so each such subscription gets only
  `SANDBOX_ALLOWANCE_BYTES`, in `sandbox/`.
- **`/v1/challenge` is unauthenticated** and writes one small D1 row per call (removed by the
  cron). Put a Cloudflare rate-limiting rule on it in front of the production deployment.
- Credentials are bearer tokens for 15 minutes and R2 does not cap object size, so the
  allowance is enforced between sessions, not within one.
- Nothing sensitive is logged: no request bodies, JWS or ID tokens, authorization codes,
  credentials, session tokens, secrets, provider user IDs or full account IDs (an 8-character
  prefix of the account ID at most).
