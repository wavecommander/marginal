// What the service knows about a subscription, how new signed information updates it, and what
// access it gives at a moment in time. Pure functions: the clock is always passed in.
//
// Updates are "newest wins", so applying the same signed data twice changes nothing and an older
// copy can never undo a newer one (a refunded subscription stays refunded even if the app sends
// the transaction it had before the refund):
// - a transaction replaces the stored one if it covers a later period (`expiresDate`), or the
//   same period signed no earlier (`signedDate`), which is how a refund or its reversal arrives;
// - renewal info replaces the stored one if it was signed no earlier.

import type { AppleEnvironment, RenewalInfo, Transaction } from "./appleJws";
import type { SubscriptionInfo } from "./contract";
import type { Settings } from "./env";

export const DAY_MS = 24 * 60 * 60 * 1000;
/** Apple retries a failed renewal for up to 60 days; billing retry never counts as active beyond that. */
export const BILLING_RETRY_MAX_MS = 60 * DAY_MS;

export interface Subscriber {
  userKey: string;
  productId: string;
  environment: AppleEnvironment;
  /** ms; end of the paid period. */
  expiresAt: number | null;
  revokedAt: number | null;
  inBillingRetry: boolean;
  graceExpiresAt: number | null;
  /** When Apple stopped retrying a failed renewal (it ended unrecovered). */
  billingRetryEndedAt: number | null;
  txnSignedAt: number;
  renewalSignedAt: number;
  usageBytes: number;
  usageCheckedAt: number | null;
  dataDeletedAt: number | null;
  createdAt: number;
  /** Optimistic-concurrency version; bumped on every write. */
  version: number;
}

export function newSubscriber(userKey: string, transaction: Transaction, now: number): Subscriber {
  return {
    userKey,
    productId: transaction.productId,
    environment: transaction.environment,
    expiresAt: transaction.expiresDate,
    revokedAt: transaction.revocationDate ?? null,
    inBillingRetry: false,
    graceExpiresAt: null,
    billingRetryEndedAt: null,
    txnSignedAt: transaction.signedDate,
    renewalSignedAt: 0,
    usageBytes: 0,
    usageCheckedAt: null,
    dataDeletedAt: null,
    createdAt: now,
    version: 0,
  };
}

export function applyTransaction(subscriber: Subscriber, transaction: Transaction): Subscriber {
  const stored = subscriber.expiresAt ?? Number.NEGATIVE_INFINITY;
  const newer =
    transaction.expiresDate > stored ||
    (transaction.expiresDate === stored && transaction.signedDate >= subscriber.txnSignedAt);
  if (!newer) return subscriber;
  return {
    ...subscriber,
    productId: transaction.productId,
    environment: transaction.environment,
    expiresAt: transaction.expiresDate,
    revokedAt: transaction.revocationDate ?? null,
    txnSignedAt: transaction.signedDate,
  };
}

export function applyRenewalInfo(subscriber: Subscriber, renewal: RenewalInfo): Subscriber {
  if (renewal.signedDate < subscriber.renewalSignedAt) return subscriber;
  let billingRetryEndedAt = subscriber.billingRetryEndedAt;
  if (subscriber.inBillingRetry && !renewal.isInBillingRetryPeriod) {
    // Retrying stopped. If the renewal recovered, the transaction's later expiry outweighs this.
    const cap = (subscriber.expiresAt ?? 0) + BILLING_RETRY_MAX_MS;
    const ended = Math.min(renewal.signedDate, cap);
    billingRetryEndedAt = Math.max(billingRetryEndedAt ?? 0, ended);
  }
  return {
    ...subscriber,
    inBillingRetry: renewal.isInBillingRetryPeriod,
    graceExpiresAt: renewal.gracePeriodExpiresDate ?? null,
    billingRetryEndedAt,
    renewalSignedAt: renewal.signedDate,
  };
}

export type Access =
  | { kind: "active"; state: "active" | "grace-period" | "billing-retry" }
  /** Ended within READ_ONLY_DAYS: restore only. */
  | { kind: "read-only"; endedAt: number }
  /** Ended within DELETE_AFTER_DAYS: no access, data kept, resubscribing restores access. */
  | { kind: "lapsed"; endedAt: number }
  /** Ended DELETE_AFTER_DAYS ago or more: the data is (or is about to be) deleted. */
  | { kind: "deletion-due"; endedAt: number }
  /** Refunded or revoked by Apple: no access. */
  | { kind: "revoked"; endedAt: number }
  /** Ended and the data has been deleted. */
  | { kind: "data-deleted"; endedAt: number };

export function accessAt(subscriber: Subscriber, now: number, settings: Pick<Settings, "readOnlyDays" | "deleteAfterDays">): Access {
  let endedAt: number;
  if (subscriber.revokedAt !== null) {
    endedAt = subscriber.revokedAt;
    if (subscriber.dataDeletedAt !== null) return { kind: "data-deleted", endedAt };
    return { kind: "revoked", endedAt };
  }
  const expires = subscriber.expiresAt ?? 0;
  if (now < expires) return { kind: "active", state: "active" };
  if (subscriber.inBillingRetry) {
    const cap = expires + BILLING_RETRY_MAX_MS;
    if (now < cap) {
      const inGrace = subscriber.graceExpiresAt !== null && now < subscriber.graceExpiresAt;
      return { kind: "active", state: inGrace ? "grace-period" : "billing-retry" };
    }
    endedAt = cap;
  } else {
    endedAt = Math.max(expires, subscriber.graceExpiresAt ?? 0, subscriber.billingRetryEndedAt ?? 0);
    if (now < endedAt) return { kind: "active", state: "billing-retry" };
  }
  if (subscriber.dataDeletedAt !== null) return { kind: "data-deleted", endedAt };
  if (now < endedAt + settings.readOnlyDays * DAY_MS) return { kind: "read-only", endedAt };
  if (now < endedAt + settings.deleteAfterDays * DAY_MS) return { kind: "lapsed", endedAt };
  return { kind: "deletion-due", endedAt };
}

export function subscriptionInfo(subscriber: Subscriber, access: Access, settings: Pick<Settings, "readOnlyDays" | "deleteAfterDays">): SubscriptionInfo {
  const iso = (ms: number | null) => (ms === null ? null : new Date(ms).toISOString());
  const base = {
    environment: subscriber.environment,
    productId: subscriber.productId,
    expiresAt: iso(subscriber.expiresAt),
  };
  if (access.kind === "active") {
    return { ...base, state: access.state, endedAt: null, readOnlyUntil: null, deleteAfter: null };
  }
  const { endedAt } = access;
  return {
    ...base,
    state: access.kind === "revoked" || subscriber.revokedAt !== null ? "revoked" : "ended",
    endedAt: iso(endedAt),
    // A revoked subscription has no read-only period.
    readOnlyUntil: access.kind === "revoked" || subscriber.revokedAt !== null ? iso(endedAt) : iso(endedAt + settings.readOnlyDays * DAY_MS),
    deleteAfter: iso(endedAt + settings.deleteAfterDays * DAY_MS),
  };
}

/** Sandbox and Xcode purchases live apart from customers' data, with a small allowance. */
export function isSandbox(environment: AppleEnvironment): boolean {
  return environment !== "Production";
}

export function allowanceFor(subscriber: Pick<Subscriber, "productId" | "environment">, settings: Settings): number {
  if (isSandbox(subscriber.environment)) return settings.sandboxAllowanceBytes;
  return settings.allowances.get(subscriber.productId) ?? 0;
}
