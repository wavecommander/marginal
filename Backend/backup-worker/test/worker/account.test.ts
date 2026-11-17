import { env } from "cloudflare:workers";
import { afterEach, beforeAll, describe, expect, it } from "vitest";
import type { AccountResponse, DeleteAccountResponse, SessionResponse, SignInResponse, SignOutResponse } from "../../src/contract";
import type { Provider } from "../../src/identity";
import { DAY, transactionPayload } from "../helpers/apple";
import { rsaSigningKey, signRs256 } from "../helpers/oidc";
import { ALLOWANCE } from "../helpers/settings";
import {
  attestedInstall,
  attestedPost,
  authed,
  countObjects,
  cron,
  errorCode,
  idToken,
  makeWorld,
  newSubject,
  postJson,
  putObjects,
  rowsFor,
  sessionOk,
  sign,
  signInRequest,
  signedInReader,
  type Reader,
  type World,
} from "./harness";

let world: World;
let nextId = 8500000000000000;
const NOW = Date.parse("2026-11-15T12:00:00Z");

beforeAll(async () => {
  world = await makeWorld({}, { deleteRequestBudget: 3 });
});

afterEach(() => {
  world.clock.now = new Date(NOW);
});

async function subscribe(reader: Reader, overrides: Record<string, unknown> = {}): Promise<{ session: SessionResponse; signedTransaction: string; id: string }> {
  const id = String(nextId++);
  const transaction = transactionPayload({ originalTransactionId: id, transactionId: id, signedDate: NOW - DAY, purchaseDate: NOW - DAY, expiresDate: NOW + 29 * DAY, ...overrides });
  const signedTransaction = await sign(world, transaction);
  return { session: await sessionOk(await authed(world, reader, "session", { signedTransaction })), signedTransaction, id };
}

/** Another device signing in to the reader's account. */
async function secondDevice(reader: Reader): Promise<Reader> {
  const install = await attestedInstall(world);
  const body = (await (await signInRequest(world, install, reader.provider, reader.subject)).json()) as SignInResponse;
  return { ...reader, install, token: body.deviceSessionToken, sessionId: body.sessionId };
}

function account(reader: Reader, extra: Record<string, unknown> = {}): Promise<Response> {
  return attestedPost(world, reader.install, "/v1/account", { deviceSessionToken: reader.token, ...extra });
}

function signOut(reader: Reader, all = false): Promise<Response> {
  return attestedPost(world, reader.install, all ? "/v1/auth/signout-all" : "/v1/auth/signout", { deviceSessionToken: reader.token });
}

function deleteAccount(reader: Reader, proof: { subject?: string; provider?: Provider; code?: string | null; none?: boolean } = {}): Promise<Response> {
  return attestedPost(world, reader.install, "/v1/account/delete", async (challenge) => ({
    deviceSessionToken: reader.token,
    ...(proof.none ? {} : { idToken: await idToken(world, proof.provider ?? reader.provider, proof.subject ?? reader.subject, challenge) }),
    ...(proof.code === null || reader.provider !== "apple" ? {} : { authorizationCode: proof.code ?? "c-delete" }),
  }));
}

describe("POST /v1/account", () => {
  it("lists the sign-in, the devices (this one marked), the subscription and usage; never the subject", async () => {
    const reader = await signedInReader(world, "google");
    const other = await secondDevice(reader);
    const empty = (await (await account(reader)).json()) as AccountResponse;
    expect(empty.subscription).toBeNull();
    expect(empty.usage).toBeNull();
    const { session } = await subscribe(reader);
    await putObjects(session.storage.prefix, 3, 5);
    world.clock.now = new Date(NOW + 60_000);
    const response = await account(other, { deviceLabel: "bGFiZWw=" });
    expect(response.status).toBe(200);
    const body = (await response.json()) as AccountResponse;
    expect(body).toMatchObject({ accountId: reader.accountId, provider: "google", appAccountToken: reader.appAccountToken });
    expect(body.devices).toEqual([
      { sessionId: reader.sessionId, createdAt: new Date(NOW).toISOString(), lastUsedAt: new Date(NOW).toISOString(), label: null, current: false },
      { sessionId: other.sessionId, createdAt: new Date(NOW).toISOString(), lastUsedAt: new Date(NOW + 60_000).toISOString(), label: "bGFiZWw=", current: true },
    ]);
    expect(body.subscription).toEqual(session.subscription);
    // The usage was counted at the session (cached for five minutes): an empty folder then.
    expect(body.usage).toEqual({ bytes: 0, allowanceBytes: ALLOWANCE, overAllowance: false, countedAt: new Date(NOW).toISOString() });
    expect(JSON.stringify(body)).not.toContain(reader.subject);
  });
});

describe("signing out", () => {
  it("ends this device's session only; the account and its folder stay", async () => {
    const reader = await signedInReader(world);
    const other = await secondDevice(reader);
    const { session } = await subscribe(reader);
    await putObjects(session.storage.prefix, 2);
    const response = await signOut(reader);
    expect(response.status).toBe(200);
    expect((await response.json()) as SignOutResponse).toEqual({ ok: true, endedSessions: 1 });
    expect(await errorCode(await authed(world, reader, "session"))).toBe("session-invalid");
    expect(await errorCode(await signOut(reader))).toBe("session-invalid");
    expect((await authed(world, other, "session")).status).toBe(200);
    expect(await countObjects(session.storage.prefix)).toBe(2);
    // Signing back in reaches the same account and folder.
    const back = await signedInReader(world, reader.provider, reader.subject, reader.install);
    expect(back.accountId).toBe(reader.accountId);
    expect((await sessionOk(await authed(world, back, "session"))).storage.prefix).toBe(session.storage.prefix);
  });

  it("of all devices ends every session of the account and no other account's", async () => {
    const reader = await signedInReader(world);
    const devices = [reader, await secondDevice(reader), await secondDevice(reader)];
    const stranger = await signedInReader(world);
    const response = await signOut(devices[1]!, true);
    expect((await response.json()) as SignOutResponse).toEqual({ ok: true, endedSessions: 3 });
    for (const device of devices) expect(await errorCode(await authed(world, device, "delete-my-data"))).toBe("session-invalid");
    expect((await authed(world, stranger, "delete-my-data")).status).toBe(200);
    expect(await rowsFor(reader.accountId)).toEqual({ accounts: 1, device_sessions: 0, subscribers: 0 });
  });
});

describe("deleting the account", () => {
  it("empties both folders in batches, then leaves nothing in D1 or R2; Apple is revoked", async () => {
    const reader = await signedInReader(world, "apple");
    const other = await secondDevice(reader);
    const { session, signedTransaction } = await subscribe(reader);
    const folderKey = session.storage.prefix.split("/")[1]!;
    await putObjects(session.storage.prefix, 1500);
    await putObjects(`sandbox/${folderKey}/`, 4);
    const neighbour = await signedInReader(world);
    const neighbourSession = (await subscribe(neighbour)).session;
    await putObjects(neighbourSession.storage.prefix, 2);
    world.outbound.length = 0;

    const first = await deleteAccount(reader, { code: "c-delete-me" });
    expect(first.status).toBe(200);
    expect((await first.json()) as DeleteAccountResponse).toEqual({ done: false, deletedObjects: 1000 });
    expect(world.outbound.map((call) => [call.url, call.form.code ?? call.form.token])).toEqual([
      ["https://appleid.apple.com/auth/token", "c-delete-me"],
      ["https://appleid.apple.com/auth/revoke", "test-refresh-for-c-delete-me"],
    ]);
    // The other device is signed out at once; the account can no longer be used meanwhile.
    expect(await errorCode(await authed(world, other, "session"))).toBe("session-invalid");
    expect(await errorCode(await authed(world, reader, "session"))).toBe("account-deleting");
    expect(await errorCode(await signInRequest(world, await attestedInstall(world), "apple", reader.subject))).toBe("account-deleting");

    // Later calls need no new sign-in.
    const results: DeleteAccountResponse[] = [];
    for (let i = 0; i < 5; i++) {
      const body = (await (await deleteAccount(reader, { none: true })).json()) as DeleteAccountResponse;
      results.push(body);
      if (body.done) break;
    }
    expect(results.at(-1)!.done).toBe(true);
    expect(results.reduce((n, r) => n + r.deletedObjects, 0)).toBe(504);
    expect(world.outbound.length).toBe(2);

    expect(await countObjects(session.storage.prefix)).toBe(0);
    expect(await countObjects(`sandbox/${folderKey}/`)).toBe(0);
    expect(await rowsFor(reader.accountId)).toEqual({ accounts: 0, device_sessions: 0, subscribers: 0 });
    const anywhere = JSON.stringify(await env.DB.batch(["accounts", "device_sessions", "subscribers"].map((t) => env.DB.prepare(`SELECT * FROM ${t}`))));
    expect(anywhere).not.toContain(reader.accountId);
    expect(anywhere).not.toContain(folderKey);
    expect(anywhere).not.toContain(reader.appAccountToken);
    expect(await countObjects(neighbourSession.storage.prefix)).toBe(2);
    expect(await errorCode(await deleteAccount(reader, { none: true }))).toBe("session-invalid");

    // The identity is free: signing in makes a new, empty account, and the subscription binds to it.
    const again = await signedInReader(world, "apple", reader.subject);
    expect(again.accountId).not.toBe(reader.accountId);
    const rebound = await sessionOk(await authed(world, again, "session", { signedTransaction }));
    expect(rebound.storage.prefix).not.toBe(session.storage.prefix);
  });

  it("needs a fresh ID token from the current sign-in, and Apple's code, before anything is deleted", async () => {
    const reader = await signedInReader(world, "apple");
    const { session } = await subscribe(reader);
    await putObjects(session.storage.prefix, 2);
    expect(await errorCode(await deleteAccount(reader, { none: true }))).toBe("bad-request");
    expect(await errorCode(await deleteAccount(reader, { code: null }))).toBe("bad-request");
    expect(await errorCode(await deleteAccount(reader, { subject: newSubject("apple") }))).toBe("identity-mismatch");
    expect(await errorCode(await deleteAccount(reader, { provider: "google" }))).toBe("id-token-invalid");
    expect(await countObjects(session.storage.prefix)).toBe(2);
    expect(await rowsFor(reader.accountId)).toEqual({ accounts: 1, device_sessions: 1, subscribers: 1 });
    expect((await authed(world, reader, "session")).status).toBe(200);
  });

  it("for Google needs no authorization code and calls nobody", async () => {
    const reader = await signedInReader(world, "google");
    world.outbound.length = 0;
    const body = (await (await deleteAccount(reader)).json()) as DeleteAccountResponse;
    expect(body).toEqual({ done: true, deletedObjects: 0 });
    expect(world.outbound).toEqual([]);
    expect(await rowsFor(reader.accountId)).toEqual({ accounts: 0, device_sessions: 0, subscribers: 0 });
  });

  it("still deletes when Apple cannot be reached to revoke", async () => {
    const reader = await signedInReader(world, "apple");
    world.appleStatus.token = 503;
    try {
      expect(((await (await deleteAccount(reader)).json()) as DeleteAccountResponse).done).toBe(true);
    } finally {
      world.appleStatus.token = 200;
    }
    expect(await rowsFor(reader.accountId)).toEqual({ accounts: 0, device_sessions: 0, subscribers: 0 });
  });

  it("left unfinished by the app, is finished by the cron after fifteen minutes", async () => {
    const reader = await signedInReader(world, "google");
    const { session } = await subscribe(reader);
    await putObjects(session.storage.prefix, 1200);
    expect(((await (await deleteAccount(reader)).json()) as DeleteAccountResponse).done).toBe(false);
    world.clock.now = new Date(NOW + 15 * 60_000 - 1);
    expect((await cron(world)).accountsRemoved).toBe(0);
    world.clock.now = new Date(NOW + 15 * 60_000);
    let removed = 0;
    for (let i = 0; i < 5 && removed === 0; i++) removed += (await cron(world)).accountsRemoved;
    expect(removed).toBe(1);
    expect(await countObjects(session.storage.prefix)).toBe(0);
    expect(await rowsFor(reader.accountId)).toEqual({ accounts: 0, device_sessions: 0, subscribers: 0 });
  });
});

describe("Sign in with Apple notifications", () => {
  async function notify(type: string, subject: string, key = world.signingKeys.apple, overrides: Record<string, unknown> = {}): Promise<Response> {
    const iat = Math.floor(world.clock.now.getTime() / 1000);
    const payload = await signRs256(
      { iss: "https://appleid.apple.com", aud: "software.tactile.texts", iat, jti: crypto.randomUUID(), events: JSON.stringify({ type, sub: subject, event_time: iat * 1000 }), ...overrides },
      key,
    );
    return postJson(world, "/v1/apple/signin-notifications", { payload });
  }

  for (const type of ["consent-revoked", "account-delete"]) {
    it(`${type} ends every session of that Apple identity's account and keeps its data`, async () => {
      const reader = await signedInReader(world, "apple");
      const other = await secondDevice(reader);
      const { session } = await subscribe(reader);
      await putObjects(session.storage.prefix, 2);
      const bystander = await signedInReader(world, "apple");
      const response = await notify(type, reader.subject);
      expect(response.status).toBe(200);
      expect(await response.json()).toEqual({ ok: true });
      for (const device of [reader, other]) expect(await errorCode(await authed(world, device, "session"))).toBe("session-invalid");
      expect((await authed(world, bystander, "delete-my-data")).status).toBe(200);
      expect(await countObjects(session.storage.prefix)).toBe(2);
      expect(await rowsFor(reader.accountId)).toEqual({ accounts: 1, device_sessions: 0, subscribers: 1 });
      // Signing in again reaches the same account.
      expect((await signedInReader(world, "apple", reader.subject)).accountId).toBe(reader.accountId);
    });
  }

  it("acknowledges other events, unknown identities and Google subjects without effect", async () => {
    const reader = await signedInReader(world, "apple");
    const google = await signedInReader(world, "google");
    expect((await notify("email-disabled", reader.subject)).status).toBe(200);
    expect((await notify("consent-revoked", newSubject("apple"))).status).toBe(200);
    expect((await notify("consent-revoked", google.subject)).status).toBe(200);
    expect((await authed(world, reader, "delete-my-data")).status).toBe(200);
    expect((await authed(world, google, "delete-my-data")).status).toBe(200);
  });

  it("refuses a forged notification or one for another app, and changes nothing", async () => {
    const reader = await signedInReader(world, "apple");
    const forger = await rsaSigningKey({ kid: world.signingKeys.apple.kid });
    const forged = await notify("consent-revoked", reader.subject, forger);
    expect(forged.status).toBe(401);
    expect(await errorCode(forged)).toBe("notification-invalid");
    expect(await errorCode(await notify("consent-revoked", reader.subject, world.signingKeys.apple, { aud: "com.example.other" }))).toBe("notification-invalid");
    expect(await errorCode(await notify("consent-revoked", reader.subject, world.signingKeys.google))).toBe("notification-invalid");
    expect((await authed(world, reader, "delete-my-data")).status).toBe(200);
  });
});
