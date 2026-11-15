# Tactile Texts cloud backup service

A Cloudflare Worker that lets the production app back up to the owner's R2 bucket without the
app ever holding a storage key. Design: `docs/DESIGN.md`, "Cloud backup service".

The iPad asks the Worker for a session. The Worker checks the App Store subscription and that
the request comes from the genuine app, then returns R2 credentials that last 15 minutes and
reach only `users/<userKey>/`. Backups then go directly between the iPad and R2. They are
encrypted on the iPad first, so neither this service nor Cloudflare can read them.

## Layout

| Path | What it is |
| --- | --- |
| `src/tempCredentials.ts` | Mints the short-lived, scoped credentials (R2 local signing). |
| `src/userKey.ts` | Turns a subscription into the name of the user's folder. |
| `src/env.ts` | Bindings, settings and secrets, parsed and checked. |
| `src/index.ts` | Routes. |
| `migrations/` | D1 schema. |
| `scripts/prove-scoped-credentials.ts` | Checks the credentials against a real development bucket. |
| `wrangler.jsonc` | The `dev` deployment (top level) and `env.production`. |

## Working on it

```sh
npm install
npm test          # unit tests, no account needed
npm run typecheck
npm run dev       # wrangler dev: local D1 and a local R2 bucket
```

`wrangler dev` also serves the local bucket over S3 at
`http://localhost:8787/cdn-cgi/local/r2/s3` with the fixed keys in `wrangler.jsonc`, so the
app's S3 client can be tested against it. That endpoint does not evaluate session tokens, so
the scoping itself is proved against a real bucket:

```sh
cp .dev.vars.example .dev.vars    # fill in; a development bucket and a token limited to it
npm run prove
```

## Secrets

Never in the repository. `.dev.vars` is git-ignored. Deployments get secrets from
`wrangler secret put <NAME>` (add `--env production` for production):
`R2_PARENT_ACCESS_KEY_ID`, `R2_PARENT_SECRET_ACCESS_KEY`, `USER_KEY_SECRET`.

Changing `USER_KEY_SECRET` changes every user's folder name: their existing backups would no
longer be found. Set it once and keep it.
