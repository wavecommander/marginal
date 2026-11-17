import { env } from "cloudflare:workers";
import { beforeAll, describe, expect, it } from "vitest";
import type { ErrorResponse } from "../../src/contract";
import { ACTIONS } from "../../src/tempCredentials";
import { DAY, renewalPayload, transactionPayload } from "../helpers/apple";
import { ALLOWANCE, OTHER_PRODUCT, SANDBOX_ALLOWANCE } from "../helpers/settings";
import { authed, errorCode, makeWorld, putObjects, sessionOk, sessionTokenPayload, sign, signedInReader, type Reader, type World } from "./harness";

let world: World;
let nextId = 3000000000000000;
/** Each subscription is presented by its own signed-in reader, so tests do not share accounts. */
const readers = new Map<string, Reader>();

beforeAll(async () => {
  world = await makeWorld();
});

/** A fresh subscription (its own original transaction ID). */
function subscription(overrides: Record<string, unknown> = {}) {
  const id = String(nextId++);
  return transactionPayload({ originalTransactionId: id, transactionId: id, ...overrides });
}

async function readerFor(payload: Record<string, unknown>): Promise<Reader> {
  const id = String(payload.originalTransactionId);
  let reader = readers.get(id);
  if (!reader) {
    reader = await signedInReader(world);
    readers.set(id, reader);
  }
  return reader;
}

async function session(payload: Record<string, unknown>, renewal?: Record<string, unknown>): Promise<Response> {
  return authed(world, await readerFor(payload), "session", {
    signedTransaction: await sign(world, payload),
    signedRenewalInfo: renewal ? await sign(world, renewal) : undefined,
  });
}

const ok = sessionOk;

describe("a session for an active subscription", () => {
  it("returns read-write credentials limited to exactly the account's folder", async () => {
    const body = await ok(await session(subscription()));
    expect(body.mode).toBe("read-write");
    expect(body.storage).toEqual({
      endpoint: "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com",
      host: "0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com",
      region: "auto",
      bucket: "tactile-texts-backups",
      prefix: expect.stringMatching(/^users\/[0-9a-f]{64}\/$/),
    });
    const token = sessionTokenPayload(body.credentials.sessionToken);
    expect(token.paths).toEqual({ prefixPaths: [body.storage.prefix], objectPaths: [] });
    expect(token.actions).toEqual(ACTIONS["read-write"]);
    expect(token.bucket).toBe("tactile-texts-backups");
    expect(token.exp).toBe(Date.parse("2026-11-15T12:15:00Z") / 1000);
    expect(body.credentials.expiresAt).toBe("2026-11-15T12:15:00.000Z");
    expect(body.subscription).toMatchObject({ state: "active", environment: "Production", endedAt: null, readOnlyUntil: null, deleteAfter: null });
    expect(body.usage).toMatchObject({ bytes: 0, allowanceBytes: ALLOWANCE, overAllowance: false });
  });

  it("gives an account the same folder every time, with or without the transaction, and another account another folder", async () => {
    const mine = subscription();
    const a = await ok(await session(mine));
    const again = await ok(await session({ ...mine, transactionId: String(nextId++), expiresDate: (mine.expiresDate as number) + 30 * DAY, signedDate: (mine.signedDate as number) + DAY }));
    const bare = await ok(await authed(world, await readerFor(mine), "session"));
    const other = await ok(await session(subscription()));
    expect(again.storage.prefix).toBe(a.storage.prefix);
    expect(bare.storage.prefix).toBe(a.storage.prefix);
    expect(bare.subscription.expiresAt).toBe(again.subscription.expiresAt);
    expect(other.storage.prefix).not.toBe(a.storage.prefix);
    expect(sessionTokenPayload(other.credentials.sessionToken).paths).toEqual({ prefixPaths: [other.storage.prefix], objectPaths: [] });
    expect(a.storage.prefix.startsWith(other.storage.prefix) || other.storage.prefix.startsWith(a.storage.prefix)).toBe(false);
  });

  it("keeps sandbox purchases in the account's separate sandbox folder with the sandbox allowance", async () => {
    const shared = subscription();
    const production = await ok(await session(shared));
    const sandbox = await ok(await session({ ...shared, environment: "Sandbox" }));
    expect(sandbox.storage.prefix).toMatch(/^sandbox\/[0-9a-f]{64}\/$/);
    expect(sandbox.storage.prefix.slice("sandbox/".length)).toBe(production.storage.prefix.slice("users/".length));
    expect(sandbox.usage.allowanceBytes).toBe(SANDBOX_ALLOWANCE);
    expect(sandbox.subscription.environment).toBe("Sandbox");
    expect(sessionTokenPayload(sandbox.credentials.sessionToken).paths).toEqual({ prefixPaths: [sandbox.storage.prefix], objectPaths: [] });
    // Without a transaction, the App Store subscription is the one served.
    expect((await ok(await authed(world, await readerFor(shared), "session"))).storage.prefix).toBe(production.storage.prefix);
  });

  it("uses the product's allowance", async () => {
    const body = await ok(await session(subscription({ productId: OTHER_PRODUCT })));
    expect(body.usage.allowanceBytes).toBe(ALLOWANCE * 10);
  });
});

describe("signed in without a subscription", () => {
  it("answers not-subscribed until a transaction is presented", async () => {
    const reader = await signedInReader(world, "google");
    const response = await authed(world, reader, "session");
    expect(response.status).toBe(403);
    expect(await errorCode(response)).toBe("not-subscribed");
    const payload = subscription();
    readers.set(String(payload.originalTransactionId), reader);
    expect((await ok(await session(payload))).mode).toBe("read-write");
    expect((await ok(await authed(world, reader, "session"))).mode).toBe("read-write");
  });

  it("refuses renewal info without a transaction", async () => {
    const reader = await signedInReader(world);
    const response = await authed(world, reader, "session", { bodyOverrides: { signedRenewalInfo: await sign(world, renewalPayload()) } });
    expect(await errorCode(response)).toBe("bad-request");
  });
});

describe("usage and the allowance", () => {
  it("counts every object across list pages, caches the count, and goes read-delete when over", async () => {
    const payload = subscription();
    const first = await ok(await session(payload));
    const prefix = first.storage.prefix;
    // 2,500 objects of 4 bytes: three list pages, 10,000 bytes = exactly the allowance.
    await putObjects(prefix, 2500, 4);
    world.clock.now = new Date(world.clock.now.getTime() + 301_000); // past the 300 s cache
    const atLimit = await ok(await session(payload));
    expect(atLimit.usage).toMatchObject({ bytes: 10_000, allowanceBytes: ALLOWANCE, overAllowance: false });
    expect(atLimit.mode).toBe("read-write");

    // One more byte, but within the cache window: still the cached count.
    await env.BUCKET.put(`${prefix}extra`, new Uint8Array(1));
    world.clock.now = new Date(world.clock.now.getTime() + 60_000);
    const cached = await ok(await session(payload));
    expect(cached.usage.bytes).toBe(10_000);
    expect(cached.usage.countedAt).toBe(atLimit.usage.countedAt);

    world.clock.now = new Date(world.clock.now.getTime() + 300_000);
    const over = await ok(await session(payload));
    expect(over.usage).toMatchObject({ bytes: 10_001, overAllowance: true });
    expect(over.mode).toBe("read-delete");
    expect(sessionTokenPayload(over.credentials.sessionToken).actions).toEqual(ACTIONS["read-delete"]);
    // Objects outside the folder never count.
    await env.BUCKET.put(`${prefix.slice(0, -2)}zz/other`, new Uint8Array(500));
    world.clock.now = new Date(world.clock.now.getTime() + 301_000);
    expect((await ok(await session(payload))).usage.bytes).toBe(10_001);
  });
});

describe("the lapse policy, exactly at its limits", () => {
  // The clock is fixed; the subscription's expiry is placed relative to it.
  const now = () => world.clock.now.getTime();

  async function at(offsetFromExpiry: number): Promise<Response> {
    const expiresDate = now() - offsetFromExpiry;
    return session(subscription({ expiresDate, signedDate: Math.min(expiresDate - DAY, now()) }));
  }

  it("one millisecond before expiry: read-write", async () => {
    expect((await ok(await at(-1))).mode).toBe("read-write");
  });

  it("at expiry and until READ_ONLY_DAYS: read-only, with the dates", async () => {
    const atExpiry = await ok(await at(0));
    expect(atExpiry.mode).toBe("read-only");
    expect(sessionTokenPayload(atExpiry.credentials.sessionToken).actions).toEqual(ACTIONS["read-only"]);
    expect(atExpiry.subscription).toMatchObject({
      state: "ended",
      endedAt: new Date(now()).toISOString(),
      readOnlyUntil: new Date(now() + 30 * DAY).toISOString(),
      deleteAfter: new Date(now() + 60 * DAY).toISOString(),
    });
    expect((await ok(await at(30 * DAY - 1))).mode).toBe("read-only");
  });

  it("from READ_ONLY_DAYS until DELETE_AFTER_DAYS: no credentials, the dates, data kept", async () => {
    for (const offset of [30 * DAY, 60 * DAY - 1]) {
      const response = await at(offset);
      expect(response.status).toBe(403);
      const body = (await response.json()) as ErrorResponse;
      expect(body.error.code).toBe("subscription-lapsed");
      expect(body.subscription?.deleteAfter).toBe(new Date(now() - offset + 60 * DAY).toISOString());
      expect(JSON.stringify(body)).not.toContain("credentials");
    }
  });

  it("from DELETE_AFTER_DAYS: no credentials", async () => {
    const response = await at(60 * DAY);
    expect(response.status).toBe(403);
    expect(((await response.json()) as ErrorResponse).error.code).toBe("data-deleted");
  });

  it("resubscribing during the lapsed period restores access to the same folder", async () => {
    const lapsed = subscription({ expiresDate: now() - 40 * DAY, signedDate: now() - 70 * DAY });
    expect((await session(lapsed)).status).toBe(403);
    const resubscribed = { ...lapsed, transactionId: String(nextId++), purchaseDate: now() - DAY, expiresDate: now() + 29 * DAY, signedDate: now() - DAY };
    const body = await ok(await session(resubscribed));
    expect(body.mode).toBe("read-write");
    // The old transaction no longer wins.
    const again = await ok(await session(lapsed));
    expect(again.mode).toBe("read-write");
    expect(again.storage.prefix).toBe(body.storage.prefix);
  });

  it("billing retry and grace period count as active", async () => {
    const payload = subscription({ expiresDate: now() - 5 * DAY, signedDate: now() - 35 * DAY });
    const renewal = renewalPayload({ originalTransactionId: payload.originalTransactionId, isInBillingRetryPeriod: true, gracePeriodExpiresDate: now() + DAY, signedDate: now() - DAY });
    const body = await ok(await session(payload, renewal));
    expect(body.mode).toBe("read-write");
    expect(body.subscription.state).toBe("grace-period");
  });

  it("renewal info for another subscription is refused", async () => {
    const payload = subscription();
    const renewal = renewalPayload({ originalTransactionId: "1", signedDate: now() - DAY });
    const response = await session(payload, renewal);
    expect(response.status).toBe(401);
    expect(((await response.json()) as ErrorResponse).error.code).toBe("transaction-invalid");
  });
});

describe("refused subscriptions", () => {
  it("revoked: no credentials", async () => {
    const response = await session(subscription({ revocationDate: Date.parse("2026-11-10T00:00:00Z"), revocationReason: 1 }));
    expect(response.status).toBe(403);
    const body = (await response.json()) as ErrorResponse;
    expect(body.error.code).toBe("subscription-revoked");
    expect(body.subscription?.state).toBe("revoked");
  });

  it("wrong bundle, unknown product, Xcode in production", async () => {
    const cases: [Record<string, unknown>, number, string][] = [
      [{ bundleId: "com.example.other" }, 401, "transaction-invalid"],
      [{ productId: "software.tactile.texts.tip" }, 403, "product-unknown"],
      [{ environment: "Xcode" }, 401, "transaction-invalid"],
      [{ appAccountToken: "not-a-uuid" }, 401, "transaction-invalid"],
    ];
    for (const [overrides, status, code] of cases) {
      const response = await session(subscription(overrides));
      expect(response.status).toBe(status);
      expect(((await response.json()) as ErrorResponse).error.code).toBe(code);
    }
  });
});

