// What the service knows about a subscription, how new signed information updates it, and what
// access it gives at a moment in time. Pure functions: the clock is always passed in.
//
// A `Subscriber` is the entitlement of one of an account's two folders (`users/` for App Store
// purchases, `sandbox/` for Sandbox and Xcode ones), holding the state of the subscription that
// pays for it. Updates are "newest wins", so applying the same signed data twice changes nothing
// and an older copy can never undo a newer one (a refunded subscription stays refunded even if
// the app sends the transaction it had before the refund):
// - a transaction replaces the stored one if it covers a later period (`expiresDate`), or the
//   same period signed no earlier (`signedDate`), which is how a refund or its reversal arrives;
// - renewal info replaces the stored one if it was signed no earlier.

import type { AppleEnvironment, RenewalInfo, Transaction } from "./appleJws";
import type { SubscriptionInfo } from "./contract";
import type { Settings } from "./env";

export const DAY_MS = 24 * 60 * 60 * 1000;
/** Apple retries a failed renewal for up to 60 days; billing retry never counts as active beyond that. */
export const BILLING_RETRY_MAX_MS = 60 * DAY_MS;

/** Which of an account's folders: `users/<folder key>/` or `sandbox/<folder key>/`. */
export type Namespace = "users" | "sandbox";

export function namespaceFor(environment: AppleEnvironment): Namespace {
  return environment === "Production" ? "users" : "sandbox";
}

export interface Subscriber {
  accountId: string;
  namespace: Namespace;
  /** The keyed hash naming the subscription that pays for this folder; null once it moved to another account. */
  subscriptionKey: string | null;
  /** ms; when that subscription was bound to this account. */
  boundAt: number;
  /** The appAccountToken on the newest transaction applied, if any. */
  appAccountToken: string | null;
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

export function newSubscriber(accountId: string, subscriptionKey: string, transaction: Transaction, now: number): Subscriber {
  return {
    accountId,
    namespace: namespaceFor(transaction.environment),
    subscriptionKey,
    boundAt: now,
    appAccountToken: transaction.appAccountToken ?? null,
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
    appAccountToken: transaction.appAccountToken ?? null,
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

/** How much an access gives, for choosing between two subscriptions: higher is better. */
export function accessRank(access: Access): number {
  switch (access.kind) {
    case "active":
      return 4;
    case "read-only":
      return 3;
    case "lapsed":
      return 2;
    default:
      return 1;
  }
}

/**
 * A folder's entitlement once its subscription has moved to another account: no longer tied to
 * the subscription (Apple's later updates go to the new account), and, if it still gave access,
 * ended now. The lapse policy then runs for this folder from the moment of the move.
 */
export function detached(subscriber: Subscriber, now: number, settings: Pick<Settings, "readOnlyDays" | "deleteAfterDays">): Subscriber {
  const base = { ...subscriber, subscriptionKey: null };
  if (accessAt(subscriber, now, settings).kind !== "active") return base;
  return { ...base, expiresAt: now, inBillingRetry: false, graceExpiresAt: null, billingRetryEndedAt: null };
}

/**
 * Of an account's entitlements, the one a request without a transaction is served from: the
 * best access, the App Store one on a tie.
 */
export function primaryOf(subscribers: Subscriber[], now: number, settings: Pick<Settings, "readOnlyDays" | "deleteAfterDays">): Subscriber | undefined {
  let best: Subscriber | undefined;
  let bestRank = 0;
  for (const subscriber of subscribers) {
    const rank = accessRank(accessAt(subscriber, now, settings));
    if (rank > bestRank || (rank === bestRank && subscriber.namespace === "users")) {
      best = subscriber;
      bestRank = rank;
    }
  }
  return best;
}
