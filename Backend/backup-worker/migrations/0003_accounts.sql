-- Accounts. The reader signs in with Apple or Google; the App Store subscription pays for the
-- account instead of being the user. The app is pre-launch and nothing is deployed with data, so
-- the subscription-keyed table is replaced outright: nothing is carried over.
--
-- Nothing here is a name, an email address or a provider's raw user ID. An identity is stored
-- only as a keyed hash; folder names are random.

DROP INDEX IF EXISTS subscribers_lapsed;
DROP INDEX IF EXISTS subscribers_revoked;
DROP TABLE subscribers;

-- One row per account, with exactly one identity (the columns are NOT NULL and the hash is
-- unique across accounts, so an account can never hold two identities or none).
CREATE TABLE accounts (
  account_id          TEXT PRIMARY KEY,                 -- 32 hex digits, random
  folder_key          TEXT NOT NULL UNIQUE,             -- 64 hex digits, random: users/<folder_key>/ and sandbox/<folder_key>/
  identity_provider   TEXT NOT NULL CHECK (identity_provider IN ('apple', 'google')),
  identity_hash       TEXT NOT NULL UNIQUE,             -- hex HMAC-SHA256(IDENTITY_KEY_SECRET, domain || provider || subject)
  app_account_token   TEXT NOT NULL UNIQUE,             -- lower-case UUID; StoreKit's appAccountToken for this account
  created_at          INTEGER NOT NULL,                 -- ms
  identity_changed_at INTEGER NOT NULL,                 -- ms; when the sign-in was last set or changed
  deleting_since      INTEGER                           -- ms; set when account deletion started, until it finishes
);
CREATE INDEX accounts_deleting ON accounts (deleting_since) WHERE deleting_since IS NOT NULL;

-- A signed-in app install. The token is random and only its hash is kept.
CREATE TABLE device_sessions (
  session_id     TEXT PRIMARY KEY,                      -- 32 hex digits, random; names the device in the account's list
  token_hash     TEXT NOT NULL UNIQUE,                  -- hex SHA-256 of the 32 token bytes
  account_id     TEXT NOT NULL REFERENCES accounts (account_id),
  attest_key_id  TEXT,                                  -- the App Attest key the session was made with; NULL only through the dev bypass
  label          TEXT,                                  -- opaque base64 the app encrypted (the device name); unreadable here
  created_at     INTEGER NOT NULL,                      -- ms
  last_used_at   INTEGER NOT NULL                       -- ms
);
CREATE INDEX device_sessions_account ON device_sessions (account_id);

-- The entitlement of one of an account's two folders: `users` (App Store purchases) or `sandbox`
-- (Sandbox and Xcode purchases). Every column from the subscription-keyed table keeps its meaning
-- and its "newest wins" updates; the row now belongs to the account and names the subscription
-- that currently pays for it.
CREATE TABLE subscribers (
  account_id             TEXT NOT NULL REFERENCES accounts (account_id),
  namespace              TEXT NOT NULL CHECK (namespace IN ('users', 'sandbox')),
  subscription_key       TEXT UNIQUE,                   -- hex HMAC(IDENTITY_KEY_SECRET, environment + original transaction ID); NULL once the subscription moved to another account
  bound_at               INTEGER NOT NULL,              -- ms; when this subscription was bound to this account (the move window counts from here)
  app_account_token      TEXT,                          -- the appAccountToken on the newest transaction applied, if any
  product_id             TEXT NOT NULL,                 -- which backup product (sets the storage allowance)
  environment            TEXT NOT NULL,                 -- Production | Sandbox | Xcode
  expires_at             INTEGER,                       -- ms; end of the paid period; NULL if unknown
  revoked_at             INTEGER,                       -- ms; set when Apple refunds or revokes
  in_billing_retry       INTEGER NOT NULL DEFAULT 0,    -- 1 while Apple is retrying a failed renewal (counts as active)
  grace_expires_at       INTEGER,                       -- ms; Apple's billing grace period end
  billing_retry_ended_at INTEGER,                       -- ms; when Apple stopped retrying, unrecovered
  txn_signed_at          INTEGER NOT NULL DEFAULT 0,    -- signedDate of the transaction applied
  renewal_signed_at      INTEGER NOT NULL DEFAULT 0,    -- signedDate of the renewal info applied
  status_checked_at      INTEGER NOT NULL,              -- ms; when the state was last written
  usage_bytes            INTEGER NOT NULL DEFAULT 0,    -- bytes under the folder at the last count
  usage_checked_at       INTEGER,                       -- ms; when usage_bytes was counted
  data_deleted_at        INTEGER,                       -- ms; set when the lapse policy deleted the folder
  created_at             INTEGER NOT NULL,
  updated_at             INTEGER NOT NULL,
  version                INTEGER NOT NULL DEFAULT 0,    -- optimistic concurrency
  PRIMARY KEY (account_id, namespace)
);

-- The daily cron looks for ended or revoked entitlements whose data is still there.
CREATE INDEX subscribers_lapsed ON subscribers (expires_at) WHERE data_deleted_at IS NULL;
CREATE INDEX subscribers_revoked ON subscribers (revoked_at) WHERE data_deleted_at IS NULL AND revoked_at IS NOT NULL;
