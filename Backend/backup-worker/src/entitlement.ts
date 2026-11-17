// Which account a subscription pays for.
//
// A verified transaction is bound like this (CLOUD_SYNC_PLAN.md, "Accounts and sign-in"):
// - Its appAccountToken (on the newest transaction known for the subscription) decides first. A
//   token naming another existing account is refused (`subscription-other-account`), always. A
//   token naming this account binds the subscription here, moving it at once if it was elsewhere.
//   A token naming no existing account (one deleted since the purchase) counts as no token.
// - Without a token, the subscription binds to the first account that presents it. Bound to
//   another account, it may move here only once SUBSCRIPTION_MOVE_DAYS have passed since it was
//   bound there (`subscription-in-use` before then), so one subscription cannot serve many
//   accounts.
// - Each account has one entitlement per folder (`users/` for App Store purchases, `sandbox/` for
//   Sandbox and Xcode ones). If this account's folder is already paid for by a different
//   subscription giving at least as much access, that one stays and the presented one is not
//   bound; otherwise the presented one takes the folder over.
// - When a subscription moves, the account it leaves keeps its folder's entitlement, detached and
//   ended at that moment, so the lapse policy runs for that folder from then.
//
// App Store Server Notifications find the entitlement by the subscription's keyed hash and
// update it, newest wins, wherever it is bound.

import type { RenewalInfo, Transaction } from "./appleJws";
import * as db from "./db";
import type { Settings } from "./env";
import { Refusal } from "./http";
import { subscriptionKey } from "./identity";
import { logEvent, shortKey } from "./log";
import { DAY_MS, accessAt, accessRank, applyRenewalInfo, applyTransaction, detached, namespaceFor, newSubscriber, type Subscriber } from "./subscription";

const ATTEMPTS = 4;

export async function bindSubscription(
  database: D1Database,
  settings: Settings,
  account: db.Account,
  transaction: Transaction,
  renewal: RenewalInfo | undefined,
  now: number,
): Promise<Subscriber> {
  const key = await subscriptionKey(settings.identityKeySecret, transaction.environment, transaction.originalTransactionId);
  const namespace = namespaceFor(transaction.environment);
  for (let attempt = 0; attempt < ATTEMPTS; attempt++) {
    const holder = await db.getSubscriberByKey(database, key);
    // The subscription's state with what was just presented, newest wins.
    let state = holder ? applyTransaction(holder, transaction) : newSubscriber(account.accountId, key, transaction, now);
    if (renewal) state = applyRenewalInfo(state, renewal);

    const token = state.appAccountToken;
    let tokenOwner: db.Account | null = null;
    if (token !== null) tokenOwner = token === account.appAccountToken ? account : await db.getAccountByAppAccountToken(database, token);
    if (tokenOwner && tokenOwner.accountId !== account.accountId) {
      throw new Refusal("subscription-other-account", "appAccountToken names another account");
    }

    if (holder && holder.accountId === account.accountId) {
      // Already this account's: refresh it.
      const next = resubscribed(state, now, settings);
      if (sameState(holder, next)) return holder;
      if (await db.saveSubscriber(database, next, true, now)) return { ...next, version: next.version + 1 };
      continue;
    }

    if (holder) {
      const movable = tokenOwner !== null || now - holder.boundAt >= settings.subscriptionMoveDays * DAY_MS;
      if (!movable) throw new Refusal("subscription-in-use", "bound to another account within the move window");
    }

    const own = await db.getSubscriber(database, account.accountId, namespace);
    if (own && accessRank(accessAt(own, now, settings)) >= accessRank(accessAt(state, now, settings))) {
      logEvent("subscription-not-bound", { account: shortKey(account.accountId), reason: "account already has one at least as good" });
      return own;
    }

    const attached = resubscribed(
      {
        ...state,
        accountId: account.accountId,
        namespace,
        subscriptionKey: key,
        boundAt: now,
        // The folder's own bookkeeping stays with the folder.
        usageBytes: own?.usageBytes ?? 0,
        usageCheckedAt: own?.usageCheckedAt ?? null,
        dataDeletedAt: own?.dataDeletedAt ?? null,
        createdAt: own?.createdAt ?? now,
        version: own?.version ?? 0,
      },
      now,
      settings,
    );
    const leaving = holder ? detached(holder, now, settings) : null;
    if (await db.attachSubscription(database, attached, own !== null, leaving, now)) {
      logEvent("subscription-bound", { account: shortKey(account.accountId), moved: holder !== null, environment: transaction.environment });
      return { ...attached, version: own ? own.version + 1 : 1 };
    }
  }
  throw new Error("subscriber row kept changing");
}

/**
 * Applies a verified transaction (and renewal info) from a server notification to wherever the
 * subscription is bound. Returns null for a subscription no account has presented.
 */
export async function recordNotification(
  database: D1Database,
  settings: Settings,
  transaction: Transaction,
  renewal: RenewalInfo | undefined,
  now: number,
): Promise<Subscriber | null> {
  const key = await subscriptionKey(settings.identityKeySecret, transaction.environment, transaction.originalTransactionId);
  for (let attempt = 0; attempt < ATTEMPTS; attempt++) {
    const existing = await db.getSubscriberByKey(database, key);
    if (!existing) return null;
    let next = applyTransaction(existing, transaction);
    if (renewal) next = applyRenewalInfo(next, renewal);
    next = resubscribed(next, now, settings);
    if (sameState(existing, next)) return existing;
    if (await db.saveSubscriber(database, next, true, now)) return { ...next, version: next.version + 1 };
  }
  throw new Error("subscriber row kept changing");
}

/** A resubscription after the lapse policy deleted the data starts afresh. */
function resubscribed(subscriber: Subscriber, now: number, settings: Settings): Subscriber {
  if (subscriber.dataDeletedAt !== null && accessAt(subscriber, now, settings).kind === "active") return { ...subscriber, dataDeletedAt: null };
  return subscriber;
}

function sameState(a: Subscriber, b: Subscriber): boolean {
  return (
    a.subscriptionKey === b.subscriptionKey &&
    a.appAccountToken === b.appAccountToken &&
    a.productId === b.productId &&
    a.environment === b.environment &&
    a.expiresAt === b.expiresAt &&
    a.revokedAt === b.revokedAt &&
    a.inBillingRetry === b.inBillingRetry &&
    a.graceExpiresAt === b.graceExpiresAt &&
    a.billingRetryEndedAt === b.billingRetryEndedAt &&
    a.txnSignedAt === b.txnSignedAt &&
    a.renewalSignedAt === b.renewalSignedAt &&
    a.dataDeletedAt === b.dataDeletedAt
  );
}
