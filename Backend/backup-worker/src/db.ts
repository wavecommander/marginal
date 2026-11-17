// D1 access. Every statement is parameterised; nothing from a request is ever spliced into SQL.

import type { AppleEnvironment } from "./appleJws";
import type { AttestEnvironment } from "./appAttest";
import type { Provider } from "./identity";
import type { Namespace, Subscriber } from "./subscription";

// ---------------------------------------------------------------------------------------------
// Challenges

export async function storeChallenge(db: D1Database, hash: string, expiresAt: number, now: number): Promise<void> {
  await db.prepare("INSERT INTO challenges (challenge_hash, expires_at, created_at) VALUES (?, ?, ?)").bind(hash, expiresAt, now).run();
}

/** Removes the challenge and says whether it existed and was still valid. A challenge works once. */
export async function consumeChallenge(db: D1Database, hash: string, now: number): Promise<boolean> {
  const row = await db
    .prepare("DELETE FROM challenges WHERE challenge_hash = ? RETURNING expires_at")
    .bind(hash)
    .first<{ expires_at: number }>();
  return row !== null && row.expires_at > now;
}

export async function deleteExpiredChallenges(db: D1Database, now: number): Promise<number> {
  const result = await db.prepare("DELETE FROM challenges WHERE expires_at <= ?").bind(now).run();
  return result.meta.changes ?? 0;
}

// ---------------------------------------------------------------------------------------------
// Attested devices

export interface Device {
  publicKey: Uint8Array;
  counter: number;
  environment: AttestEnvironment;
}

export async function getDevice(db: D1Database, keyId: string): Promise<Device | null> {
  const row = await db
    .prepare("SELECT public_key, counter, environment FROM attested_devices WHERE key_id = ?")
    .bind(keyId)
    .first<{ public_key: ArrayBuffer | number[]; counter: number; environment: string }>();
  if (!row) return null;
  return {
    publicKey: new Uint8Array(row.public_key as ArrayBuffer),
    counter: row.counter,
    environment: row.environment === "development" ? "development" : "production",
  };
}

/** Returns false if the key is already registered. */
export async function insertDevice(db: D1Database, keyId: string, device: Device, now: number): Promise<boolean> {
  const result = await db
    .prepare(
      "INSERT INTO attested_devices (key_id, public_key, counter, environment, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (key_id) DO NOTHING",
    )
    .bind(keyId, device.publicKey, device.counter, device.environment, now, now)
    .run();
  return (result.meta.changes ?? 0) === 1;
}

/** Moves the counter forward, atomically: false if another request already used this or a later value. */
export async function advanceCounter(db: D1Database, keyId: string, counter: number, now: number): Promise<boolean> {
  const result = await db
    .prepare("UPDATE attested_devices SET counter = ?, last_used_at = ? WHERE key_id = ? AND counter < ?")
    .bind(counter, now, keyId, counter)
    .run();
  return (result.meta.changes ?? 0) === 1;
}

// ---------------------------------------------------------------------------------------------
// Accounts

export interface Account {
  accountId: string;
  folderKey: string;
  provider: Provider;
  identityHash: string;
  appAccountToken: string;
  createdAt: number;
  identityChangedAt: number;
  deletingSince: number | null;
}

interface AccountRow {
  account_id: string;
  folder_key: string;
  identity_provider: string;
  identity_hash: string;
  app_account_token: string;
  created_at: number;
  identity_changed_at: number;
  deleting_since: number | null;
}

function accountFromRow(row: AccountRow): Account {
  return {
    accountId: row.account_id,
    folderKey: row.folder_key,
    provider: row.identity_provider === "google" ? "google" : "apple",
    identityHash: row.identity_hash,
    appAccountToken: row.app_account_token,
    createdAt: row.created_at,
    identityChangedAt: row.identity_changed_at,
    deletingSince: row.deleting_since,
  };
}

async function accountWhere(db: D1Database, column: "account_id" | "identity_hash" | "app_account_token", value: string): Promise<Account | null> {
  const row = await db.prepare(`SELECT * FROM accounts WHERE ${column} = ?`).bind(value).first<AccountRow>();
  return row ? accountFromRow(row) : null;
}

export function getAccount(db: D1Database, accountId: string): Promise<Account | null> {
  return accountWhere(db, "account_id", accountId);
}

export function getAccountByIdentity(db: D1Database, identityHash: string): Promise<Account | null> {
  return accountWhere(db, "identity_hash", identityHash);
}

export function getAccountByAppAccountToken(db: D1Database, token: string): Promise<Account | null> {
  return accountWhere(db, "app_account_token", token);
}

/** Creates the account; false if one already has this identity (another request just made it). */
export async function insertAccount(db: D1Database, account: Account): Promise<boolean> {
  const result = await db
    .prepare(
      `INSERT INTO accounts (account_id, folder_key, identity_provider, identity_hash, app_account_token, created_at, identity_changed_at, deleting_since)
       VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
       ON CONFLICT DO NOTHING`,
    )
    .bind(account.accountId, account.folderKey, account.provider, account.identityHash, account.appAccountToken, account.createdAt, account.identityChangedAt)
    .run();
  return (result.meta.changes ?? 0) === 1;
}

/**
 * Replaces the account's one identity with another, in one statement: it applies only if the
 * account still has `oldHash`, is not being deleted, and no account has `newHash`. The unique
 * index on the hash backs that last check against a concurrent sign-in.
 */
export async function changeIdentity(
  db: D1Database,
  accountId: string,
  oldHash: string,
  provider: Provider,
  newHash: string,
  now: number,
): Promise<"changed" | "in-use" | "stale"> {
  try {
    const result = await db
      .prepare(
        `UPDATE accounts SET identity_provider = ?, identity_hash = ?, identity_changed_at = ?
         WHERE account_id = ? AND identity_hash = ? AND deleting_since IS NULL
           AND NOT EXISTS (SELECT 1 FROM accounts WHERE identity_hash = ?)`,
      )
      .bind(provider, newHash, now, accountId, oldHash, newHash)
      .run();
    if ((result.meta.changes ?? 0) === 1) return "changed";
  } catch (error) {
    if (error instanceof Error && /UNIQUE/i.test(error.message)) return "in-use";
    throw error;
  }
  return (await getAccountByIdentity(db, newHash)) ? "in-use" : "stale";
}

/** Marks deletion as started (once; a later call keeps the first time). */
export async function markAccountDeleting(db: D1Database, accountId: string, now: number): Promise<void> {
  await db.prepare("UPDATE accounts SET deleting_since = COALESCE(deleting_since, ?) WHERE account_id = ?").bind(now, accountId).run();
}

/**
 * Removes everything D1 holds for the account, in one transaction, leaving only its folder name
 * in `deleted_folders` until `purgeAfter` (credentials minted before the deletion may still
 * write there until then). The identity, the appAccountToken and the subscription binding go at
 * once, so the same person can sign in to a new account and bind the subscription to it.
 */
export async function removeAccount(db: D1Database, account: Pick<Account, "accountId" | "folderKey">, purgeAfter: number, now: number): Promise<void> {
  await db.batch([
    db
      .prepare(
        `INSERT INTO deleted_folders (folder_key, deleted_at, purge_after) VALUES (?, ?, ?)
         ON CONFLICT (folder_key) DO UPDATE SET purge_after = MAX(purge_after, excluded.purge_after)`,
      )
      .bind(account.folderKey, now, purgeAfter),
    db.prepare("DELETE FROM device_sessions WHERE account_id = ?").bind(account.accountId),
    db.prepare("DELETE FROM subscribers WHERE account_id = ?").bind(account.accountId),
    db.prepare("DELETE FROM accounts WHERE account_id = ?").bind(account.accountId),
  ]);
}

/** Folders of deleted accounts whose last credentials have expired, oldest first. */
export async function foldersToPurge(db: D1Database, now: number, limit: number): Promise<string[]> {
  const result = await db
    .prepare("SELECT folder_key FROM deleted_folders WHERE purge_after <= ? ORDER BY purge_after, folder_key LIMIT ?")
    .bind(now, limit)
    .all<{ folder_key: string }>();
  return result.results.map((row) => row.folder_key);
}

/** Forgets a deleted account's folder once it has been emptied after `purge_after`. */
export async function forgetDeletedFolder(db: D1Database, folderKey: string, now: number): Promise<void> {
  await db.prepare("DELETE FROM deleted_folders WHERE folder_key = ? AND purge_after <= ?").bind(folderKey, now).run();
}

/** Accounts whose deletion started at or before `before`, oldest first. */
export async function accountsBeingDeleted(db: D1Database, before: number, limit: number): Promise<Account[]> {
  const result = await db
    .prepare("SELECT * FROM accounts WHERE deleting_since IS NOT NULL AND deleting_since <= ? ORDER BY deleting_since, account_id LIMIT ?")
    .bind(before, limit)
    .all<AccountRow>();
  return result.results.map(accountFromRow);
}

// ---------------------------------------------------------------------------------------------
// Device sessions

export interface DeviceSession {
  sessionId: string;
  accountId: string;
  attestKeyId: string | null;
  label: string | null;
  createdAt: number;
  lastUsedAt: number;
}

interface SessionRow {
  session_id: string;
  account_id: string;
  attest_key_id: string | null;
  label: string | null;
  created_at: number;
  last_used_at: number;
}

function sessionFromRow(row: SessionRow): DeviceSession {
  return {
    sessionId: row.session_id,
    accountId: row.account_id,
    attestKeyId: row.attest_key_id,
    label: row.label,
    createdAt: row.created_at,
    lastUsedAt: row.last_used_at,
  };
}

export async function insertSession(db: D1Database, session: DeviceSession, tokenHash: string): Promise<void> {
  await db
    .prepare(
      "INSERT INTO device_sessions (session_id, token_hash, account_id, attest_key_id, label, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(session.sessionId, tokenHash, session.accountId, session.attestKeyId, session.label, session.createdAt, session.lastUsedAt)
    .run();
}

export async function getSessionByTokenHash(db: D1Database, tokenHash: string): Promise<DeviceSession | null> {
  const row = await db
    .prepare("SELECT session_id, account_id, attest_key_id, label, created_at, last_used_at FROM device_sessions WHERE token_hash = ?")
    .bind(tokenHash)
    .first<SessionRow>();
  return row ? sessionFromRow(row) : null;
}

export async function touchSession(db: D1Database, sessionId: string, now: number): Promise<void> {
  await db.prepare("UPDATE device_sessions SET last_used_at = ? WHERE session_id = ?").bind(now, sessionId).run();
}

export async function setSessionLabel(db: D1Database, sessionId: string, label: string): Promise<void> {
  await db.prepare("UPDATE device_sessions SET label = ? WHERE session_id = ?").bind(label, sessionId).run();
}

export async function listSessions(db: D1Database, accountId: string): Promise<DeviceSession[]> {
  const result = await db
    .prepare("SELECT session_id, account_id, attest_key_id, label, created_at, last_used_at FROM device_sessions WHERE account_id = ? ORDER BY created_at, rowid")
    .bind(accountId)
    .all<SessionRow>();
  return result.results.map(sessionFromRow);
}

export async function deleteSession(db: D1Database, sessionId: string): Promise<number> {
  const result = await db.prepare("DELETE FROM device_sessions WHERE session_id = ?").bind(sessionId).run();
  return result.meta.changes ?? 0;
}

/**
 * Ends every session of the account, except `keep` if given, and (with `createdAtOrBefore`) only
 * those made at or before that moment. Returns how many ended.
 */
export async function deleteAccountSessions(db: D1Database, accountId: string, options: { keep?: string; createdAtOrBefore?: number } = {}): Promise<number> {
  const result = await db
    .prepare("DELETE FROM device_sessions WHERE account_id = ? AND session_id != ? AND created_at <= ?")
    .bind(accountId, options.keep ?? "", options.createdAtOrBefore ?? Number.MAX_SAFE_INTEGER)
    .run();
  return result.meta.changes ?? 0;
}

// ---------------------------------------------------------------------------------------------
// Subscribers: the entitlement of each of an account's folders

interface SubscriberRow {
  account_id: string;
  namespace: string;
  subscription_key: string | null;
  bound_at: number;
  app_account_token: string | null;
  product_id: string;
  environment: string;
  expires_at: number | null;
  revoked_at: number | null;
  in_billing_retry: number;
  grace_expires_at: number | null;
  billing_retry_ended_at: number | null;
  txn_signed_at: number;
  renewal_signed_at: number;
  usage_bytes: number;
  usage_checked_at: number | null;
  data_deleted_at: number | null;
  created_at: number;
  version: number;
}

function fromRow(row: SubscriberRow): Subscriber {
  return {
    accountId: row.account_id,
    namespace: row.namespace as Namespace,
    subscriptionKey: row.subscription_key,
    boundAt: row.bound_at,
    appAccountToken: row.app_account_token,
    productId: row.product_id,
    environment: row.environment as AppleEnvironment,
    expiresAt: row.expires_at,
    revokedAt: row.revoked_at,
    inBillingRetry: row.in_billing_retry === 1,
    graceExpiresAt: row.grace_expires_at,
    billingRetryEndedAt: row.billing_retry_ended_at,
    txnSignedAt: row.txn_signed_at,
    renewalSignedAt: row.renewal_signed_at,
    usageBytes: row.usage_bytes,
    usageCheckedAt: row.usage_checked_at,
    dataDeletedAt: row.data_deleted_at,
    createdAt: row.created_at,
    version: row.version,
  };
}

/** The entitlement the subscription currently pays for, whichever account it is. */
export async function getSubscriberByKey(db: D1Database, subscriptionKey: string): Promise<Subscriber | null> {
  const row = await db.prepare("SELECT * FROM subscribers WHERE subscription_key = ?").bind(subscriptionKey).first<SubscriberRow>();
  return row ? fromRow(row) : null;
}

export async function getSubscriber(db: D1Database, accountId: string, namespace: Namespace): Promise<Subscriber | null> {
  const row = await db.prepare("SELECT * FROM subscribers WHERE account_id = ? AND namespace = ?").bind(accountId, namespace).first<SubscriberRow>();
  return row ? fromRow(row) : null;
}

export async function listSubscribers(db: D1Database, accountId: string): Promise<Subscriber[]> {
  const result = await db.prepare("SELECT * FROM subscribers WHERE account_id = ? ORDER BY namespace").bind(accountId).all<SubscriberRow>();
  return result.results.map(fromRow);
}

/** The state columns, in the order the statements below bind them. */
function stateValues(subscriber: Subscriber): (string | number | null)[] {
  return [
    subscriber.subscriptionKey,
    subscriber.boundAt,
    subscriber.appAccountToken,
    subscriber.productId,
    subscriber.environment,
    subscriber.expiresAt,
    subscriber.revokedAt,
    subscriber.inBillingRetry ? 1 : 0,
    subscriber.graceExpiresAt,
    subscriber.billingRetryEndedAt,
    subscriber.txnSignedAt,
    subscriber.renewalSignedAt,
    subscriber.dataDeletedAt,
  ];
}

function insertStatement(db: D1Database, subscriber: Subscriber, now: number): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO subscribers (subscription_key, bound_at, app_account_token, product_id, environment, expires_at, revoked_at,
         in_billing_retry, grace_expires_at, billing_retry_ended_at, txn_signed_at, renewal_signed_at, data_deleted_at,
         account_id, namespace, status_checked_at, usage_bytes, usage_checked_at, created_at, updated_at, version)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)
       ON CONFLICT (account_id, namespace) DO NOTHING`,
    )
    .bind(...stateValues(subscriber), subscriber.accountId, subscriber.namespace, now, subscriber.usageBytes, subscriber.usageCheckedAt, now, now);
}

function updateStatement(db: D1Database, subscriber: Subscriber, now: number): D1PreparedStatement {
  return db
    .prepare(
      `UPDATE subscribers SET subscription_key = ?, bound_at = ?, app_account_token = ?, product_id = ?, environment = ?,
         expires_at = ?, revoked_at = ?, in_billing_retry = ?, grace_expires_at = ?, billing_retry_ended_at = ?,
         txn_signed_at = ?, renewal_signed_at = ?, data_deleted_at = ?,
         status_checked_at = ?, updated_at = ?, version = version + 1
       WHERE account_id = ? AND namespace = ? AND version = ?`,
    )
    .bind(...stateValues(subscriber), now, now, subscriber.accountId, subscriber.namespace, subscriber.version);
}

/**
 * Writes the entitlement (not the usage cache) if nobody changed the row since it was read
 * (`existing` false: the row must not exist yet). Returns false on a conflict; the caller reads
 * again and retries.
 */
export async function saveSubscriber(db: D1Database, subscriber: Subscriber, existing: boolean, now: number): Promise<boolean> {
  try {
    const result = await (existing ? updateStatement(db, subscriber, now) : insertStatement(db, subscriber, now)).run();
    return (result.meta.changes ?? 0) === 1;
  } catch (error) {
    // Another row took the subscription meanwhile.
    if (error instanceof Error && /UNIQUE/i.test(error.message)) return false;
    throw error;
  }
}

/**
 * Binds a subscription to an account's folder, and (`from`) detaches it from the folder of the
 * account that held it, all in one transaction that applies completely or not at all:
 * - if `from` changed since it was read and still holds the subscription, the attach breaks the
 *   unique subscription key and the batch rolls back;
 * - if `to` changed since it was read, the guard statement breaks a CHECK constraint and the
 *   batch rolls back.
 * Returns false when it rolled back; the caller reads again and retries.
 */
export async function attachSubscription(db: D1Database, to: Subscriber, toExisting: boolean, from: Subscriber | null, now: number): Promise<boolean> {
  const statements: D1PreparedStatement[] = [];
  if (from) {
    statements.push(
      db
        .prepare(
          `UPDATE subscribers SET subscription_key = NULL, expires_at = ?, in_billing_retry = ?, grace_expires_at = ?,
             billing_retry_ended_at = ?, status_checked_at = ?, updated_at = ?, version = version + 1
           WHERE account_id = ? AND namespace = ? AND version = ?`,
        )
        .bind(from.expiresAt, from.inBillingRetry ? 1 : 0, from.graceExpiresAt, from.billingRetryEndedAt, now, now, from.accountId, from.namespace, from.version),
    );
  }
  statements.push(toExisting ? updateStatement(db, to, now) : insertStatement(db, to, now));
  const expectedVersion = toExisting ? to.version + 1 : 1;
  statements.push(
    db
      .prepare(
        `INSERT INTO subscribers (account_id, namespace, bound_at, product_id, environment, status_checked_at, created_at, updated_at)
         SELECT 'guard', 'guard', 0, '', '', 0, 0, 0
         WHERE NOT EXISTS (SELECT 1 FROM subscribers WHERE account_id = ? AND namespace = ? AND subscription_key = ? AND version = ?)`,
      )
      .bind(to.accountId, to.namespace, to.subscriptionKey, expectedVersion),
  );
  try {
    await db.batch(statements);
    return true;
  } catch (error) {
    if (error instanceof Error && /UNIQUE|CHECK|FOREIGN KEY|constraint/i.test(error.message)) return false;
    throw error;
  }
}

export async function saveUsage(db: D1Database, accountId: string, namespace: Namespace, bytes: number, at: number): Promise<void> {
  await db
    .prepare("UPDATE subscribers SET usage_bytes = ?, usage_checked_at = ? WHERE account_id = ? AND namespace = ?")
    .bind(bytes, at, accountId, namespace)
    .run();
}

/** After the account emptied its own folders: every folder counts zero, as of now. */
export async function resetUsage(db: D1Database, accountId: string, at: number): Promise<void> {
  await db.prepare("UPDATE subscribers SET usage_bytes = 0, usage_checked_at = ? WHERE account_id = ?").bind(at, accountId).run();
}

/** Marks the data deleted, unless the row changed since `version` (for example, a resubscription). */
export async function markDataDeleted(db: D1Database, accountId: string, namespace: Namespace, version: number, now: number): Promise<boolean> {
  const result = await db
    .prepare(
      `UPDATE subscribers SET data_deleted_at = ?, usage_bytes = 0, usage_checked_at = ?, updated_at = ?, version = version + 1
       WHERE account_id = ? AND namespace = ? AND version = ?`,
    )
    .bind(now, now, now, accountId, namespace, version)
    .run();
  return (result.meta.changes ?? 0) === 1;
}

export interface DeletionCandidate {
  subscriber: Subscriber;
  folderKey: string;
}

/**
 * Entitlements whose folder may be due for deletion: data still there, and expired or revoked
 * at or before `cutoff` (now minus DELETE_AFTER_DAYS). A necessary condition only: the caller
 * works out the exact end (billing retry, grace) for each. Keyset pages by account and namespace.
 */
export async function deletionCandidates(
  db: D1Database,
  cutoff: number,
  after: { accountId: string; namespace: string },
  limit: number,
): Promise<DeletionCandidate[]> {
  const result = await db
    .prepare(
      `SELECT s.*, a.folder_key AS folder_key FROM subscribers s JOIN accounts a ON a.account_id = s.account_id
       WHERE s.data_deleted_at IS NULL AND (s.account_id, s.namespace) > (?, ?)
         AND ((s.revoked_at IS NOT NULL AND s.revoked_at <= ?) OR (s.revoked_at IS NULL AND s.expires_at <= ?))
       ORDER BY s.account_id, s.namespace LIMIT ?`,
    )
    .bind(after.accountId, after.namespace, cutoff, cutoff, limit)
    .all<SubscriberRow & { folder_key: string }>();
  return result.results.map((row) => ({ subscriber: fromRow(row), folderKey: row.folder_key }));
}
