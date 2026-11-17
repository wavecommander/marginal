import { env } from "cloudflare:workers";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import type { AccountResponse, SessionResponse } from "../../src/contract";
import { DAY, signedNotification, transactionPayload } from "../helpers/apple";
import { attestedPost, authed, errorCode, idToken, makeWorld, postJson, sessionOk, sign, signedInReader, type Reader, type World } from "./harness";

let world: World;
let nextId = 7500000000000000;
const NOW = Date.parse("2026-11-15T12:00:00Z");

beforeAll(async () => {
  world = await makeWorld();
});

afterEach(() => {
  world.clock.now = new Date(NOW);
});

/** A subscription bought now (relative to the clock), active for a year unless overridden. */
function purchase(overrides: Record<string, unknown> = {}) {
  const id = String(nextId++);
  const now = world.clock.now.getTime();
  return transactionPayload({ originalTransactionId: id, transactionId: id, signedDate: now - DAY, purchaseDate: now - DAY, expiresDate: now + 365 * DAY, ...overrides });
}

async function present(reader: Reader, transaction: Record<string, unknown>): Promise<Response> {
  return authed(world, reader, "session", { signedTransaction: await sign(world, transaction) });
}

async function subscriberRow(reader: Reader, namespace = "users") {
  return env.DB.prepare("SELECT * FROM subscribers WHERE account_id = ? AND namespace = ?").bind(reader.accountId, namespace).first<Record<string, unknown>>();
}

describe("binding a subscription to an account", () => {
  it("binds a transaction carrying the account's appAccountToken (any case)", async () => {
    const reader = await signedInReader(world);
    const body = await sessionOk(await present(reader, purchase({ appAccountToken: reader.appAccountToken.toUpperCase() })));
    expect(body.mode).toBe("read-write");
    expect(await subscriberRow(reader)).toMatchObject({ app_account_token: reader.appAccountToken, bound_at: NOW });
    // The raw original transaction ID is never stored.
    expect(JSON.stringify(await subscriberRow(reader))).not.toContain(String(nextId - 1));
  });

  it("binds a transaction without a token to the first account that presents it, and refuses it elsewhere", async () => {
    const first = await signedInReader(world);
    const second = await signedInReader(world, "google");
    const transaction = purchase();
    const bound = await sessionOk(await present(first, transaction));
    const refused = await present(second, transaction);
    expect(refused.status).toBe(403);
    expect(await errorCode(refused)).toBe("subscription-in-use");
    expect(await errorCode(await authed(world, second, "session"))).toBe("not-subscribed");
    expect((await sessionOk(await present(first, transaction))).storage.prefix).toBe(bound.storage.prefix);
  });

  it("refuses a transaction whose token names another account, always", async () => {
    const owner = await signedInReader(world);
    const other = await signedInReader(world);
    const transaction = purchase({ appAccountToken: owner.appAccountToken });
    const response = await present(other, transaction);
    expect(response.status).toBe(403);
    expect(await errorCode(response)).toBe("subscription-other-account");
    // Not even after the move window.
    world.clock.now = new Date(NOW + 400 * DAY);
    expect(await errorCode(await present(other, { ...transaction, expiresDate: NOW + 800 * DAY }))).toBe("subscription-other-account");
    expect((await present(owner, { ...transaction, expiresDate: NOW + 800 * DAY })).status).toBe(200);
  });

  it("moves a subscription without a token after SUBSCRIPTION_MOVE_DAYS, and the old account's folder lapses from then", async () => {
    const first = await signedInReader(world);
    const second = await signedInReader(world);
    const transaction = purchase();
    const firstSession = await sessionOk(await present(first, transaction));

    world.clock.now = new Date(NOW + 30 * DAY - 1);
    expect(await errorCode(await present(second, transaction))).toBe("subscription-in-use");

    world.clock.now = new Date(NOW + 30 * DAY);
    const moved = await sessionOk(await present(second, transaction));
    expect(moved.mode).toBe("read-write");
    expect(moved.storage.prefix).not.toBe(firstSession.storage.prefix);
    expect(moved.subscription.expiresAt).toBe(firstSession.subscription.expiresAt);
    expect(await subscriberRow(second)).toMatchObject({ bound_at: NOW + 30 * DAY });

    // The first account keeps its folder, ended at the move: read-only, then the lapse policy.
    const detached = await sessionOk(await authed(world, first, "session"));
    expect(detached.mode).toBe("read-only");
    expect(detached.storage.prefix).toBe(firstSession.storage.prefix);
    expect(detached.subscription).toMatchObject({ state: "ended", endedAt: new Date(NOW + 30 * DAY).toISOString() });
    expect(await subscriberRow(first)).toMatchObject({ subscription_key: null });
    // Presenting the transaction again now counts as moving it back: refused within the window.
    expect(await errorCode(await present(first, transaction))).toBe("subscription-in-use");
    world.clock.now = new Date(NOW + 60 * DAY);
    expect(await errorCode(await authed(world, first, "session"))).toBe("subscription-lapsed");
  });

  it("moves a subscription at once to the account its token names", async () => {
    const first = await signedInReader(world);
    const owner = await signedInReader(world);
    const transaction = purchase();
    await sessionOk(await present(first, transaction));
    // The purchase is renewed with the owner's token (for example, bought again from the owner's account).
    const tokened = { ...transaction, transactionId: String(nextId++), expiresDate: (transaction.expiresDate as number) + 30 * DAY, appAccountToken: owner.appAccountToken };
    const moved = await sessionOk(await present(owner, tokened));
    expect(moved.mode).toBe("read-write");
    // And it is now the owner's: the first account is told so.
    expect(await errorCode(await present(first, transaction))).toBe("subscription-other-account");
    expect((await sessionOk(await authed(world, first, "session"))).mode).toBe("read-only");
  });

  it("treats a token naming a deleted account as no token", async () => {
    const gone = await signedInReader(world, "google");
    const transaction = purchase({ appAccountToken: gone.appAccountToken });
    const deleted = await attestedPost(world, gone.install, "/v1/account/delete", async (challenge) => ({
      deviceSessionToken: gone.token,
      idToken: await idToken(world, "google", gone.subject, challenge),
    }));
    expect(((await deleted.json()) as { done: boolean }).done).toBe(true);
    const newcomer = await signedInReader(world);
    expect((await present(newcomer, transaction)).status).toBe(200);
  });

  it("keeps an account's own subscription when another, no better, is presented", async () => {
    const reader = await signedInReader(world);
    const mine = purchase();
    const theirs = purchase({ expiresDate: NOW + 100 * DAY });
    const own = await sessionOk(await present(reader, mine));
    const response = await sessionOk(await present(reader, theirs));
    expect(response.subscription.expiresAt).toBe(own.subscription.expiresAt);
    // Not bound: another account can still take it at once.
    const other = await signedInReader(world);
    expect((await sessionOk(await present(other, theirs))).subscription.expiresAt).toBe(new Date(NOW + 100 * DAY).toISOString());
  });

  it("lets a better subscription take over an account's folder whose own has ended", async () => {
    const reader = await signedInReader(world);
    const ended = purchase({ expiresDate: NOW - DAY, signedDate: NOW - 31 * DAY, purchaseDate: NOW - 31 * DAY });
    const before = await sessionOk(await present(reader, ended));
    expect(before.mode).toBe("read-only");
    const fresh = purchase();
    const after = await sessionOk(await present(reader, fresh));
    expect(after.mode).toBe("read-write");
    expect(after.storage.prefix).toBe(before.storage.prefix);
    // The ended one is no longer bound anywhere: Apple's notifications about it change nothing here.
    const renewedOld = { ...ended, transactionId: String(nextId++), expiresDate: NOW + 1000 * DAY, signedDate: NOW };
    expect((await postJson(world, "/v1/apple/notifications", { signedPayload: await signedNotification(world.chain, "DID_RENEW", undefined, renewedOld, undefined) })).status).toBe(200);
    expect((await sessionOk(await authed(world, reader, "session"))).subscription.expiresAt).toBe(after.subscription.expiresAt);
  });

  it("server notifications follow the subscription to the account it moved to", async () => {
    const first = await signedInReader(world);
    const second = await signedInReader(world);
    const transaction = purchase({ expiresDate: NOW + 40 * DAY });
    await sessionOk(await present(first, transaction));
    world.clock.now = new Date(NOW + 31 * DAY);
    await sessionOk(await present(second, transaction));
    const refunded = { ...transaction, revocationDate: NOW + 31 * DAY, revocationReason: 0, signedDate: NOW + 31 * DAY };
    expect((await postJson(world, "/v1/apple/notifications", { signedPayload: await signedNotification(world.chain, "REFUND", undefined, refunded, undefined) })).status).toBe(200);
    expect(await errorCode(await authed(world, second, "session"))).toBe("subscription-revoked");
    // The first account's folder is unaffected: it ended at the move.
    expect((await sessionOk(await authed(world, first, "session"))).mode).toBe("read-only");
  });

  it("shows on the account screen", async () => {
    const reader = await signedInReader(world);
    const transaction = purchase({ appAccountToken: reader.appAccountToken });
    const session: SessionResponse = await sessionOk(await present(reader, transaction));
    const account = (await (await attestedPost(world, reader.install, "/v1/account", { deviceSessionToken: reader.token })).json()) as AccountResponse;
    expect(account.subscription).toEqual(session.subscription);
  });
});
