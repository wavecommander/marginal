// The dev test entitlement: on the `dev` deployment only, an account whose sign-in is a dev test
// issuer identity (never a real Apple or Google one) may be served as subscribed with no App
// Store transaction, so sync and backup can be tried before any App Store product exists
// (README, "Testing sync in development without Apple, Google or the App Store").
//
// It is on only when all of these hold, each checked here at use, whatever built the settings:
// - ENVIRONMENT is `dev` (readSettings refuses DEV_TEST_ENTITLEMENT in production at all);
// - DEV_TEST_ENTITLEMENT names a product in PRODUCT_ALLOWANCES;
// - the dev test issuer is on (DEV_TEST_SIGNIN_SECRET), so nothing else could have made the account;
// - the account's identity is the dev test issuer's (`accounts.identity_dev_test`, set with the
//   identity at sign-in and on every change of sign-in).
//
// How it is represented: **not at all in the database.** The entitlement is worked out for each
// request and never stored, so
// - App Store notifications cannot reach it (they find entitlements by a subscription's keyed
//   hash; this one has none);
// - the lapse cron never sees it (it reads stored entitlements only), and turning the switch off
//   simply ends it: the account answers `not-subscribed` again and its data stays until the
//   account is deleted or the switch comes back. One rule keeps the two apart: while the dev test
//   entitlement applies to an account, the cron does not empty that account's `sandbox/` folder
//   for a stored Sandbox or Xcode purchase that lapsed (the folder is in use); it does once the
//   switch is off;
// - deleting the account leaves nothing of it behind: there is nothing to delete.
// It is the account's `sandbox/` folder (the presented transaction environment is `Xcode`,
// local development) with NO storage cap (owner decision, 18 November 2026: a dev test account
// is for trying real libraries; see `storageLimit`), always active (its `expiresAt` is a day from
// now, every time). A real purchase the account presents binds exactly as without the switch
// (its refusals, such as another account's purchase, still apply); the session is then served
// from the better of the two, so an old StoreKit Testing purchase on a simulator cannot make a
// dev test account read-only. Without a transaction, the best access wins. A stored entitlement
// wins a tie either way.

import type * as db from "./db";
import type { Settings } from "./env";
import { devTestIssuerEnabled } from "./idToken";
import { DAY_MS, allowanceFor, type Subscriber } from "./subscription";

/**
 * What a session served by the dev test entitlement reports as its allowance: the largest whole
 * number of bytes JSON carries exactly. It is a figure to show, not a limit that is applied.
 */
export const DEV_TEST_ALLOWANCE_BYTES = Number.MAX_SAFE_INTEGER;

/**
 * The storage limit for the entitlement a request is served from. A session or account screen
 * served by the dev test entitlement itself (`served === devTest`) has no cap: it is never over
 * its allowance, whatever it holds, and even when its folder is too large to count in full.
 * Anything else, including a dev test account served from a real purchase it presented, keeps
 * its product's or the sandbox allowance.
 */
export function storageLimit(
  served: Subscriber, devTest: Subscriber | undefined, counted: { bytes: number; complete: boolean }, settings: Settings,
): { allowanceBytes: number; overAllowance: boolean } {
  if (devTest !== undefined && served === devTest) return { allowanceBytes: DEV_TEST_ALLOWANCE_BYTES, overAllowance: false };
  const allowanceBytes = allowanceFor(served, settings);
  return { allowanceBytes, overAllowance: counted.bytes > allowanceBytes || !counted.complete };
}

/** Whether an account with this identity has the dev test entitlement now. */
export function devTestEntitlementApplies(account: Pick<db.Account, "devTest">, settings: Settings): boolean {
  if (settings.environment !== "dev") return false;
  const productId = settings.devTestEntitlement;
  if (productId === undefined || !settings.allowances.has(productId)) return false;
  return devTestIssuerEnabled(settings) && account.devTest === true;
}

/** The account's dev test entitlement as of `now`, or undefined when it does not apply. */
export function devTestEntitlement(account: db.Account, settings: Settings, now: number, stored: readonly Subscriber[] = []): Subscriber | undefined {
  if (!devTestEntitlementApplies(account, settings)) return undefined;
  const productId = settings.devTestEntitlement!;
  // The sandbox folder's usage count is kept on its stored entitlement, if it has one.
  const sandbox = stored.find((subscriber) => subscriber.namespace === "sandbox");
  return {
    accountId: account.accountId,
    namespace: "sandbox",
    subscriptionKey: null,
    boundAt: now,
    appAccountToken: null,
    productId,
    environment: "Xcode",
    expiresAt: now + DAY_MS,
    revokedAt: null,
    inBillingRetry: false,
    graceExpiresAt: null,
    billingRetryEndedAt: null,
    txnSignedAt: 0,
    renewalSignedAt: 0,
    usageBytes: sandbox?.usageBytes ?? 0,
    usageCheckedAt: sandbox?.usageCheckedAt ?? null,
    dataDeletedAt: null,
    createdAt: now,
    version: 0,
  };
}

/**
 * The entitlements a request without a transaction chooses from: the stored ones, then the dev
 * test one where it applies (last, so a stored entitlement wins a tie in `primaryOf`).
 */
export function withDevTestEntitlement(stored: Subscriber[], account: db.Account, settings: Settings, now: number): { candidates: Subscriber[]; devTest: Subscriber | undefined } {
  const devTest = devTestEntitlement(account, settings, now, stored);
  return { candidates: devTest ? [...stored, devTest] : stored, devTest };
}
