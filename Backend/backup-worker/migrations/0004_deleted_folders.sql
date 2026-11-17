-- Folders of deleted accounts, kept until no credential issued for them can still work.
--
-- R2 credentials outlive the request that minted them by up to CREDENTIAL_TTL_SECONDS, so an
-- account's folders may receive objects after its deletion emptied them. The account itself is
-- gone at once (its identity, sessions and subscription binding are free for a new account);
-- only its random folder name stays here, with nothing that identifies anyone, until the cron
-- has emptied the folders once more after `purge_after`.
CREATE TABLE deleted_folders (
  folder_key   TEXT PRIMARY KEY,                -- 64 hex digits: users/<folder_key>/ and sandbox/<folder_key>/
  deleted_at   INTEGER NOT NULL,                -- ms; when the account was removed
  purge_after  INTEGER NOT NULL                 -- ms; deletion start + CREDENTIAL_TTL_SECONDS + a margin
);
CREATE INDEX deleted_folders_purge ON deleted_folders (purge_after);
