-- The service's whole state about a user. There are no accounts, names or email addresses: a
-- user is the keyed hash of their App Store subscription (see src/userKey.ts), and the raw
-- subscription ID is never stored.
CREATE TABLE subscribers (
  user_key           TEXT PRIMARY KEY,          -- 64 hex digits; also the folder name users/<user_key>/
  product_id         TEXT NOT NULL,             -- which backup product (sets the storage allowance)
  environment        TEXT NOT NULL,             -- Production | Sandbox | Xcode
  expires_at         INTEGER,                   -- ms since 1970 when the paid period ends; NULL if unknown
  revoked_at         INTEGER,                   -- ms; set when Apple refunds or revokes
  in_billing_retry   INTEGER NOT NULL DEFAULT 0,-- 1 while Apple is retrying a failed renewal (counts as active)
  status_checked_at  INTEGER NOT NULL,          -- ms; when the subscription state was last confirmed
  usage_bytes        INTEGER NOT NULL DEFAULT 0,-- bytes stored under the user's folder at the last count
  usage_checked_at   INTEGER,                   -- ms; when usage_bytes was last counted
  data_deleted_at    INTEGER,                   -- ms; set when the lapse policy or the user deleted the data
  created_at         INTEGER NOT NULL,
  updated_at         INTEGER NOT NULL
);

-- The daily cron looks for ended subscriptions whose data is still there.
CREATE INDEX subscribers_lapsed ON subscribers (expires_at) WHERE data_deleted_at IS NULL;

-- App Attest: one row per app install that has proved it is the genuine app.
CREATE TABLE attested_devices (
  key_id        TEXT PRIMARY KEY,               -- base64 of the attested key's identifier
  public_key    BLOB NOT NULL,                  -- the attested public key (uncompressed P-256 point)
  counter       INTEGER NOT NULL,               -- last assertion counter seen; must only go up
  created_at    INTEGER NOT NULL,
  last_used_at  INTEGER NOT NULL
);
