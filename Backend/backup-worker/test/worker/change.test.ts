import { env } from "cloudflare:workers";
import { beforeAll, describe, expect, it } from "vitest";
import type { AccountResponse, SessionResponse, SignInResponse } from "../../src/contract";
import type { Provider } from "../../src/identity";
import { DAY, transactionPayload } from "../helpers/apple";
import { attestedInstall, attestedPost, authed, errorCode, idToken, makeWorld, newSubject, sessionOk, sign, signInRequest, signedInReader, type Reader, type World } from "./harness";

let world: World;
let nextId = 8000000000000000;
const NOW = Date.parse("2026-11-15T12:00:00Z");

beforeAll(async () => {
  world = await makeWorld();
});

/** A signed-in reader with an active subscription bound to the account. */
async function subscribedReader(provider: Provider = "apple"): Promise<{ reader: Reader; session: SessionResponse }> {
  const reader = await signedInReader(world, provider);
  const id = String(nextId++);
  const transaction = transactionPayload({ originalTransactionId: id, transactionId: id, signedDate: NOW - DAY, purchaseDate: NOW - DAY, expiresDate: NOW + 29 * DAY, appAccountToken: reader.appAccountToken });
  const session = await sessionOk(await authed(world, reader, "session", { signedTransaction: await sign(world, transaction) }));
  return { reader, session };
}

interface ChangeOptions {
  currentProvider?: Provider;
  currentSubject?: string;
  newProvider: Provider;
  newSubject: string;
  currentAuthorizationCode?: string | null;
  /** Spoil the new ID token's audience: the second step fails. */
  spoilNew?: boolean;
}

function change(reader: Reader, options: ChangeOptions): Promise<Response> {
  return attestedPost(world, reader.install, "/v1/auth/change", async (challenge) => ({
    deviceSessionToken: reader.token,
    currentIdToken: await idToken(world, options.currentProvider ?? reader.provider, options.currentSubject ?? reader.subject, challenge),
    ...(options.currentAuthorizationCode === null ? {} : { currentAuthorizationCode: options.currentAuthorizationCode ?? "c-current" }),
    newProvider: options.newProvider,
    newIdToken: await idToken(world, options.newProvider, options.newSubject, challenge, options.spoilNew ? { aud: "com.example.other" } : {}),
  }));
}

async function signInAs(provider: Provider, subject: string): Promise<SignInResponse> {
  const response = await signInRequest(world, await attestedInstall(world), provider, subject);
  if (response.status !== 200) throw new Error(`${response.status} ${await response.text()}`);
  return response.json();
}

async function accountRow(accountId: string) {
  return env.DB.prepare("SELECT * FROM accounts WHERE account_id = ?").bind(accountId).first<Record<string, unknown>>();
}

describe("changing the sign-in", () => {
  it("Apple to Google and back: the same account, folder and subscription; only the new sign-in reaches it", async () => {
    const { reader, session } = await subscribedReader("apple");
    const googleSubject = newSubject("google");
    world.outbound.length = 0;

    const toGoogle = await change(reader, { newProvider: "google", newSubject: googleSubject, currentAuthorizationCode: "c-leaving-apple" });
    expect(toGoogle.status).toBe(200);
    const changed = (await toGoogle.json()) as AccountResponse;
    expect(changed).toMatchObject({ accountId: reader.accountId, provider: "google", appAccountToken: reader.appAccountToken });
    expect(changed.subscription).toMatchObject({ state: "active", expiresAt: session.subscription.expiresAt });
    // Leaving Apple revoked the Apple authorization, with the confirming sign-in's code.
    expect(world.outbound.map((call) => call.url)).toEqual(["https://appleid.apple.com/auth/token", "https://appleid.apple.com/auth/revoke"]);
    expect(world.outbound[0]!.form.code).toBe("c-leaving-apple");
    expect(world.outbound[1]!.form.token).toBe("test-refresh-for-c-leaving-apple");

    // The folder and the subscription are unchanged, for this device.
    expect((await sessionOk(await authed(world, reader, "session"))).storage.prefix).toBe(session.storage.prefix);
    // Google now reaches the account; Apple's old identity makes a new, empty one.
    expect((await signInAs("google", googleSubject)).account.accountId).toBe(reader.accountId);
    const apple = await signInAs("apple", reader.subject);
    expect(apple.newAccount).toBe(true);
    expect(apple.account.accountId).not.toBe(reader.accountId);
    // Exactly one identity, the new one.
    expect(await accountRow(reader.accountId)).toMatchObject({ identity_provider: "google", identity_changed_at: NOW });
    expect((await env.DB.prepare("SELECT COUNT(*) AS n FROM accounts WHERE account_id = ?").bind(reader.accountId).first<{ n: number }>())?.n).toBe(1);

    // And back to Apple (a new Apple ID, since the old one now has its own account). No revocation leaving Google.
    world.outbound.length = 0;
    const appleAgain = newSubject("apple");
    const google: Reader = { ...reader, provider: "google", subject: googleSubject };
    const back = await change(google, { newProvider: "apple", newSubject: appleAgain, currentAuthorizationCode: null });
    expect(back.status).toBe(200);
    expect(((await back.json()) as AccountResponse).provider).toBe("apple");
    expect(world.outbound).toEqual([]);
    expect((await signInAs("apple", appleAgain)).account.accountId).toBe(reader.accountId);
    expect((await signInAs("google", googleSubject)).newAccount).toBe(true);
    const after = await sessionOk(await authed(world, reader, "session"));
    expect(after.storage.prefix).toBe(session.storage.prefix);
    expect(after.subscription.expiresAt).toBe(session.subscription.expiresAt);
  });

  it("keeps the account's other devices signed in", async () => {
    const { reader } = await subscribedReader("google");
    const install = await attestedInstall(world);
    const second = (await (await signInRequest(world, install, "google", reader.subject)).json()) as SignInResponse;
    expect((await change(reader, { newProvider: "apple", newSubject: newSubject("apple") })).status).toBe(200);
    const secondReader = { ...reader, install, token: second.deviceSessionToken };
    expect((await authed(world, secondReader, "session")).status).toBe(200);
  });

  it("is refused when the new identity already has an account, and nothing changes", async () => {
    const { reader } = await subscribedReader("apple");
    const taken = await signedInReader(world, "google");
    const response = await change(reader, { newProvider: "google", newSubject: taken.subject });
    expect(response.status).toBe(409);
    expect(await errorCode(response)).toBe("identity-in-use");
    expect(await accountRow(reader.accountId)).toMatchObject({ identity_provider: "apple" });
    expect((await signInAs("apple", reader.subject)).account.accountId).toBe(reader.accountId);
    expect((await signInAs("google", taken.subject)).account.accountId).toBe(taken.accountId);
  });

  it("leaves the old sign-in working when the second step fails", async () => {
    const { reader } = await subscribedReader("apple");
    const before = await accountRow(reader.accountId);
    world.outbound.length = 0;
    const googleSubject = newSubject("google");
    const response = await change(reader, { newProvider: "google", newSubject: googleSubject, spoilNew: true });
    expect(await errorCode(response)).toBe("id-token-invalid");
    expect(await accountRow(reader.accountId)).toEqual(before);
    expect(world.outbound).toEqual([]);
    expect((await signInAs("apple", reader.subject)).account.accountId).toBe(reader.accountId);
    expect((await authed(world, reader, "session")).status).toBe(200);
    // The Google identity is still free: it made no account and joined none.
    expect((await signInAs("google", googleSubject)).newAccount).toBe(true);
  });

  it("needs proof from the current sign-in, and Apple's authorization code when leaving Apple", async () => {
    const { reader } = await subscribedReader("apple");
    // A token from another Apple ID.
    expect(await errorCode(await change(reader, { currentSubject: newSubject("apple"), newProvider: "google", newSubject: newSubject("google") }))).toBe("identity-mismatch");
    // A Google token where Apple's is needed.
    expect(await errorCode(await change(reader, { currentProvider: "google", newProvider: "google", newSubject: newSubject("google") }))).toBe("id-token-invalid");
    expect(await errorCode(await change(reader, { newProvider: "google", newSubject: newSubject("google"), currentAuthorizationCode: null }))).toBe("bad-request");
    // To the provider it already has.
    expect(await errorCode(await change(reader, { newProvider: "apple", newSubject: newSubject("apple") }))).toBe("bad-request");
    // Without a session.
    expect(await errorCode(await change({ ...reader, token: "D".repeat(43) }, { newProvider: "google", newSubject: newSubject("google") }))).toBe("session-invalid");
    expect(await accountRow(reader.accountId)).toMatchObject({ identity_provider: "apple" });
  });

  it("still changes when Apple's revocation fails", async () => {
    const { reader } = await subscribedReader("apple");
    world.appleStatus.revoke = 500;
    try {
      const response = await change(reader, { newProvider: "google", newSubject: newSubject("google") });
      expect(response.status).toBe(200);
      expect(await accountRow(reader.accountId)).toMatchObject({ identity_provider: "google" });
    } finally {
      world.appleStatus.revoke = 200;
    }
  });

  it("works without the Sign in with Apple key, skipping revocation", async () => {
    const plain = await makeWorld({ APPLE_SIWA_KEY_ID: "", APPLE_SIWA_PRIVATE_KEY: "" });
    const reader = await signedInReader(plain, "apple");
    const response = await attestedPost(plain, reader.install, "/v1/auth/change", async (challenge) => ({
      deviceSessionToken: reader.token,
      currentIdToken: await idToken(plain, "apple", reader.subject, challenge),
      currentAuthorizationCode: "c-1",
      newProvider: "google",
      newIdToken: await idToken(plain, "google", newSubject("google"), challenge),
    }));
    expect(response.status).toBe(200);
    expect(plain.outbound).toEqual([]);
  });
});
