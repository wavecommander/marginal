// The dev test entitlement (src/devEntitlement.ts): in `dev` with DEV_TEST_ENTITLEMENT, an account
// whose sign-in is a dev test identity is served as subscribed with no App Store transaction.
// Never a real Apple or Google identity, never in production, never stored, and invisible to
// App Store notifications, the lapse cron and account deletion.

import { env } from "cloudflare:workers";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { AccountResponse, DeleteAccountResponse, SessionResponse, SignInResponse } from "../../src/contract";
import type { Provider } from "../../src/identity";
import { DAY, signedNotification, transactionPayload } from "../helpers/apple";
import { base64 } from "../helpers/pki";
import { DEV_SIGNIN_SECRET, PRODUCT, SANDBOX_ALLOWANCE } from "../helpers/settings";
import {
  attestedInstall,
  attestedPost,
  call,
  countObjects,
  cron,
  deletedFolder,
  devIdToken,
  errorCode,
  idToken,
  makeWorld,
  newSubject,
  postJson,
  putObjects,
  rowsFor,
  sign,
  type Install,
  type World,
} from "./harness";

const DEV = { ENVIRONMENT: "dev", R2_S3_HOST: "localhost:8787", APP_APPLE_ID: "" } as const;
const NOW = Date.parse("2026-11-15T12:00:00Z");

let dev: World;
let logged: string[] = [];
let nextId = 7000000000000000;

beforeAll(async () => {
  dev = await makeWorld({ ...DEV, DEV_TEST_SIGNIN_SECRET: DEV_SIGNIN_SECRET, DEV_TEST_ENTITLEMENT: PRODUCT });
});

beforeEach(() => {
  logged = [];
  for (const level of ["log", "info", "warn", "error", "debug"] as const) {
    vi.spyOn(console, level).mockImplementation((...args: unknown[]) => {
      logged.push(args.map((arg) => (typeof arg === "string" ? arg : JSON.stringify(arg))).join(" "));
    });
  }
});

afterEach(() => {
  vi.restoreAllMocks();
  dev.clock.now = new Date(NOW);
});

type TokenMaker = (challenge: string) => Promise<string>;
const devToken = (world: World, subject: string): TokenMaker => (challenge) => devIdToken(world, subject, challenge);
const realToken = (world: World, provider: Provider, subject: string): TokenMaker => (challenge) => idToken(world, provider, subject, challenge);

interface Signed {
  install: Install;
  token: string;
  accountId: string;
}

async function signedIn(world: World, provider: Provider, token: TokenMaker): Promise<Signed> {
  const install = await attestedInstall(world);
  const response = await attestedPost(world, install, provider === "apple" ? "/v1/auth/apple" : "/v1/auth/google", async (challenge) => ({
    idToken: await token(challenge),
    ...(provider === "apple" ? { authorizationCode: "c-sign-in" } : {}),
  }));
  if (response.status !== 200) throw new Error(`sign-in: ${response.status} ${await response.text()}`);
  const body = (await response.json()) as SignInResponse;
  return { install, token: body.deviceSessionToken, accountId: body.account.accountId };
}

function session(world: World, who: Signed, signedTransaction?: string): Promise<Response> {
  return attestedPost(world, who.install, "/v1/session", { deviceSessionToken: who.token, ...(signedTransaction ? { signedTransaction } : {}) });
}

async function sessionOk(world: World, who: Signed, signedTransaction?: string): Promise<SessionResponse> {
  const response = await session(world, who, signedTransaction);
  if (response.status !== 200) throw new Error(`session: ${response.status} ${await response.text()}`);
  return response.json();
}

async function accountScreen(world: World, who: Signed): Promise<AccountResponse> {
  const response = await attestedPost(world, who.install, "/v1/account", { deviceSessionToken: who.token });
  if (response.status !== 200) throw new Error(`account: ${response.status}`);
  return response.json();
}

function change(world: World, who: Signed, newProvider: Provider, current: TokenMaker, next: TokenMaker): Promise<Response> {
  return attestedPost(world, who.install, "/v1/auth/change", async (challenge) => ({
    deviceSessionToken: who.token,
    currentIdToken: await current(challenge),
    currentAuthorizationCode: "c-current",
    newProvider,
    newIdToken: await next(challenge),
  }));
}

async function devTestFlag(accountId: string): Promise<number | undefined> {
  return (await env.DB.prepare("SELECT identity_dev_test AS flag FROM accounts WHERE account_id = ?").bind(accountId).first<{ flag: number }>())?.flag;
}

/** A Sandbox purchase (accepted by `dev`) for `who`'s account, as the app would send it. */
function sandboxTransaction(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const id = String(nextId++);
  return transactionPayload({ environment: "Sandbox", originalTransactionId: id, transactionId: id, signedDate: NOW - 10 * DAY, purchaseDate: NOW - 10 * DAY, expiresDate: NOW + 20 * DAY, ...overrides });
}

describe("the dev test entitlement, in dev with the dev test issuer on", () => {
  it("gives a dev test account a read-write session in sandbox/ with the sandbox allowance, with no transaction and nothing stored", async () => {
    for (const provider of ["apple", "google"] as const) {
      const reader = await signedIn(dev, provider, devToken(dev, newSubject(provider)));
      expect(await devTestFlag(reader.accountId)).toBe(1);
      const body = await sessionOk(dev, reader);
      expect(body.mode).toBe("read-write");
      expect(body.storage.prefix).toMatch(/^sandbox\/[0-9a-f]{64}\/$/);
      expect(body.subscription).toMatchObject({ state: "active", environment: "Xcode", productId: PRODUCT, endedAt: null, readOnlyUntil: null, deleteAfter: null });
      expect(Date.parse(body.subscription.expiresAt!)).toBeGreaterThan(NOW);
      expect(body.usage).toMatchObject({ bytes: 0, allowanceBytes: SANDBOX_ALLOWANCE, overAllowance: false });
      expect(body.credentials.accessKeyId).toBeTruthy();
      // The account screen says the same, and nothing was written for it.
      const screen = await accountScreen(dev, reader);
      expect(screen.subscription).toMatchObject({ state: "active", environment: "Xcode", productId: PRODUCT });
      expect(screen.usage).toMatchObject({ allowanceBytes: SANDBOX_ALLOWANCE });
      expect(await rowsFor(reader.accountId)).toEqual({ accounts: 1, device_sessions: 1, subscribers: 0 });
    }
    const sessionLines = logged.filter((line) => line.includes('"session"'));
    expect(sessionLines.length).toBe(2);
    for (const line of sessionLines) expect(JSON.parse(line)).toMatchObject({ event: "session", mode: "read-write", entitlement: "dev-test" });
    for (const line of logged) expect(line).not.toContain(DEV_SIGNIN_SECRET);
  });

  it("stays active a year on; over the allowance it is read-delete like any sandbox subscription", async () => {
    const reader = await signedIn(dev, "apple", devToken(dev, newSubject("apple")));
    const prefix = (await sessionOk(dev, reader)).storage.prefix;
    dev.clock.now = new Date(NOW + 365 * DAY);
    expect((await sessionOk(dev, reader)).mode).toBe("read-write");
    await putObjects(prefix, 2, SANDBOX_ALLOWANCE);
    dev.clock.now = new Date(NOW + 366 * DAY);
    const over = await sessionOk(dev, reader);
    expect(over.mode).toBe("read-delete");
    expect(over.usage.overAllowance).toBe(true);
  });

  it("never applies to a real Apple or Google identity, even with the same subject", async () => {
    for (const provider of ["apple", "google"] as const) {
      const subject = newSubject(provider);
      const real = await signedIn(dev, provider, realToken(dev, provider, subject));
      expect(await devTestFlag(real.accountId)).toBe(0);
      expect(await errorCode(await session(dev, real))).toBe("not-subscribed");
      expect((await accountScreen(dev, real)).subscription).toBeNull();
      // The dev identity with the same subject is another account, and it is entitled.
      const devReader = await signedIn(dev, provider, devToken(dev, subject));
      expect(devReader.accountId).not.toBe(real.accountId);
      expect((await sessionOk(dev, devReader)).mode).toBe("read-write");
    }
  });

  it("follows the identity when the sign-in changes, in both directions", async () => {
    // A dev test account changed to a real Google identity loses it.
    const devSubject = newSubject("apple");
    const reader = await signedIn(dev, "apple", devToken(dev, devSubject));
    expect((await sessionOk(dev, reader)).mode).toBe("read-write");
    expect((await change(dev, reader, "google", devToken(dev, devSubject), realToken(dev, "google", newSubject("google")))).status).toBe(200);
    expect(await devTestFlag(reader.accountId)).toBe(0);
    expect(await errorCode(await session(dev, reader))).toBe("not-subscribed");

    // An account changed to a dev test identity is a dev test account from then on.
    const realSubject = newSubject("google");
    const other = await signedIn(dev, "google", realToken(dev, "google", realSubject));
    expect(await errorCode(await session(dev, other))).toBe("not-subscribed");
    expect((await change(dev, other, "apple", realToken(dev, "google", realSubject), devToken(dev, newSubject("apple")))).status).toBe(200);
    expect(await devTestFlag(other.accountId)).toBe(1);
    expect((await sessionOk(dev, other)).mode).toBe("read-write");
  });

  it("a real purchase the account presents binds and is served as without the switch; a stored one wins a tie", async () => {
    const reader = await signedIn(dev, "google", devToken(dev, newSubject("google")));
    const transaction = sandboxTransaction();
    const bound = await sessionOk(dev, reader, await sign(dev, transaction));
    expect(bound.subscription).toMatchObject({ environment: "Sandbox", state: "active" });
    expect((await rowsFor(reader.accountId)).subscribers).toBe(1);
    // Without a transaction: the stored, active one (same folder, same access) is chosen.
    const served = await sessionOk(dev, reader);
    expect(served.subscription.environment).toBe("Sandbox");
    expect(served.storage.prefix).toBe(bound.storage.prefix);
    expect(logged.filter((line) => line.includes('"session"')).every((line) => !line.includes("dev-test"))).toBe(true);
  });
});

describe("App Store notifications and the lapse cron are not confused by it", () => {
  it("a notification only ever changes the stored purchase; a refunded purchase leaves the dev test entitlement serving", async () => {
    const reader = await signedIn(dev, "apple", devToken(dev, newSubject("apple")));
    const transaction = sandboxTransaction();
    await sessionOk(dev, reader, await sign(dev, transaction));
    const before = await env.DB.prepare("SELECT account_id, namespace FROM subscribers WHERE account_id = ?").bind(reader.accountId).all();
    const refunded = { ...transaction, revocationDate: NOW - DAY, revocationReason: 0, signedDate: NOW - DAY };
    const response = await postJson(dev, "/v1/apple/notifications", { signedPayload: await signedNotification(dev.chain, "REFUND", undefined, refunded, undefined) });
    expect(response.status).toBe(200);
    const after = await env.DB.prepare("SELECT account_id, namespace, revoked_at FROM subscribers WHERE account_id = ?").bind(reader.accountId).all<{ revoked_at: number | null }>();
    expect(after.results.length).toBe(before.results.length);
    expect(after.results[0]!.revoked_at).toBe(NOW - DAY);
    // With the refunded transaction: refused, as for anyone. Without one: the dev entitlement.
    expect(await errorCode(await session(dev, reader, await sign(dev, refunded)))).toBe("subscription-revoked");
    expect((await sessionOk(dev, reader)).subscription.environment).toBe("Xcode");

    // A notification for a subscription nobody presented is still ignored.
    const stranger = sandboxTransaction();
    expect((await postJson(dev, "/v1/apple/notifications", { signedPayload: await signedNotification(dev.chain, "DID_RENEW", undefined, stranger, undefined) })).status).toBe(200);
    expect(logged.some((line) => line.includes("ignored-unknown-subscription"))).toBe(true);
    expect((await rowsFor(reader.accountId)).subscribers).toBe(1);
  });

  it("the cron never empties a dev test account's folder while the switch is on, and does once it is off", async () => {
    const reader = await signedIn(dev, "google", devToken(dev, newSubject("google")));
    const prefix = (await sessionOk(dev, reader)).storage.prefix;
    await putObjects(prefix, 3);
    // A Sandbox purchase that ended long ago is stored for the same folder.
    const old = sandboxTransaction({ signedDate: NOW - 200 * DAY, purchaseDate: NOW - 200 * DAY, expiresDate: NOW - 170 * DAY });
    expect(await errorCode(await session(dev, reader, await sign(dev, old)))).toBe("data-deleted");
    expect((await rowsFor(reader.accountId)).subscribers).toBe(1);

    dev.clock.now = new Date(NOW + 400 * DAY);
    for (let i = 0; i < 20 && (await cron(dev)).unfinished; i++);
    expect(await countObjects(prefix)).toBe(3);
    expect((await sessionOk(dev, reader)).mode).toBe("read-write");

    // The switch off (same database): the stored purchase's lapse policy applies again.
    const off = await makeWorld({ ...DEV, DEV_TEST_SIGNIN_SECRET: DEV_SIGNIN_SECRET });
    off.clock.now = dev.clock.now;
    for (let i = 0; i < 20 && (await cron(off)).unfinished; i++);
    expect(await countObjects(prefix)).toBe(0);
  });
});

describe("deleting a dev test account", () => {
  it("leaves nothing in D1 or R2", async () => {
    const subject = newSubject("apple");
    const reader = await signedIn(dev, "apple", devToken(dev, subject));
    const prefix = (await sessionOk(dev, reader)).storage.prefix;
    const folderKey = prefix.split("/")[1]!;
    await putObjects(prefix, 4);
    await putObjects(`users/${folderKey}/`, 2);
    const first = await attestedPost(dev, reader.install, "/v1/account/delete", async (challenge) => ({
      deviceSessionToken: reader.token,
      idToken: await devIdToken(dev, subject, challenge),
      authorizationCode: "c-delete",
    }));
    expect(first.status).toBe(200);
    expect(((await first.json()) as DeleteAccountResponse).done).toBe(true);
    expect(await rowsFor(reader.accountId)).toEqual({ accounts: 0, device_sessions: 0, subscribers: 0 });
    expect(await countObjects(prefix)).toBe(0);
    expect(await countObjects(`users/${folderKey}/`)).toBe(0);
    // Only the folder name is kept, until the last credential could have expired.
    expect(await deletedFolder(folderKey)).not.toBeNull();
    dev.clock.now = new Date(NOW + DAY);
    for (let i = 0; i < 20 && (await cron(dev)).unfinished; i++);
    expect(await deletedFolder(folderKey)).toBeNull();
    // The same dev identity signs in to a new, empty, entitled account.
    const again = await signedIn(dev, "apple", devToken(dev, subject));
    expect(again.accountId).not.toBe(reader.accountId);
    expect((await sessionOk(dev, again)).storage.prefix).not.toBe(prefix);
  });
});

describe("the dev test entitlement off", () => {
  it("in dev without DEV_TEST_ENTITLEMENT, or with it but without the dev test issuer: not-subscribed", async () => {
    const subject = newSubject("apple");
    const withIssuer = await makeWorld({ ...DEV, DEV_TEST_SIGNIN_SECRET: DEV_SIGNIN_SECRET });
    const reader = await signedIn(withIssuer, "apple", devToken(withIssuer, subject));
    expect(await errorCode(await session(withIssuer, reader))).toBe("not-subscribed");
    // The entitlement set but the issuer off: the dev test account made earlier is not served.
    const noIssuer = await makeWorld({ ...DEV, DEV_TEST_ENTITLEMENT: PRODUCT });
    expect(await errorCode(await session(noIssuer, reader))).toBe("not-subscribed");
  });

  it("in production: the setting's mere presence stops the Worker, naming it", async () => {
    for (const value of [PRODUCT, ""]) {
      const misconfigured = await makeWorld({ DEV_TEST_ENTITLEMENT: value });
      for (const path of ["/v1/challenge", "/v1/session"]) {
        const response = await postJson(misconfigured, path, { action: "session", challenge: base64(new Uint8Array(32)), deviceSessionToken: "x".repeat(43) });
        expect(response.status).toBe(500);
        expect(await errorCode(response)).toBe("internal");
      }
      expect((await call(misconfigured, "/v1/health")).status).toBe(500);
      expect(logged.some((line) => line.includes("DEV_TEST_ENTITLEMENT must not exist in production"))).toBe(true);
    }
  });
});
