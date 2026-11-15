// D1 access. Every statement is parameterised; nothing from a request is ever spliced into SQL.

import type { AppleEnvironment } from "./appleJws";
import type { AttestEnvironment } from "./appAttest";
import type { Subscriber } from "./subscription";

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
// Subscribers

interface SubscriberRow {
  user_key: string;
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
    userKey: row.user_key,
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

export async function getSubscriber(db: D1Database, userKey: string): Promise<Subscriber | null> {
  const row = await db.prepare("SELECT * FROM subscribers WHERE user_key = ?").bind(userKey).first<SubscriberRow>();
  return row ? fromRow(row) : null;
}

/**
 * Writes the subscription state (not the usage cache) if nobody changed the row since it was
 * read (`existing` false: the row must not exist yet). Returns false on a conflict; the caller
 * reads again and retries.
 */
export async function saveSubscriber(db: D1Database, subscriber: Subscriber, existing: boolean, now: number): Promise<boolean> {
  const values = [
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
  if (!existing) {
    const result = await db
      .prepare(
        `INSERT INTO subscribers (product_id, environment, expires_at, revoked_at, in_billing_retry, grace_expires_at,
           billing_retry_ended_at, txn_signed_at, renewal_signed_at, data_deleted_at,
           user_key, status_checked_at, usage_bytes, usage_checked_at, created_at, updated_at, version)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?, 1)
         ON CONFLICT (user_key) DO NOTHING`,
      )
      .bind(...values, subscriber.userKey, now, now, now)
      .run();
    return (result.meta.changes ?? 0) === 1;
  }
  const result = await db
    .prepare(
      `UPDATE subscribers SET product_id = ?, environment = ?, expires_at = ?, revoked_at = ?, in_billing_retry = ?,
         grace_expires_at = ?, billing_retry_ended_at = ?, txn_signed_at = ?, renewal_signed_at = ?, data_deleted_at = ?,
         status_checked_at = ?, updated_at = ?, version = version + 1
       WHERE user_key = ? AND version = ?`,
    )
    .bind(...values, now, now, subscriber.userKey, subscriber.version)
    .run();
  return (result.meta.changes ?? 0) === 1;
}

export async function saveUsage(db: D1Database, userKey: string, bytes: number, at: number): Promise<void> {
  await db.prepare("UPDATE subscribers SET usage_bytes = ?, usage_checked_at = ? WHERE user_key = ?").bind(bytes, at, userKey).run();
}

/** Marks the data deleted, unless the row changed since `version` (for example, a resubscription). */
export async function markDataDeleted(db: D1Database, userKey: string, version: number, now: number): Promise<boolean> {
  const result = await db
    .prepare(
      `UPDATE subscribers SET data_deleted_at = ?, usage_bytes = 0, usage_checked_at = ?, updated_at = ?, version = version + 1
       WHERE user_key = ? AND version = ?`,
    )
    .bind(now, now, now, userKey, version)
    .run();
  return (result.meta.changes ?? 0) === 1;
}

export async function deleteSubscriber(db: D1Database, userKey: string): Promise<void> {
  await db.prepare("DELETE FROM subscribers WHERE user_key = ?").bind(userKey).run();
}

/**
 * Subscriptions that may be due for deletion: data still there, and expired or revoked at or
 * before `cutoff` (now minus DELETE_AFTER_DAYS). A necessary condition only: the caller works out
 * the exact end (billing retry, grace) for each. Keyset pages by user key.
 */
export async function deletionCandidates(db: D1Database, cutoff: number, afterKey: string, limit: number): Promise<Subscriber[]> {
  const result = await db
    .prepare(
      `SELECT * FROM subscribers
       WHERE data_deleted_at IS NULL AND user_key > ?
         AND ((revoked_at IS NOT NULL AND revoked_at <= ?) OR (revoked_at IS NULL AND expires_at <= ?))
       ORDER BY user_key LIMIT ?`,
    )
    .bind(afterKey, cutoff, cutoff, limit)
    .all<SubscriberRow>();
  return result.results.map(fromRow);
}
