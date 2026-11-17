import { env } from "cloudflare:workers";
import { beforeAll, describe, expect, it } from "vitest";
import type { AccountResponse, SignInResponse } from "../../src/contract";
import { idTokenClaims, nonceOf, rsaSigningKey, signRs256 } from "../helpers/oidc";
import {
  attestedInstall,
  attestedPost,
  authed,
  errorCode,
  idToken,
  makeWorld,
  newChallenge,
  newSubject,
  signInRequest,
  signedInReader,
  type Install,
  type World,
} from "./harness";

let world: World;
let install: Install;

beforeAll(async () => {
  world = await makeWorld();
  install = await attestedInstall(world);
});

async function signedIn(response: Response): Promise<SignInResponse> {
  if (response.status !== 200) throw new Error(`${response.status} ${await response.text()}`);
  return response.json();
}

/** Signs in with a token built from custom claims (and optionally another key). */
function signInWithClaims(provider: "apple" | "google", subject: string, overrides: Record<string, unknown>, key = world.signingKeys[provider]): Promise<Response> {
  return attestedPost(world, install, provider === "apple" ? "/v1/auth/apple" : "/v1/auth/google", async (challenge) => ({
    idToken: await signRs256(idTokenClaims(provider, subject, await nonceOf(challenge), world.clock.now, overrides), key),
  }));
}

describe("signing in", () => {
  it("creates the account on the first sign-in and returns a device session, its token and the account", async () => {
    const subject = newSubject("apple");
    const body = await signedIn(await signInRequest(world, install, "apple", subject, { deviceLabel: "ZW5jcnlwdGVk" }));
    expect(body.newAccount).toBe(true);
    expect(body.deviceSessionToken).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(body.sessionId).toMatch(/^[0-9a-f]{32}$/);
    const account: AccountResponse = body.account;
    expect(account).toEqual({
      accountId: expect.stringMatching(/^[0-9a-f]{32}$/),
      provider: "apple",
      appAccountToken: expect.stringMatching(/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/),
      createdAt: "2026-11-15T12:00:00.000Z",
      devices: [{ sessionId: body.sessionId, createdAt: "2026-11-15T12:00:00.000Z", lastUsedAt: "2026-11-15T12:00:00.000Z", label: "ZW5jcnlwdGVk", current: true }],
      subscription: null,
      usage: null,
    });
    // Nothing that names the person is stored: no subject, no email, no token.
    const rows = JSON.stringify([
      await env.DB.prepare("SELECT * FROM accounts WHERE account_id = ?").bind(account.accountId).all(),
      await env.DB.prepare("SELECT * FROM device_sessions WHERE account_id = ?").bind(account.accountId).all(),
    ]);
    expect(rows).not.toContain(subject);
    expect(rows).not.toContain("privaterelay");
    expect(rows).not.toContain(body.deviceSessionToken);
  });

  it("signs the same identity in to the same account, with a new session each time", async () => {
    const subject = newSubject("google");
    const first = await signedIn(await signInRequest(world, install, "google", subject));
    const second = await signedIn(await signInRequest(world, await attestedInstall(world), "google", subject));
    expect(second.newAccount).toBe(false);
    expect(second.account.accountId).toBe(first.account.accountId);
    expect(second.account.appAccountToken).toBe(first.account.appAccountToken);
    expect(second.deviceSessionToken).not.toBe(first.deviceSessionToken);
    expect(second.account.devices.map((d) => [d.sessionId, d.current])).toEqual([
      [first.sessionId, false],
      [second.sessionId, true],
    ]);
  });

  it("keeps Apple and Google identities apart, even with the same subject", async () => {
    const subject = "1234567890";
    const apple = await signedIn(await signInRequest(world, install, "apple", subject));
    const google = await signedIn(await signInRequest(world, install, "google", subject));
    expect(google.account.accountId).not.toBe(apple.account.accountId);
    expect(google.account.provider).toBe("google");
  });

  it("makes one account when the same new identity signs in twice at once", async () => {
    const subject = newSubject("apple");
    const [a, b] = await Promise.all([signInRequest(world, await attestedInstall(world), "apple", subject), signInRequest(world, await attestedInstall(world), "apple", subject)]);
    const [bodyA, bodyB] = [await signedIn(a), await signedIn(b)];
    expect(bodyA.account.accountId).toBe(bodyB.account.accountId);
    expect([bodyA.newAccount, bodyB.newAccount].sort()).toEqual([false, true]);
  });

  it("accepts a token signed with a key Apple has just rotated in, after fetching the set again once", async () => {
    const rotated = await rsaSigningKey();
    world.jwks.pending.apple.push(rotated.jwk);
    const before = world.jwks.refreshes;
    const body = await signedIn(await signInWithClaims("apple", newSubject("apple"), {}, rotated));
    expect(body.newAccount).toBe(true);
    expect(world.jwks.refreshes).toBe(before + 1);
  });
});

describe("refused sign-ins", () => {
  const iat = () => Math.floor(world.clock.now.getTime() / 1000);

  it("wrong audience, issuer, expired, issued in the future", async () => {
    const cases: ["apple" | "google", Record<string, unknown>][] = [
      ["apple", { aud: "com.example.other" }],
      ["google", { aud: "999-other.apps.googleusercontent.com", azp: "999-other.apps.googleusercontent.com" }],
      ["apple", { iss: "https://accounts.google.com" }],
      ["google", { iss: "https://appleid.apple.com" }],
      ["apple", { exp: iat() - 120 }],
      ["google", { exp: iat() - 120 }],
      ["apple", { iat: iat() + 600 }],
    ];
    for (const [provider, overrides] of cases) {
      const response = await signInWithClaims(provider, newSubject(provider), overrides);
      expect(response.status).toBe(401);
      expect(await errorCode(response)).toBe("id-token-invalid");
    }
  });

  it("a nonce that is not this request's challenge", async () => {
    const other = await newChallenge(world);
    const response = await signInWithClaims("apple", newSubject("apple"), { nonce: await nonceOf(other) });
    expect(await errorCode(response)).toBe("id-token-invalid");
    // The raw challenge instead of its hash.
    const raw = await attestedPost(world, install, "/v1/auth/apple", async (challenge) => ({
      idToken: await signRs256(idTokenClaims("apple", newSubject("apple"), challenge, world.clock.now), world.signingKeys.apple),
    }));
    expect(await errorCode(raw)).toBe("id-token-invalid");
  });

  it("a bad signature, a forged key under a real key ID, an unknown key ID", async () => {
    // Another token's signature on this one's header and claims.
    const other = await idToken(world, "apple", newSubject("apple"), await newChallenge(world));
    const badSignature = await attestedPost(world, install, "/v1/auth/apple", async (challenge) => {
      const real = await idToken(world, "apple", newSubject("apple"), challenge);
      return { idToken: `${real.split(".").slice(0, 2).join(".")}.${other.split(".")[2]}` };
    });
    expect(await errorCode(badSignature)).toBe("id-token-invalid");
    const forger = await rsaSigningKey({ kid: world.signingKeys.apple.kid });
    expect(await errorCode(await signInWithClaims("apple", newSubject("apple"), {}, forger))).toBe("id-token-invalid");
    const before = world.jwks.refreshes;
    const stranger = await rsaSigningKey();
    expect(await errorCode(await signInWithClaims("apple", newSubject("apple"), {}, stranger))).toBe("id-token-invalid");
    expect(world.jwks.refreshes).toBe(before + 1);
    // Google's key for an Apple sign-in.
    expect(await errorCode(await signInWithClaims("apple", newSubject("apple"), {}, world.signingKeys.google))).toBe("id-token-invalid");
  });

  it("a replayed challenge, and a replayed ID token with a new challenge", async () => {
    const subject = newSubject("apple");
    const challenge = await newChallenge(world);
    const token = await idToken(world, "apple", subject, challenge);
    expect((await attestedPost(world, install, "/v1/auth/apple", { idToken: token }, { challenge })).status).toBe(200);
    const replay = await attestedPost(world, install, "/v1/auth/apple", { idToken: token }, { challenge });
    expect(replay.status).toBe(401);
    expect(await errorCode(replay)).toBe("challenge-invalid");
    expect(await errorCode(await attestedPost(world, install, "/v1/auth/apple", { idToken: token }))).toBe("id-token-invalid");
  });

  it("without App Attest", async () => {
    expect(await errorCode(await signInRequest(world, null, "apple", newSubject("apple")))).toBe("assertion-invalid");
  });

  it("Google when it is not configured; either when the keys cannot be fetched", async () => {
    const off = await makeWorld({ GOOGLE_CLIENT_IDS: "" });
    const offInstall = await attestedInstall(off);
    const challenge = await newChallenge(off);
    const response = await signInRequest(off, offInstall, "google", newSubject("google"), {}, { challenge });
    expect(response.status).toBe(403);
    expect(await errorCode(response)).toBe("provider-disabled");
    // Refused before the challenge was spent.
    expect((await signInRequest(off, offInstall, "apple", newSubject("apple"), {}, { challenge })).status).toBe(200);

    world.jwks.unavailable = true;
    try {
      const unreachable = await signInRequest(world, install, "apple", newSubject("apple"));
      expect(unreachable.status).toBe(503);
      expect(await errorCode(unreachable)).toBe("provider-unreachable");
    } finally {
      world.jwks.unavailable = false;
    }
  });

  it("a malformed device label", async () => {
    expect(await errorCode(await signInRequest(world, install, "apple", newSubject("apple"), { deviceLabel: "not base64!" }))).toBe("bad-request");
    expect(await errorCode(await signInRequest(world, install, "apple", newSubject("apple"), { deviceLabel: "A".repeat(1028) }))).toBe("bad-request");
  });
});

describe("one identity per account", () => {
  it("the database cannot hold two accounts for one identity, or an account without one", async () => {
    const reader = await signedInReader(world, "google");
    const row = await env.DB.prepare("SELECT * FROM accounts WHERE account_id = ?").bind(reader.accountId).first<Record<string, unknown>>();
    expect(row).toMatchObject({ identity_provider: "google", identity_hash: expect.stringMatching(/^[0-9a-f]{64}$/) });
    const insert = (id: string, hash: unknown, provider: unknown) =>
      env.DB.prepare(
        "INSERT INTO accounts (account_id, folder_key, identity_provider, identity_hash, app_account_token, created_at, identity_changed_at) VALUES (?, ?, ?, ?, ?, 0, 0)",
      )
        .bind(id, id.padEnd(64, "0"), provider, hash, crypto.randomUUID())
        .run();
    await expect(insert("f".repeat(32), row!.identity_hash, "google")).rejects.toThrow(/UNIQUE/);
    await expect(insert("e".repeat(32), null, "apple")).rejects.toThrow(/NOT NULL/);
    await expect(insert("d".repeat(32), "ab".repeat(32), "facebook")).rejects.toThrow(/CHECK/);
  });
});

describe("a session made through a sign-in", () => {
  it("works only with the device session token it returned", async () => {
    const reader = await signedInReader(world);
    expect(await errorCode(await authed(world, reader, "session"))).toBe("not-subscribed");
    expect(await errorCode(await authed(world, reader, "session", { token: "C".repeat(43) }))).toBe("session-invalid");
  });
});
