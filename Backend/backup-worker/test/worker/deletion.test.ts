import { env } from "cloudflare:workers";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import type { DeleteMyDataResponse, SessionResponse } from "../../src/contract";
import { DAY, transactionPayload } from "../helpers/apple";
import { attestedInstall, authed, countObjects, cron, makeWorld, newChallenge, putObjects, sign, type Install, type World } from "./harness";

let world: World;
let install: Install;
let nextId = 6000000000000000;
const NOW = Date.parse("2026-11-15T12:00:00Z");

beforeAll(async () => {
  // Small budgets so that a few thousand objects take several calls.
  world = await makeWorld({}, { deleteRequestBudget: 2, cronBudget: 4 });
  install = await attestedInstall(world);
});

afterEach(() => {
  world.clock.now = new Date(NOW);
});

async function startSubscription(overrides: Record<string, unknown> = {}) {
  const id = String(nextId++);
  const transaction = transactionPayload({ originalTransactionId: id, transactionId: id, signedDate: NOW - 10 * DAY, purchaseDate: NOW - 10 * DAY, expiresDate: NOW + 20 * DAY, ...overrides });
  const signedTransaction = await sign(world, transaction);
  const response = await authed(world, install, "session", { signedTransaction });
  if (response.status !== 200) throw new Error(`session ${response.status} ${await response.text()}`);
  const body = (await response.json()) as SessionResponse;
  return { transaction, signedTransaction, prefix: body.storage.prefix, userKey: body.storage.prefix.split("/")[1]! };
}

/** Other tests' subscriptions may fall due too; run until a run has nothing left over. */
async function cronUntilDone(): Promise<void> {
  for (let i = 0; i < 50; i++) if (!(await cron(world)).unfinished) return;
  throw new Error("cron never finished");
}

async function rowFor(userKey: string) {
  return env.DB.prepare("SELECT * FROM subscribers WHERE user_key = ?").bind(userKey).first<Record<string, unknown>>();
}

describe("POST /v1/delete-my-data", () => {
  it("deletes everything under the caller's folder, in resumable batches, then the row, and nothing else", async () => {
    const mine = await startSubscription();
    const neighbour = await startSubscription();
    await putObjects(mine.prefix, 2300, 1);
    await putObjects(neighbour.prefix, 10, 1);
    // A key that shares the caller's folder name as a prefix but is not inside the folder.
    const lookalike = `${mine.prefix.slice(0, -1)}-not-mine/file`;
    await env.BUCKET.put(lookalike, "x");
    await env.BUCKET.put("unrelated/file", "x");

    const calls: DeleteMyDataResponse[] = [];
    for (let i = 0; i < 5; i++) {
      const response = await authed(world, install, "delete-my-data", { signedTransaction: mine.signedTransaction });
      expect(response.status).toBe(200);
      const body = (await response.json()) as DeleteMyDataResponse;
      calls.push(body);
      if (body.done) break;
    }
    // Budget 2 = one list and one delete of up to 1,000 objects per call.
    expect(calls).toEqual([
      { done: false, deletedObjects: 1000 },
      { done: false, deletedObjects: 1000 },
      { done: true, deletedObjects: 300 },
    ]);
    expect(await countObjects(mine.prefix)).toBe(0);
    expect(await rowFor(mine.userKey)).toBeNull();
    expect(await countObjects(neighbour.prefix)).toBe(10);
    expect(await env.BUCKET.head(lookalike)).not.toBeNull();
    expect(await env.BUCKET.head("unrelated/file")).not.toBeNull();
    expect(await rowFor(neighbour.userKey)).not.toBeNull();
  });

  it("works for a subscription that has been revoked", async () => {
    const id = String(nextId++);
    const transaction = transactionPayload({ originalTransactionId: id, transactionId: id, revocationDate: NOW - DAY, signedDate: NOW - DAY });
    const response = await authed(world, install, "delete-my-data", { signedTransaction: await sign(world, transaction) });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ done: true, deletedObjects: 0 });
  });

  it("needs the same proof as a session", async () => {
    const mine = await startSubscription();
    await putObjects(mine.prefix, 3, 1);
    const unattested = await authed(world, null, "delete-my-data", { signedTransaction: mine.signedTransaction });
    expect(unattested.status).toBe(401);
    const forgedChallenge = await authed(world, install, "delete-my-data", { signedTransaction: mine.signedTransaction, challenge: btoa("x".repeat(32)) });
    expect(forgedChallenge.status).toBe(401);
    expect(await countObjects(mine.prefix)).toBe(3);
    void newChallenge;
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
    const challenge = await newChallenge(world);

    // 61 days later: `due` ended 60 days ago exactly, `notYet` 59 days ago.
    world.clock.now = new Date(NOW + 61 * DAY);
    const first = await cron(world);
    expect(first).toMatchObject({ objectsDeleted: 2000, foldersEmptied: 0, unfinished: true, challengesRemoved: 1 });
    expect(await rowFor(due.userKey)).toMatchObject({ data_deleted_at: null });
    const second = await cron(world);
    expect(second).toMatchObject({ objectsDeleted: 500, foldersEmptied: 1 });
    expect(await countObjects(due.prefix)).toBe(0);
    expect(await rowFor(due.userKey)).toMatchObject({ data_deleted_at: NOW + 61 * DAY, usage_bytes: 0 });
    expect(await countObjects(notYet.prefix)).toBe(5);
    expect(await countObjects(active.prefix)).toBe(5);
    expect((await env.DB.prepare("SELECT COUNT(*) AS n FROM challenges").first<{ n: number }>())?.n).toBe(0);
    void challenge;

    // A session for the deleted subscription now says so.
    const after = await authed(world, install, "session", { signedTransaction: due.signedTransaction });
    expect(after.status).toBe(403);
    expect(((await after.json()) as { error: { code: string } }).error.code).toBe("data-deleted");

    // A day later the other one is due too; a third run finds nothing more for the first.
    world.clock.now = new Date(NOW + 62 * DAY);
    const third = await cron(world);
    expect(third).toMatchObject({ objectsDeleted: 5, foldersEmptied: 1, unfinished: false });
    expect(await countObjects(active.prefix)).toBe(5);
    world.clock.now = new Date(NOW);
  });

  it("deletes a revoked subscription's data DELETE_AFTER_DAYS after the revocation", async () => {
    const id = String(nextId++);
    const live = await startSubscription({ originalTransactionId: id, transactionId: id });
    await putObjects(live.prefix, 3, 1);
    const revoked = await sign(world, { ...live.transaction, revocationDate: NOW, signedDate: NOW });
    expect((await authed(world, install, "session", { signedTransaction: revoked })).status).toBe(403);
    world.clock.now = new Date(NOW + 60 * DAY - 1);
    expect((await cron(world)).objectsDeleted).toBe(0);
    world.clock.now = new Date(NOW + 60 * DAY);
    expect((await cron(world)).objectsDeleted).toBe(3);
    expect(await rowFor(live.userKey)).toMatchObject({ data_deleted_at: NOW + 60 * DAY });
    world.clock.now = new Date(NOW);
  });

  it("counts from the end of billing retry, not from the expiry date", async () => {
    const id = String(nextId++);
    const lapsing = await startSubscription({ originalTransactionId: id, transactionId: id, expiresDate: NOW + DAY });
    await putObjects(lapsing.prefix, 3, 1);
    // Apple reports billing retry, and then nothing more: retry counts as active for at most 60
    // days after the expiry (to NOW + 61 days), and the deletion clock starts there.
    const renewal = await sign(world, { originalTransactionId: id, isInBillingRetryPeriod: true, signedDate: NOW + 2 * DAY, environment: "Production" });
    world.clock.now = new Date(NOW + 2 * DAY);
    expect((await authed(world, install, "session", { signedTransaction: lapsing.signedTransaction, signedRenewalInfo: renewal })).status).toBe(200);
    // Long past expiry + 60 days, but not 60 days past the end of retry: kept.
    world.clock.now = new Date(NOW + 121 * DAY - 1);
    await cronUntilDone();
    expect(await countObjects(lapsing.prefix)).toBe(3);
    world.clock.now = new Date(NOW + 121 * DAY);
    await cronUntilDone();
    expect(await countObjects(lapsing.prefix)).toBe(0);
    world.clock.now = new Date(NOW);
  });
});
