# Tactile Texts cloud backup service

A Cloudflare Worker that lets the production app back up to the owner's R2 bucket without the
app ever holding a storage key. Design: `docs/DESIGN.md`, "Cloud backup service".

The iPad asks the Worker for a session. The Worker checks the App Store subscription and that
the request comes from the genuine app (App Attest), then returns R2 credentials that last 15
minutes and reach only the user's folder. Backups then go directly between the iPad and R2.
They are encrypted on the iPad first, so neither this service nor Cloudflare can read them.

## Layout

| Path | What it is |
| --- | --- |
| `src/index.ts` | Entry point: `fetch` and the daily `scheduled` cron. |
| `src/service.ts` | The endpoints and the cron. |
| `src/contract.ts` | The HTTP contract below, as exported TypeScript types and error codes. |
| `src/appleJws.ts` | Verifies App Store JWS: transactions, renewal info, server notifications. |
| `src/appAttest.ts` | Verifies App Attest attestations and assertions. |
| `src/x509.ts`, `src/der.ts`, `src/cbor.ts` | Minimal, strict certificate, DER and CBOR readers. |
| `src/appleRoots.ts` | Apple's pinned root certificates. |
| `src/subscription.ts` | Subscription state, "newest wins" updates, the lapse policy. |
| `src/storage.ts` | The user's folder in R2: usage counting, deletion in bounded batches. |
| `src/db.ts` | D1 queries. |
| `src/tempCredentials.ts` | Mints the short-lived, scoped credentials (R2 local signing). |
| `src/userKey.ts` | Turns a subscription into the name of the user's folder. |
| `src/env.ts` | Bindings, settings and secrets, parsed and checked (`readSettings`). |
| `src/http.ts`, `src/log.ts` | Responses, body limits, refusals; logging that cannot leak. |
| `migrations/` | D1 schema. |
| `test/unit/` | Plain Node tests of the pure modules (includes Apple's own App Attest sample). |
| `test/worker/` | Tests inside the Workers runtime with local D1 and R2. |
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

`MarginalTests/BackupCloudServiceEndToEndTests` runs the app's own client against a local
`wrangler dev` that mints real temporary credentials for the real development bucket: a
StoreKit test purchase, a backup of a small library, a check that every object is opaque, a
restore into an empty library, and delete-everything. It needs three more values in
`.dev.vars`:

- `APP_ATTEST_BYPASS_SECRET`: any 32+ random characters (`openssl rand -hex 24`). The
  simulator has no App Attest.
- `APPLE_TEAM_ID`: required by the settings check even when App Attest is bypassed; any 10
  uppercase letters or digits will do locally.
- `XCODE_STOREKIT_CERT`: the certificate StoreKit Testing signs transactions with. **Getting it
  without the Xcode UI:** a test-session transaction's JWS carries it as the only entry of its
  header's `x5c` (base64 DER, self-signed, "StoreKit Testing in Xcode"). The app's test
  `writeStoreKitTestCertificate` buys through an `SKTestSession` and writes that entry to a file:

  ```sh
  TEST_RUNNER_MARGINAL_STOREKIT_CERT_OUT=/tmp/storekit-cert.txt \
    scripts/test.sh --skip-packages \
    "-only-testing:MarginalTests/BackupCloudServiceEndToEndTests/writeStoreKitTestCertificate()"
  echo "XCODE_STOREKIT_CERT=$(tr -d '\n' < /tmp/storekit-cert.txt)" >> .dev.vars
  ```

  Measured (Xcode 27, iOS 27 simulator): the certificate is the same across test sessions and
  runs on one simulator, valid for a year from when it was made; another simulator or Mac may
  have its own, so take it from the simulator the tests run on. It is public, not a secret.

Then:

```sh
npm run migrate:local
npx wrangler dev --port 8797 --ip 127.0.0.1
# in the repository root, with the bypass secret from .dev.vars:
TEST_RUNNER_MARGINAL_BACKUP_SERVICE=127.0.0.1:8797 \
TEST_RUNNER_MARGINAL_BACKUP_SERVICE_BYPASS=<APP_ATTEST_BYPASS_SECRET> \
  scripts/test.sh --skip-packages -only-testing:MarginalTests/BackupCloudServiceEndToEndTests
```

Two things differ from a deployment, because `wrangler dev`'s `BUCKET` binding is the *local*
bucket while the credentials reach the real one: usage always counts 0, and
`/v1/delete-my-data` empties the local folder (answering `done` at once), so the test removes
the real objects itself with the folder's credentials and checks the folder is empty. Test
purchases land under `sandbox/<key>/`.

## HTTP contract

All request and response bodies are JSON (`Content-Type: application/json`, UTF-8). Times are
ISO 8601 in UTC. Base64 is standard base64 with padding. Bodies over 64 KiB are refused. Every
response carries `Cache-Control: no-store`. The TypeScript types are in `src/contract.ts`.

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
| 400 | `bad-request` | The request was not understood. | Malformed JSON, a missing or mistyped field, `action` not matching the endpoint. |
| 404 | `not-found` | No such endpoint. | |
| 405 | `method-not-allowed` | That method is not allowed here. | Wrong method; the `Allow` header lists the right one. |
| 413 | `body-too-large` | The request is too large. | Over 64 KiB. |
| 415 | `unsupported-media-type` | Send the request as JSON. | Content type is not `application/json`. |
| 401 | `challenge-invalid` | The request expired. Try again. | Challenge unknown, already used, or older than five minutes. Get a new one. |
| 401 | `attestation-invalid` | This copy of the app could not be verified. | `/v1/attest` refused the attestation. |
| 409 | `device-already-attested` | This device is already registered. | The key ID is already registered; use it. |
| 401 | `device-unknown` | This device needs to be registered again. | No attested key with that ID: generate a key and attest again. |
| 401 | `assertion-invalid` | This copy of the app could not be verified. | Assertion missing, invalid, or its counter did not increase. |
| 401 | `transaction-invalid` | The subscription could not be verified. | The signed transaction or renewal info failed verification (signature, chain, bundle, fields), or the renewal info is for another subscription. |
| 403 | `product-unknown` | This purchase does not include cloud backup. | Not an auto-renewable subscription to a product in `PRODUCT_ALLOWANCES`. |
| 403 | `environment-not-accepted` | Purchases from this environment are not accepted here. | E.g. a `Production` purchase sent to the `dev` deployment. |
| 403 | `subscription-revoked` | This subscription was refunded or revoked. | Apple refunded it or revoked it (Family Sharing). No access. |
| 403 | `subscription-lapsed` | Your subscription has ended. Resubscribe to restore access to your backups before they are deleted. | Ended `READ_ONLY_DAYS` or more ago, less than `DELETE_AFTER_DAYS`. Data kept until `subscription.deleteAfter`. |
| 403 | `data-deleted` | Your subscription ended and its backups have been deleted. | Ended `DELETE_AFTER_DAYS` or more ago. |
| 401 | `notification-invalid` | The notification could not be verified. | `/v1/apple/notifications` only. |
| 500 | `internal` | Something went wrong. Try again later. | Includes a misconfigured deployment. |

### `GET /v1/health`

`200 {"ok": true, "environment": "dev" | "production"}`. Answers `500 internal` if any setting
is missing or malformed, so a bad deployment shows at once.

### `POST /v1/challenge`

No body (or `{}`). Returns a single-use challenge valid for five minutes, used by `/v1/attest`
and by every authenticated request.

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

### Authenticated requests: `POST /v1/session` and `POST /v1/delete-my-data`

Body (its exact bytes are the App Attest `clientData`):

```json
{ "action": "session" | "delete-my-data",
  "challenge": "<from /v1/challenge, single use>",
  "signedTransaction": "<StoreKit Transaction.jwsRepresentation of the backup subscription>",
  "signedRenewalInfo": "<optional: its RenewalInfo JWS>" }
```

`action` must name the endpoint. Send `signedRenewalInfo` when the app has it
(`Product.SubscriptionInfo.Status.renewalInfo`): without it, Apple's billing-retry and grace
periods cannot count until a server notification reports them.

Headers:

| Header | Value |
| --- | --- |
| `X-App-Attest-Key-Id` | The attested key ID (base64). |
| `X-App-Attest-Assertion` | `generateAssertion(keyId, clientDataHash: SHA-256(body bytes))`, base64. |
| `X-App-Attest-Bypass` | `dev` deployment only, instead of the two above (the simulator has no App Attest): the `APP_ATTEST_BYPASS_SECRET`. Production ignores it. |

The order of checks: body and fields; the challenge (consumed even if a later check fails);
the assertion (signature over the body, App ID, counter strictly greater than the last one
seen); the signed transaction (and renewal info).

#### `POST /v1/session` → `200`

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
    "productId": "software.tactile.marginal.backup.standard",
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
- **`storage.prefix`**: `users/<userKey>/` for `Production` purchases; `sandbox/<key>/` for
  `Sandbox` (App Review, TestFlight) and `Xcode` ones, which also get the small
  `SANDBOX_ALLOWANCE_BYTES`. Every object key the app uses must start with it.
- **`subscription.state`**: `active`; `grace-period` (Apple's billing grace period);
  `billing-retry` (Apple retrying a failed renewal, counted as active for at most 60 days after
  the expiry); `ended`; `revoked`. `expiresAt` is the end of the paid period Apple last
  reported; `endedAt`, `readOnlyUntil` and `deleteAfter` are null while active.
- **`usage`**: the sum of object sizes under the prefix, counted through the bucket binding and
  reused for `USAGE_CACHE_SECONDS` (5 minutes). `overAllowance` is `bytes > allowanceBytes`
  (exactly at the allowance is still within it). A folder of more than 100,000 objects is not
  counted in full and is treated as over the allowance.

The lapse policy, measured from when access ended (`endedAt`: the expiry, or when Apple's
billing retry or grace period ended, or the revocation date):

| Time since `endedAt` | Result |
| --- | --- |
| before it (active, grace period, billing retry) | `200`, `read-write` (or `read-delete` over the allowance) |
| 0 to `READ_ONLY_DAYS` (exclusive) | `200`, `read-only` |
| `READ_ONLY_DAYS` to `DELETE_AFTER_DAYS` (exclusive) | `403 subscription-lapsed` with the dates; resubscribing restores access to the same folder |
| `DELETE_AFTER_DAYS` and after, or once deleted | `403 data-deleted`; the daily cron deletes the folder |
| refunded or revoked | `403 subscription-revoked`; the cron deletes the folder `DELETE_AFTER_DAYS` after the revocation |

A subscription that becomes active again after its data was deleted starts with an empty folder.

Errors: `bad-request`, `challenge-invalid`, `device-unknown`, `assertion-invalid`,
`transaction-invalid`, `product-unknown`, `environment-not-accepted`, `subscription-revoked`,
`subscription-lapsed`, `data-deleted`.

#### `POST /v1/delete-my-data` → `200`

Deletes every object under the caller's folder and then the caller's subscription row. Works in
any subscription state (ended and revoked included), with the same proof as a session. Each
call deletes a bounded batch (up to 100,000 objects); call again, with a new challenge and
assertion, until `done` is true.

`200 {"done": true | false, "deletedObjects": 2300}`

Errors: as for a session, except the subscription-state ones (`subscription-revoked`,
`subscription-lapsed`, `data-deleted`) which do not apply.

### `POST /v1/apple/notifications`

App Store Server Notifications V2. Configure this URL in App Store Connect (production URL for
the production deployment; the sandbox URL may point at either).

`{"signedPayload": "<JWS>"}` → `200 {"ok": true}`

The payload, and the transaction and renewal info inside it, are verified like the app's
(Apple's chain; bundle ID; in `Production`, `appAppleId` = `APP_APPLE_ID`). Then, for
`SUBSCRIBED`, `DID_RENEW`, `DID_CHANGE_RENEWAL_PREF`, `DID_CHANGE_RENEWAL_STATUS`,
`OFFER_REDEEMED`, `DID_FAIL_TO_RENEW`, `GRACE_PERIOD_EXPIRED`, `EXPIRED`, `REFUND` (no subtype),
`REFUND_REVERSED`, `REVOKE` and `RENEWAL_EXTENDED`, the stored subscription is updated, newest
information winning (a transaction for a later period, or the same period signed later; renewal
info signed later). Replays and late arrivals therefore change nothing. Other types, a
subscription the service has never seen and products outside `PRODUCT_ALLOWANCES` are
acknowledged with `200` and no effect. A payload that fails verification gets
`401 notification-invalid` and changes nothing.

## The daily cron

At 03:17 UTC: removes expired challenges; then, for subscriptions whose data is still there and
whose access ended `DELETE_AFTER_DAYS` or more ago (or were revoked that long ago), deletes the
folder in batches of 1,000 objects and marks the row (`data_deleted_at`). One run spends at
most 600 R2 operations (300,000 objects) and looks at most at 2,000 subscriptions, well inside
the Workers limits even on the Free plan; the next run resumes where it stopped. A row that
changed meanwhile (for example a resubscription) is not marked.

## Configuration

Variables (in `wrangler.jsonc`, per deployment):

| Name | Meaning |
| --- | --- |
| `ENVIRONMENT` | `dev` or `production`. |
| `R2_ACCOUNT_ID` | The Cloudflare account owning the bucket (32 hex digits). |
| `R2_S3_HOST` | The bucket's S3 host, `<account id>.r2.cloudflarestorage.com` (or the jurisdiction form). `dev` also accepts a local host. |
| `R2_BUCKET_NAME` | The bucket. |
| `APP_BUNDLE_ID` | The app's bundle ID. |
| `APPLE_TEAM_ID` | The 10-character App ID prefix; App Attest checks `<team ID>.<bundle ID>`. |
| `APP_APPLE_ID` | The app's numeric Apple ID (App Store Connect). Required in production. |
| `CREDENTIAL_TTL_SECONDS` | Credential lifetime, 60 to 3600 (900). |
| `READ_ONLY_DAYS`, `DELETE_AFTER_DAYS` | The lapse policy (30, 60). |
| `PRODUCT_ALLOWANCES` | JSON: backup product ID to allowance in bytes. |
| `SANDBOX_ALLOWANCE_BYTES` | Allowance for Sandbox and Xcode purchases (100 MB). |
| `USAGE_CACHE_SECONDS` | How long a usage count is reused (300). |
| `XCODE_STOREKIT_CERT` | `dev` only: base64 DER of Xcode's StoreKit test certificate. |

Secrets (`wrangler secret put <NAME>`, add `--env production` for production; `.dev.vars`
locally): `R2_PARENT_ACCESS_KEY_ID`, `R2_PARENT_SECRET_ACCESS_KEY`, `USER_KEY_SECRET` (at least
32 characters), and in `dev` only, optionally, `APP_ATTEST_BYPASS_SECRET` (at least 32
characters).

Every setting is checked on each request; a missing or malformed one makes every endpoint answer
`500` and logs which setting (never its value). In production, the mere presence of
`APP_ATTEST_BYPASS_SECRET`, or a non-empty `XCODE_STOREKIT_CERT`, is such an error: the
development switches cannot be turned on there by mistake, and the code checks the environment
again before honouring either.

Changing `USER_KEY_SECRET` changes every user's folder name: their existing backups would no
longer be found. Set it once and keep it.

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
- **What App Attest proves** is that the request comes from the genuine app on a genuine device;
  the signed transaction is the identity. Someone holding another user's signed transaction and
  a genuine copy of the app could open that user's folder (whose contents are encrypted).
- **Sandbox purchases** are accepted by production (App Review and TestFlight need them). Any
  TestFlight tester can make them for free, so each such subscription gets only
  `SANDBOX_ALLOWANCE_BYTES`, in `sandbox/`.
- **`/v1/challenge` is unauthenticated** and writes one small D1 row per call (removed by the
  cron). Put a Cloudflare rate-limiting rule on it in front of the production deployment.
- Credentials are bearer tokens for 15 minutes and R2 does not cap object size, so the
  allowance is enforced between sessions, not within one.
- Nothing sensitive is logged: no request bodies, JWS, credentials, secrets or full user keys
  (an 8-character prefix of the user key at most).
