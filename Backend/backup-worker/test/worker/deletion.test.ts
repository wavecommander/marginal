import { env } from "cloudflare:workers";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import type { DeleteMyDataResponse, SessionResponse } from "../../src/contract";
import { DAY, transactionPayload } from "../helpers/apple";
import { authed, countObjects, cron, errorCode, makeWorld, newChallenge, putObjects, sign, signedInReader, type Reader, type World } from "./harness";

let world: World;
let nextId = 6000000000000000;
const NOW = Date.parse("2026-11-15T12:00:00Z");

beforeAll(async () => {
  // Small budgets so that a few thousand objects take several calls.
  world = await makeWorld({}, { deleteRequestBudget: 3, cronBudget: 4 });
});

afterEach(() => {
  world.clock.now = new Date(NOW);
});

/** A reader with a subscription and a session, as the app would start. */
async function startSubscription(overrides: Record<string, unknown> = {}) {
  const reader = await signedInReader(world);
  const id = String(nextId++);
  const transaction = transactionPayload({ originalTransactionId: id, transactionId: id, signedDate: NOW - 10 * DAY, purchaseDate: NOW - 10 * DAY, expiresDate: NOW + 20 * DAY, ...overrides });
  const signedTransaction = await sign(world, transaction);
  const response = await authed(world, reader, "session", { signedTransaction });
  if (response.status !== 200) throw new Error(`session ${response.status} ${await response.text()}`);
  const body = (await response.json()) as SessionResponse;
  return { reader, transaction, signedTransaction, prefix: body.storage.prefix, folderKey: body.storage.prefix.split("/")[1]! };
}

/** Other tests' subscriptions may fall due too; run until a run has nothing left over. */
async function cronUntilDone(): Promise<void> {
  for (let i = 0; i < 50; i++) if (!(await cron(world)).unfinished) return;
  throw new Error("cron never finished");
}

async function rowFor(reader: Reader, namespace = "users") {
  return env.DB.prepare("SELECT * FROM subscribers WHERE account_id = ? AND namespace = ?").bind(reader.accountId, namespace).first<Record<string, unknown>>();
}

describe("POST /v1/delete-my-data", () => {
  it("deletes everything under the account's folders, in resumable batches, and nothing else; the account and subscription stay", async () => {
    const mine = await startSubscription();
    const neighbour = await startSubscription();
    await putObjects(mine.prefix, 2300, 1);
    await putObjects(`sandbox/${mine.folderKey}/`, 5, 1);
    await putObjects(neighbour.prefix, 10, 1);
    // A key that shares the account's folder name as a prefix but is not inside the folder.
    const lookalike = `${mine.prefix.slice(0, -1)}-not-mine/file`;
    await env.BUCKET.put(lookalike, "x");
    await env.BUCKET.put("unrelated/file", "x");

    const calls: DeleteMyDataResponse[] = [];
    for (let i = 0; i < 6; i++) {
      const response = await authed(world, mine.reader, "delete-my-data");
      expect(response.status).toBe(200);
      const body = (await response.json()) as DeleteMyDataResponse;
      calls.push(body);
      if (body.done) break;
    }
    // Budget 3 = one list and one delete of up to 1,000 objects, and one more list, per call.
    expect(calls).toEqual([
      { done: false, deletedObjects: 1000 },
      { done: false, deletedObjects: 1000 },
      { done: false, deletedObjects: 300 },
      { done: true, deletedObjects: 5 },
    ]);
    expect(await countObjects(mine.prefix)).toBe(0);
    expect(await countObjects(`sandbox/${mine.folderKey}/`)).toBe(0);
    expect(await rowFor(mine.reader)).toMatchObject({ usage_bytes: 0, data_deleted_at: null });
    expect(await countObjects(neighbour.prefix)).toBe(10);
    expect(await env.BUCKET.head(lookalike)).not.toBeNull();
    expect(await env.BUCKET.head("unrelated/file")).not.toBeNull();
    // Still signed in and subscribed, with an empty folder.
    const after = await authed(world, mine.reader, "session");
    expect(after.status).toBe(200);
    expect(((await after.json()) as SessionResponse).storage.prefix).toBe(mine.prefix);
  });

  it("works for an account without a subscription", async () => {
    const reader = await signedInReader(world, "google");
    const response = await authed(world, reader, "delete-my-data");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ done: true, deletedObjects: 0 });
  });

  it("needs the same proof as a session", async () => {
    const mine = await startSubscription();
    await putObjects(mine.prefix, 3, 1);
    const unattested = await authed(world, mine.reader, "delete-my-data", {}, null);
    expect(unattested.status).toBe(401);
    const forgedChallenge = await authed(world, mine.reader, "delete-my-data", { challenge: btoa("x".repeat(32)) });
    expect(forgedChallenge.status).toBe(401);
    const wrongToken = await authed(world, mine.reader, "delete-my-data", { token: "A".repeat(43) });
    expect(await errorCode(wrongToken)).toBe("session-invalid");
    expect(await countObjects(mine.prefix)).toBe(3);
  });
});

describe("the daily cron", () => {
  it("deletes the data of subscriptions ended DELETE_AFTER_DAYS ago, in batches across runs, and marks them", async () => {
    // Started while active, then time passes.
    const due = await startSubscription({ expiresDate: NOW + DAY });
    const notYet = await startSubscription({ expiresDate: NOW + 2 * DAY });
    const active = await startSubscription({ expiresDate: NOW + 400 * DAY, signedDate: NOW - DAY });
    await putObjects(due.prefix, 2500, 1);
    await putObjects(notYet.prefix, 5, 1);
    await putObjects(active.prefix, 5, 1);
    await newChallenge(world);

    // 61 days later: `due` ended 60 days ago exactly, `notYet` 59 days ago.
    world.clock.now = new Date(NOW + 61 * DAY);
    const first = await cron(world);
    expect(first).toMatchObject({ objectsDeleted: 2000, foldersEmptied: 0, unfinished: true });
    expect(first.challengesRemoved).toBeGreaterThan(0);
    expect(await rowFor(due.reader)).toMatchObject({ data_deleted_at: null });
    const second = await cron(world);
    expect(second).toMatchObject({ objectsDeleted: 500, foldersEmptied: 1 });
    expect(await countObjects(due.prefix)).toBe(0);
    expect(await rowFor(due.reader)).toMatchObject({ data_deleted_at: NOW + 61 * DAY, usage_bytes: 0 });
    expect(await countObjects(notYet.prefix)).toBe(5);
    expect(await countObjects(active.prefix)).toBe(5);
    expect((await env.DB.prepare("SELECT COUNT(*) AS n FROM challenges").first<{ n: number }>())?.n).toBe(0);

    // A session for the account now says so, with or without the transaction.
    const after = await authed(world, due.reader, "session", { signedTransaction: due.signedTransaction });
    expect(after.status).toBe(403);
    expect(await errorCode(after)).toBe("data-deleted");
    expect(await errorCode(await authed(world, due.reader, "session"))).toBe("data-deleted");

    // A day later the other one is due too; a third run finds nothing more for the first.
    world.clock.now = new Date(NOW + 62 * DAY);
    const third = await cron(world);
    expect(third).toMatchObject({ objectsDeleted: 5, foldersEmptied: 1, unfinished: false });
    expect(await countObjects(active.prefix)).toBe(5);
  });

  it("deletes a revoked subscription's data DELETE_AFTER_DAYS after the revocation", async () => {
    const live = await startSubscription();
    await putObjects(live.prefix, 3, 1);
    const revoked = await sign(world, { ...live.transaction, revocationDate: NOW, signedDate: NOW });
    expect((await authed(world, live.reader, "session", { signedTransaction: revoked })).status).toBe(403);
    world.clock.now = new Date(NOW + 60 * DAY - 1);
    await cronUntilDone();
    expect(await countObjects(live.prefix)).toBe(3);
    world.clock.now = new Date(NOW + 60 * DAY);
    await cronUntilDone();
    expect(await countObjects(live.prefix)).toBe(0);
    expect(await rowFor(live.reader)).toMatchObject({ data_deleted_at: NOW + 60 * DAY });
  });

  it("counts from the end of billing retry, not from the expiry date", async () => {
    const lapsing = await startSubscription({ expiresDate: NOW + DAY });
    const id = lapsing.transaction.originalTransactionId;
    await putObjects(lapsing.prefix, 3, 1);
    // Apple reports billing retry, and then nothing more: retry counts as active for at most 60
    // days after the expiry (to NOW + 61 days), and the deletion clock starts there.
    const renewal = await sign(world, { originalTransactionId: id, isInBillingRetryPeriod: true, signedDate: NOW + 2 * DAY, environment: "Production" });
    world.clock.now = new Date(NOW + 2 * DAY);
    expect((await authed(world, lapsing.reader, "session", { signedTransaction: lapsing.signedTransaction, signedRenewalInfo: renewal })).status).toBe(200);
    // Long past expiry + 60 days, but not 60 days past the end of retry: kept.
    world.clock.now = new Date(NOW + 121 * DAY - 1);
    await cronUntilDone();
    expect(await countObjects(lapsing.prefix)).toBe(3);
    world.clock.now = new Date(NOW + 121 * DAY);
    await cronUntilDone();
    expect(await countObjects(lapsing.prefix)).toBe(0);
  });

  it("resubscribing after the data was deleted starts with an empty folder and access", async () => {
    const lapsed = await startSubscription({ expiresDate: NOW + DAY });
    await putObjects(lapsed.prefix, 2, 1);
    world.clock.now = new Date(NOW + 61 * DAY);
    await cronUntilDone();
    expect(await countObjects(lapsed.prefix)).toBe(0);
    const renewed = await sign(world, { ...lapsed.transaction, transactionId: String(nextId++), purchaseDate: NOW + 61 * DAY, expiresDate: NOW + 91 * DAY, signedDate: NOW + 61 * DAY });
    const response = await authed(world, lapsed.reader, "session", { signedTransaction: renewed });
    expect(response.status).toBe(200);
    expect(((await response.json()) as SessionResponse).storage.prefix).toBe(lapsed.prefix);
    expect(await rowFor(lapsed.reader)).toMatchObject({ data_deleted_at: null });
  });
});
