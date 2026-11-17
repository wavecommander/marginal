import { describe, expect, it } from "vitest";
import type { RenewalInfo, Transaction } from "../../src/appleJws";
import { readSettings } from "../../src/env";
import { BILLING_RETRY_MAX_MS, DAY_MS, accessAt, applyRenewalInfo, applyTransaction, detached, newSubscriber, primaryOf, subscriptionInfo, type Subscriber } from "../../src/subscription";
import { testEnv } from "../helpers/settings";

const settings = readSettings(testEnv()); // READ_ONLY_DAYS 30, DELETE_AFTER_DAYS 60
const EXPIRES = Date.parse("2026-12-01T00:00:00Z");
const KEY = "a".repeat(64);

function transaction(overrides: Partial<Transaction> = {}): Transaction {
  return {
    originalTransactionId: "1",
    transactionId: "1",
    productId: "software.tactile.texts.backup.standard",
    environment: "Production",
    signedDate: EXPIRES - 30 * DAY_MS,
    expiresDate: EXPIRES,
    revocationDate: undefined,
    appAccountToken: undefined,
    ...overrides,
  };
}

function renewal(overrides: Partial<RenewalInfo> = {}): RenewalInfo {
  return { originalTransactionId: "1", environment: "Production", signedDate: EXPIRES, isInBillingRetryPeriod: false, gracePeriodExpiresDate: undefined, ...overrides };
}

function subscriber(overrides: Partial<Subscriber> = {}): Subscriber {
  return { ...newSubscriber("account-1", KEY, transaction(), 0), ...overrides };
}

describe("the lapse policy, exactly at its limits", () => {
  const at = (ms: number) => accessAt(subscriber(), ms, settings).kind;

  it("is active until the paid period ends", () => {
    expect(at(EXPIRES - 1)).toBe("active");
    expect(at(EXPIRES)).toBe("read-only");
  });

  it("is read-only for READ_ONLY_DAYS, then lapsed until DELETE_AFTER_DAYS, then due for deletion", () => {
    expect(at(EXPIRES + 30 * DAY_MS - 1)).toBe("read-only");
    expect(at(EXPIRES + 30 * DAY_MS)).toBe("lapsed");
    expect(at(EXPIRES + 60 * DAY_MS - 1)).toBe("lapsed");
    expect(at(EXPIRES + 60 * DAY_MS)).toBe("deletion-due");
  });

  it("reports the dates", () => {
    const sub = subscriber();
    const info = subscriptionInfo(sub, accessAt(sub, EXPIRES + DAY_MS, settings), settings);
    expect(info).toEqual({
      state: "ended",
      environment: "Production",
      productId: "software.tactile.texts.backup.standard",
      expiresAt: "2026-12-01T00:00:00.000Z",
      endedAt: "2026-12-01T00:00:00.000Z",
      readOnlyUntil: "2026-12-31T00:00:00.000Z",
      deleteAfter: "2027-01-30T00:00:00.000Z",
    });
  });

  it("once the data is deleted, says so", () => {
    expect(accessAt(subscriber({ dataDeletedAt: EXPIRES + 60 * DAY_MS }), EXPIRES + 61 * DAY_MS, settings).kind).toBe("data-deleted");
  });
});

describe("billing retry and grace period count as active", () => {
  it("grace period, then billing retry, up to Apple's 60-day limit", () => {
    const sub = applyRenewalInfo(subscriber(), renewal({ isInBillingRetryPeriod: true, gracePeriodExpiresDate: EXPIRES + 16 * DAY_MS }));
    expect(accessAt(sub, EXPIRES + DAY_MS, settings)).toEqual({ kind: "active", state: "grace-period" });
    expect(accessAt(sub, EXPIRES + 16 * DAY_MS, settings)).toEqual({ kind: "active", state: "billing-retry" });
    expect(accessAt(sub, EXPIRES + BILLING_RETRY_MAX_MS - 1, settings).kind).toBe("active");
    // A stale "still retrying" never keeps access beyond the limit; the lapse policy counts from it.
    const after = accessAt(sub, EXPIRES + BILLING_RETRY_MAX_MS, settings);
    expect(after).toEqual({ kind: "read-only", endedAt: EXPIRES + BILLING_RETRY_MAX_MS });
  });

  it("when retrying stops unrecovered, the subscription ended then", () => {
    let sub = applyRenewalInfo(subscriber(), renewal({ isInBillingRetryPeriod: true, signedDate: EXPIRES + DAY_MS }));
    const gaveUp = EXPIRES + 20 * DAY_MS;
    sub = applyRenewalInfo(sub, renewal({ isInBillingRetryPeriod: false, signedDate: gaveUp }));
    expect(sub.billingRetryEndedAt).toBe(gaveUp);
    expect(accessAt(sub, gaveUp - 1, settings).kind).toBe("active");
    expect(accessAt(sub, gaveUp, settings)).toEqual({ kind: "read-only", endedAt: gaveUp });
    expect(accessAt(sub, gaveUp + 30 * DAY_MS, settings).kind).toBe("lapsed");
  });

  it("a recovered renewal moves the paid period on", () => {
    let sub = applyRenewalInfo(subscriber(), renewal({ isInBillingRetryPeriod: true, signedDate: EXPIRES + DAY_MS }));
    sub = applyTransaction(sub, transaction({ expiresDate: EXPIRES + 32 * DAY_MS, signedDate: EXPIRES + 2 * DAY_MS }));
    sub = applyRenewalInfo(sub, renewal({ isInBillingRetryPeriod: false, signedDate: EXPIRES + 2 * DAY_MS }));
    expect(accessAt(sub, EXPIRES + 31 * DAY_MS, settings)).toEqual({ kind: "active", state: "active" });
  });
});

describe("newest wins", () => {
  it("a later period replaces an earlier one; an older one is ignored", () => {
    const renewed = applyTransaction(subscriber(), transaction({ expiresDate: EXPIRES + 30 * DAY_MS, signedDate: EXPIRES }));
    expect(renewed.expiresAt).toBe(EXPIRES + 30 * DAY_MS);
    expect(applyTransaction(renewed, transaction())).toBe(renewed);
  });

  it("a refund sticks even if the app later sends the transaction from before it", () => {
    const refunded = applyTransaction(subscriber(), transaction({ revocationDate: EXPIRES - 10 * DAY_MS, signedDate: EXPIRES - 9 * DAY_MS }));
    expect(accessAt(refunded, EXPIRES - DAY_MS, settings).kind).toBe("revoked");
    const stale = applyTransaction(refunded, transaction());
    expect(stale.revokedAt).toBe(EXPIRES - 10 * DAY_MS);
    // A reversal (same period, signed later, no revocation) restores it.
    const reversed = applyTransaction(stale, transaction({ signedDate: EXPIRES - 5 * DAY_MS }));
    expect(reversed.revokedAt).toBeNull();
    expect(accessAt(reversed, EXPIRES - DAY_MS, settings).kind).toBe("active");
  });

  it("applying the same data twice changes nothing", () => {
    const once = applyRenewalInfo(applyTransaction(subscriber(), transaction({ signedDate: EXPIRES - DAY_MS })), renewal());
    const twice = applyRenewalInfo(applyTransaction(once, transaction({ signedDate: EXPIRES - DAY_MS })), renewal());
    expect(twice).toEqual(once);
  });

  it("older renewal info is ignored", () => {
    const sub = applyRenewalInfo(subscriber(), renewal({ signedDate: EXPIRES + 5 * DAY_MS }));
    expect(applyRenewalInfo(sub, renewal({ isInBillingRetryPeriod: true, signedDate: EXPIRES }))).toBe(sub);
  });
});

describe("accounts", () => {
  it("a transaction's appAccountToken follows the newest transaction", () => {
    const tokened = applyTransaction(subscriber(), transaction({ signedDate: EXPIRES - DAY_MS, appAccountToken: "6f9619ff-8b86-d011-b42d-00c04fc964ff" }));
    expect(tokened.appAccountToken).toBe("6f9619ff-8b86-d011-b42d-00c04fc964ff");
    // An older transaction without the token changes nothing.
    expect(applyTransaction(tokened, transaction()).appAccountToken).toBe("6f9619ff-8b86-d011-b42d-00c04fc964ff");
  });

  it("a detached entitlement ends at the move if it still gave access, and keeps an earlier end", () => {
    const active = { ...subscriber(), inBillingRetry: true, graceExpiresAt: EXPIRES + DAY_MS };
    const moved = detached(active, EXPIRES - 10 * DAY_MS, settings);
    expect(moved.subscriptionKey).toBeNull();
    expect(accessAt(moved, EXPIRES - 10 * DAY_MS, settings)).toEqual({ kind: "read-only", endedAt: EXPIRES - 10 * DAY_MS });
    const ended = detached(subscriber(), EXPIRES + DAY_MS, settings);
    expect(ended.expiresAt).toBe(EXPIRES);
    expect(ended.subscriptionKey).toBeNull();
  });

  it("serves the best entitlement, the App Store one on a tie", () => {
    const users = subscriber();
    const sandbox = { ...subscriber(), namespace: "sandbox" as const, environment: "Sandbox" as const };
    expect(primaryOf([sandbox, users], EXPIRES - DAY_MS, settings)).toBe(users);
    const better = { ...sandbox, expiresAt: EXPIRES + 30 * DAY_MS };
    expect(primaryOf([users, better], EXPIRES + DAY_MS, settings)).toBe(better);
    expect(primaryOf([], EXPIRES, settings)).toBeUndefined();
  });
});
