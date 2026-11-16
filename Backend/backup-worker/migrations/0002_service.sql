-- What the service needs beyond the first schema: one-time challenges, the App Attest
-- environment of each device key, and enough about each subscription to apply Apple's signed
-- updates in order (newest wins) and to work out billing retry and grace periods.

-- App Attest challenges: random, single use, a few minutes long. Only their hash is kept.
CREATE TABLE challenges (
  challenge_hash  TEXT PRIMARY KEY,               -- hex SHA-256 of the challenge bytes
  expires_at      INTEGER NOT NULL,               -- ms
  created_at      INTEGER NOT NULL
);
CREATE INDEX challenges_expiry ON challenges (expires_at);

-- production | development: an App Attest key belongs to one environment.
ALTER TABLE attested_devices ADD COLUMN environment TEXT NOT NULL DEFAULT 'production';

ALTER TABLE subscribers ADD COLUMN grace_expires_at INTEGER;          -- ms; Apple's billing grace period end
ALTER TABLE subscribers ADD COLUMN billing_retry_ended_at INTEGER;    -- ms; when Apple stopped retrying, unrecovered
ALTER TABLE subscribers ADD COLUMN txn_signed_at INTEGER NOT NULL DEFAULT 0;      -- signedDate of the transaction applied
ALTER TABLE subscribers ADD COLUMN renewal_signed_at INTEGER NOT NULL DEFAULT 0;  -- signedDate of the renewal info applied
ALTER TABLE subscribers ADD COLUMN version INTEGER NOT NULL DEFAULT 0;            -- optimistic concurrency

-- The daily cron also looks for revoked subscriptions whose data is still there.
CREATE INDEX subscribers_revoked ON subscribers (revoked_at) WHERE data_deleted_at IS NULL AND revoked_at IS NOT NULL;
