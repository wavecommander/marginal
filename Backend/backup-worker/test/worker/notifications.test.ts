import { env } from "cloudflare:workers";
import { beforeAll, describe, expect, it } from "vitest";
import type { ErrorResponse, SessionResponse } from "../../src/contract";
import { DAY, renewalPayload, signedNotification, transactionPayload } from "../helpers/apple";
import { appleLikeChain, signWithChain } from "../helpers/pki";
import { attestedInstall, authed, makeWorld, postJson, sign, type Install, type World } from "./harness";

let world: World;
let install: Install;
let nextId = 5000000000000000;
const NOW = Date.parse("2026-11-15T12:00:00Z");

beforeAll(async () => {
  world = await makeWorld();
  install = await attestedInstall(world);
});

/** Starts a subscription with a session, as the app would. */
async function subscribe(overrides: Record<string, unknown> = {}) {
  const id = String(nextId++);
  const transaction = transactionPayload({ originalTransactionId: id, transactionId: id, signedDate: NOW - 10 * DAY, purchaseDate: NOW - 10 * DAY, expiresDate: NOW + 20 * DAY, ...overrides });
  const response = await authed(world, install, "session", { signedTransaction: await sign(world, transaction) });
  if (response.status !== 200) throw new Error(`session ${response.status}`);
  return { id, transaction, prefix: ((await response.json()) as SessionResponse).storage.prefix };
}

async function notify(signedPayload: string): Promise<Response> {
  return postJson(world, "/v1/apple/notifications", { signedPayload });
}

async function sessionFor(transaction: Record<string, unknown>): Promise<Response> {
  return authed(world, install, "session", { signedTransaction: await sign(world, transaction) });
}

async function stateOf(transaction: Record<string, unknown>): Promise<string> {
  const response = await sessionFor(transaction);
  if (response.status === 200) return `${((await response.json()) as SessionResponse).mode}`;
  return ((await response.json()) as ErrorResponse).error.code;
}

describe("App Store Server Notifications", () => {
  it("DID_RENEW extends the subscription", async () => {
    const { transaction } = await subscribe({ expiresDate: NOW - DAY });
    expect(await stateOf(transaction)).toBe("read-only");
    const renewed = { ...transaction, transactionId: String(nextId++), purchaseDate: NOW - DAY, expiresDate: NOW + 29 * DAY, signedDate: NOW - DAY };
    const response = await notify(await signedNotification(world.chain, "DID_RENEW", undefined, renewed, renewalPayload({ originalTransactionId: transaction.originalTransactionId, signedDate: NOW - DAY })));
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true });
    // The app still sends its old transaction; the renewal it has not seen yet counts.
    expect(await stateOf(transaction)).toBe("read-write");
  });

  it("REFUND revokes, REFUND_REVERSED restores, and replays change nothing", async () => {
    const { transaction } = await subscribe();
    const refunded = { ...transaction, revocationDate: NOW - DAY, revocationReason: 0, signedDate: NOW - DAY };
    const refund = await signedNotification(world.chain, "REFUND", undefined, refunded, undefined);
    expect((await notify(refund)).status).toBe(200);
    expect(await stateOf(transaction)).toBe("subscription-revoked");
    // Idempotent: the same notification again, and the pre-refund transaction from the app.
    const before = await env.DB.prepare("SELECT * FROM subscribers ORDER BY user_key").all();
    expect((await notify(refund)).status).toBe(200);
    const after = await env.DB.prepare("SELECT * FROM subscribers ORDER BY user_key").all();
    expect(after.results).toEqual(before.results);
    expect(await stateOf(transaction)).toBe("subscription-revoked");

    const reversed = { ...transaction, signedDate: NOW - DAY / 2 };
    expect((await notify(await signedNotification(world.chain, "REFUND_REVERSED", undefined, reversed, undefined))).status).toBe(200);
    expect(await stateOf(transaction)).toBe("read-write");
    // An older notification arriving late (the refund) does not undo the reversal.
    expect((await notify(refund)).status).toBe(200);
    expect(await stateOf(transaction)).toBe("read-write");
  });

  it("REVOKE (Family Sharing) revokes", async () => {
    const { transaction } = await subscribe({ inAppOwnershipType: "FAMILY_SHARED" });
    const revoked = { ...transaction, revocationDate: NOW - DAY, revocationReason: 0, signedDate: NOW - DAY };
    expect((await notify(await signedNotification(world.chain, "REVOKE", undefined, revoked, undefined))).status).toBe(200);
    expect(await stateOf(transaction)).toBe("subscription-revoked");
  });

  it("DID_FAIL_TO_RENEW with a grace period, GRACE_PERIOD_EXPIRED, then EXPIRED / BILLING_RETRY", async () => {
    const { transaction } = await subscribe({ expiresDate: NOW - 2 * DAY, signedDate: NOW - 32 * DAY, purchaseDate: NOW - 32 * DAY });
    const id = transaction.originalTransactionId;
    expect(await stateOf(transaction)).toBe("read-only");

    const grace = renewalPayload({ originalTransactionId: id, isInBillingRetryPeriod: true, gracePeriodExpiresDate: NOW + 5 * DAY, signedDate: NOW - 2 * DAY });
    expect((await notify(await signedNotification(world.chain, "DID_FAIL_TO_RENEW", "GRACE_PERIOD", transaction, grace))).status).toBe(200);
    expect(await stateOf(transaction)).toBe("read-write");

    const retrying = renewalPayload({ originalTransactionId: id, isInBillingRetryPeriod: true, gracePeriodExpiresDate: NOW - DAY, signedDate: NOW - DAY });
    expect((await notify(await signedNotification(world.chain, "GRACE_PERIOD_EXPIRED", undefined, transaction, retrying))).status).toBe(200);
    expect(await stateOf(transaction)).toBe("read-write");

    const gaveUp = renewalPayload({ originalTransactionId: id, isInBillingRetryPeriod: false, expirationIntent: 2, signedDate: NOW - DAY / 2 });
    expect((await notify(await signedNotification(world.chain, "EXPIRED", "BILLING_RETRY", transaction, gaveUp))).status).toBe(200);
    const response = await sessionFor(transaction);
    const body = (await response.json()) as SessionResponse;
    expect(body.mode).toBe("read-only");
    // The read-only period runs from when Apple gave up, not from the original expiry.
    expect(body.subscription.endedAt).toBe(new Date(NOW - DAY / 2).toISOString());
  });

  it("EXPIRED (voluntary) ends the subscription", async () => {
    const { transaction } = await subscribe({ expiresDate: NOW - DAY, signedDate: NOW - 31 * DAY, purchaseDate: NOW - 31 * DAY });
    const renewal = renewalPayload({ originalTransactionId: transaction.originalTransactionId, autoRenewStatus: 0, expirationIntent: 1, signedDate: NOW - DAY });
    expect((await notify(await signedNotification(world.chain, "EXPIRED", "VOLUNTARY", transaction, renewal))).status).toBe(200);
    expect(await stateOf(transaction)).toBe("read-only");
  });

  it("acknowledges an unknown subscription, an unhandled type and another product without effect", async () => {
    const before = await env.DB.prepare("SELECT COUNT(*) AS n FROM subscribers").first<{ n: number }>();
    const stranger = transactionPayload({ originalTransactionId: "5999999999999999", transactionId: "5999999999999999" });
    for (const [type, transaction] of [
      ["DID_RENEW", stranger],
      ["CONSUMPTION_REQUEST", stranger],
      ["TEST", undefined],
      ["DID_RENEW", { ...stranger, productId: "software.tactile.marginal.other" }],
    ] as const) {
      const response = await notify(await signedNotification(world.chain, type, undefined, transaction, undefined));
      expect(response.status).toBe(200);
    }
    const after = await env.DB.prepare("SELECT COUNT(*) AS n FROM subscribers").first<{ n: number }>();
    expect(after?.n).toBe(before?.n);
  });

  it("refuses a forged or tampered notification and changes nothing", async () => {
    const { transaction } = await subscribe();
    const forger = await appleLikeChain();
    const refunded = { ...transaction, revocationDate: NOW - DAY, signedDate: NOW - DAY };
    const forged = await signedNotification(forger, "REFUND", undefined, refunded, undefined);
    const response = await notify(forged);
    expect(response.status).toBe(401);
    expect(((await response.json()) as ErrorResponse).error.code).toBe("notification-invalid");

    // A genuine envelope around a forged transaction.
    const inner = await signWithChain(refunded, forger);
    const envelope = await signWithChain(
      { notificationType: "REFUND", notificationUUID: crypto.randomUUID(), signedDate: NOW - DAY, version: "2.0", data: { appAppleId: 1234567890, bundleId: "software.tactile.marginal", environment: "Production", signedTransactionInfo: inner } },
      world.chain,
    );
    expect((await notify(envelope)).status).toBe(401);

    // A tampered genuine one.
    const genuine = await signedNotification(world.chain, "REFUND", undefined, refunded, undefined);
    const [h, p, s] = genuine.split(".");
    expect((await notify(`${h}.${p}x.${s}`)).status).toBe(401);
    expect(await stateOf(transaction)).toBe("read-write");
  });

  it("refuses notifications for another app", async () => {
    const { transaction } = await subscribe();
    const wrongApp = await signedNotification(world.chain, "REFUND", undefined, { ...transaction, revocationDate: NOW }, undefined, {
      data: { bundleId: "com.example.other", environment: "Production", appAppleId: 1234567890 },
    });
    expect((await notify(wrongApp)).status).toBe(401);
    expect(await stateOf(transaction)).toBe("read-write");
  });
});
