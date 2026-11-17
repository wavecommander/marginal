// The dev test issuer: HS256 sign-in tokens the `dev` deployment checks itself (README, "The dev
// test issuer"), standing in for Apple or Google in their own identity namespaces.

import { env } from "cloudflare:workers";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { AccountResponse, DeleteAccountResponse, SignInResponse, SignOutResponse } from "../../src/contract";
import type { Provider } from "../../src/identity";
import { devTestClaims, idTokenClaims, nonceOf, signDevTestToken } from "../helpers/oidc";
import { base64 } from "../helpers/pki";
import { DEV_SIGNIN_SECRET } from "../helpers/settings";
import {
  attestedInstall,
  attestedPost,
  call,
  devIdToken,
  errorCode,
  idToken,
  makeWorld,
  newSubject,
  postJson,
  type Install,
  type World,
} from "./harness";

const DEV = { ENVIRONMENT: "dev", R2_S3_HOST: "localhost:8787", APP_APPLE_ID: "" } as const;

let dev: World;
let logged: string[] = [];

beforeAll(async () => {
  dev = await makeWorld({ ...DEV, DEV_TEST_SIGNIN_SECRET: DEV_SIGNIN_SECRET });
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
});

type TokenMaker = (challenge: string) => Promise<string>;

/** A dev token for `subject` in `world`. */
const dev_ = (world: World, subject: string, overrides: Record<string, unknown> = {}, secret?: string): TokenMaker => (challenge) => devIdToken(world, subject, challenge, overrides, secret);
/** A real (generated-key) provider token for `subject` in `world`. */
const real = (world: World, provider: Provider, subject: string): TokenMaker => (challenge) => idToken(world, provider, subject, challenge);

interface Signed {
  install: Install;
  token: string;
  body: SignInResponse;
}

function signIn(world: World, install: Install, provider: Provider, token: TokenMaker): Promise<Response> {
  return attestedPost(world, install, provider === "apple" ? "/v1/auth/apple" : "/v1/auth/google", async (challenge) => ({
    idToken: await token(challenge),
    ...(provider === "apple" ? { authorizationCode: "c-sign-in" } : {}),
  }));
}

async function signedIn(world: World, provider: Provider, token: TokenMaker): Promise<Signed> {
  const install = await attestedInstall(world);
  const response = await signIn(world, install, provider, token);
  if (response.status !== 200) throw new Error(`sign-in: ${response.status} ${await response.text()}`);
  const body = (await response.json()) as SignInResponse;
  return { install, token: body.deviceSessionToken, body };
}

function change(world: World, who: Signed, newProvider: Provider, current: TokenMaker, next: TokenMaker, code: string | null = "c-current"): Promise<Response> {
  return attestedPost(world, who.install, "/v1/auth/change", async (challenge) => ({
    deviceSessionToken: who.token,
    currentIdToken: await current(challenge),
    ...(code === null ? {} : { currentAuthorizationCode: code }),
    newProvider,
    newIdToken: await next(challenge),
  }));
}

function deleteAccount(world: World, who: Signed, proof: TokenMaker | null, code: string | null = "c-delete"): Promise<Response> {
  return attestedPost(world, who.install, "/v1/account/delete", async (challenge) => ({
    deviceSessionToken: who.token,
    ...(proof === null ? {} : { idToken: await proof(challenge) }),
    ...(code === null ? {} : { authorizationCode: code }),
  }));
}

function accountScreen(world: World, who: Signed): Promise<Response> {
  return attestedPost(world, who.install, "/v1/account", { deviceSessionToken: who.token });
}

async function accountRow(accountId: string) {
  return env.DB.prepare("SELECT identity_provider FROM accounts WHERE account_id = ?").bind(accountId).first<{ identity_provider: string }>();
}

describe("the dev test issuer, in dev with DEV_TEST_SIGNIN_SECRET", () => {
  it("signs in as Apple and as Google, each its own account, the same one again next time; logs say dev-test, never the subject", async () => {
    const subject = "dev-tester-shared-subject";
    const apple = await signedIn(dev, "apple", dev_(dev, subject));
    expect(apple.body.newAccount).toBe(true);
    expect(apple.body.account.provider).toBe("apple");
    expect(await accountRow(apple.body.account.accountId)).toEqual({ identity_provider: "apple" });
    const google = await signedIn(dev, "google", dev_(dev, subject));
    expect(google.body.newAccount).toBe(true);
    expect(google.body.account.provider).toBe("google");
    expect(google.body.account.accountId).not.toBe(apple.body.account.accountId);
    const again = await signedIn(dev, "apple", dev_(dev, subject));
    expect(again.body.newAccount).toBe(false);
    expect(again.body.account.accountId).toBe(apple.body.account.accountId);

    const signedInLines = logged.filter((line) => line.includes('"signed-in"'));
    expect(signedInLines.length).toBe(3);
    for (const line of signedInLines) expect(JSON.parse(line)).toMatchObject({ event: "signed-in", issuer: "dev-test" });
    for (const line of logged) {
      expect(line).not.toContain(subject);
      expect(line).not.toContain(DEV_SIGNIN_SECRET);
      expect(line).not.toContain("tester@example.com");
    }

    // Signing out works as for any session.
    const out = await attestedPost(dev, apple.install, "/v1/auth/signout", { deviceSessionToken: apple.token });
    expect(out.status).toBe(200);
    expect(((await out.json()) as SignOutResponse).endedSessions).toBe(1);
    expect(await errorCode(await accountScreen(dev, apple))).toBe("session-invalid");
    expect((await accountScreen(dev, again)).status).toBe(200);
  });

  it("changes Apple to Google with dev tokens; leaving Apple still needs the authorization code", async () => {
    const appleSubject = newSubject("apple");
    const googleSubject = newSubject("google");
    const reader = await signedIn(dev, "apple", dev_(dev, appleSubject));
    expect(await errorCode(await change(dev, reader, "google", dev_(dev, appleSubject), dev_(dev, googleSubject), null))).toBe("bad-request");
    dev.outbound.length = 0;
    const changed = await change(dev, reader, "google", dev_(dev, appleSubject), dev_(dev, googleSubject));
    expect(changed.status).toBe(200);
    expect((await changed.json()) as AccountResponse).toMatchObject({ accountId: reader.body.account.accountId, provider: "google" });
    expect(await accountRow(reader.body.account.accountId)).toEqual({ identity_provider: "google" });
    // Leaving Apple tries to revoke, as for any Apple account (here against the stand-in).
    expect(dev.outbound.map((call) => call.url)).toEqual(["https://appleid.apple.com/auth/token", "https://appleid.apple.com/auth/revoke"]);
    // The dev Google identity now reaches the account; the dev Apple one makes a new account.
    expect((await signedIn(dev, "google", dev_(dev, googleSubject))).body.account.accountId).toBe(reader.body.account.accountId);
    expect((await signedIn(dev, "apple", dev_(dev, appleSubject))).body.newAccount).toBe(true);
  });

  it("deletes an account with a dev token as proof", async () => {
    const subject = newSubject("google");
    const reader = await signedIn(dev, "google", dev_(dev, subject));
    const first = await deleteAccount(dev, reader, dev_(dev, subject), null);
    expect(first.status).toBe(200);
    expect(((await first.json()) as DeleteAccountResponse).done).toBe(true);
    expect(await accountRow(reader.body.account.accountId)).toBeNull();
    // The same dev identity signs in again to a new, empty account.
    const again = await signedIn(dev, "google", dev_(dev, subject));
    expect(again.body.newAccount).toBe(true);
    expect(again.body.account.accountId).not.toBe(reader.body.account.accountId);
  });

  it("works without GOOGLE_CLIENT_IDS for Google; a real Google token is then still provider-disabled", async () => {
    const noGoogle = await makeWorld({ ...DEV, GOOGLE_CLIENT_IDS: "", DEV_TEST_SIGNIN_SECRET: DEV_SIGNIN_SECRET });
    const subject = newSubject("google");
    expect((await signedIn(noGoogle, "google", dev_(noGoogle, subject))).body.account.provider).toBe("google");
    const install = await attestedInstall(noGoogle);
    expect(await errorCode(await signIn(noGoogle, install, "google", real(noGoogle, "google", subject)))).toBe("provider-disabled");
  });

  it("refuses a wrong secret, audience, nonce, issuer, an expired token and too long a life", async () => {
    const install = await attestedInstall(dev);
    const subject = newSubject("apple");
    const iat = Math.floor(dev.clock.now.getTime() / 1000);
    const bad: TokenMaker[] = [
      dev_(dev, subject, {}, `${DEV_SIGNIN_SECRET}-wrong`),
      dev_(dev, subject, { aud: "com.example.other" }),
      dev_(dev, subject, { nonce: await nonceOf(base64(new Uint8Array(32))) }),
      dev_(dev, subject, { iss: "https://appleid.apple.com" }),
      dev_(dev, subject, { iat: iat - 900, exp: iat - 300 }),
      dev_(dev, subject, { exp: iat + 3600 }),
    ];
    for (const token of bad) {
      expect(await errorCode(await signIn(dev, install, "apple", token))).toBe("id-token-invalid");
    }
    // An HS256 token shaped exactly like Apple's (issuer, claims), keyed with the dev secret.
    const appleShaped: TokenMaker = async (challenge) => signDevTestToken(idTokenClaims("apple", subject, await nonceOf(challenge), dev.clock.now), DEV_SIGNIN_SECRET);
    expect(await errorCode(await signIn(dev, install, "apple", appleShaped))).toBe("id-token-invalid");
    const googleShaped: TokenMaker = async (challenge) => signDevTestToken(idTokenClaims("google", subject, await nonceOf(challenge), dev.clock.now), DEV_SIGNIN_SECRET);
    expect(await errorCode(await signIn(dev, install, "google", googleShaped))).toBe("id-token-invalid");
  });
});

describe("the dev test issuer cannot reach a real identity's account", () => {
  it("the same subject from Apple and from the dev issuer are two accounts, neither able to prove, change or delete the other", async () => {
    const subject = newSubject("apple");
    const realApple = await signedIn(dev, "apple", real(dev, "apple", subject));
    const devApple = await signedIn(dev, "apple", dev_(dev, subject));
    expect(devApple.body.newAccount).toBe(true);
    expect(devApple.body.account.accountId).not.toBe(realApple.body.account.accountId);

    // A dev token as proof for the real account, and a real token as proof for the dev one.
    expect(await errorCode(await deleteAccount(dev, realApple, dev_(dev, subject)))).toBe("identity-mismatch");
    expect(await errorCode(await change(dev, realApple, "google", dev_(dev, subject), dev_(dev, newSubject("google"))))).toBe("identity-mismatch");
    expect(await errorCode(await deleteAccount(dev, devApple, real(dev, "apple", subject)))).toBe("identity-mismatch");
    expect(await errorCode(await change(dev, devApple, "google", real(dev, "apple", subject), dev_(dev, newSubject("google"))))).toBe("identity-mismatch");
    // Both accounts are untouched.
    expect((await accountScreen(dev, realApple)).status).toBe(200);
    expect((await accountScreen(dev, devApple)).status).toBe(200);
    expect((await signedIn(dev, "apple", real(dev, "apple", subject))).body.account.accountId).toBe(realApple.body.account.accountId);
  });

  it("changing to a dev Google identity with a real Google user's subject neither collides with nor takes over that account", async () => {
    const googleSubject = newSubject("google");
    const realGoogle = await signedIn(dev, "google", real(dev, "google", googleSubject));
    const devSubject = newSubject("apple");
    const devApple = await signedIn(dev, "apple", dev_(dev, devSubject));
    const changed = await change(dev, devApple, "google", dev_(dev, devSubject), dev_(dev, googleSubject));
    expect(changed.status).toBe(200);
    expect((await signedIn(dev, "google", real(dev, "google", googleSubject))).body.account.accountId).toBe(realGoogle.body.account.accountId);
    expect((await signedIn(dev, "google", dev_(dev, googleSubject))).body.account.accountId).toBe(devApple.body.account.accountId);
  });

  it("Sign in with Apple notifications never take a dev token", async () => {
    const subject = newSubject("apple");
    const devApple = await signedIn(dev, "apple", dev_(dev, subject));
    const iat = Math.floor(dev.clock.now.getTime() / 1000);
    const events = JSON.stringify({ type: "consent-revoked", sub: subject, event_time: iat });
    for (const claims of [devTestClaims(subject, "", dev.clock.now, { events }), devTestClaims(subject, "", dev.clock.now, { iss: "https://appleid.apple.com", events })]) {
      const response = await postJson(dev, "/v1/apple/signin-notifications", { payload: await signDevTestToken(claims, DEV_SIGNIN_SECRET) });
      expect(response.status).toBe(401);
      expect(await errorCode(response)).toBe("notification-invalid");
    }
    expect((await accountScreen(dev, devApple)).status).toBe(200);
  });
});

describe("the dev test issuer off", () => {
  it("in dev without the secret: a dev token is id-token-invalid", async () => {
    const off = await makeWorld({ ...DEV });
    const install = await attestedInstall(off);
    for (const provider of ["apple", "google"] as const) {
      expect(await errorCode(await signIn(off, install, provider, dev_(off, newSubject(provider))))).toBe("id-token-invalid");
    }
  });

  it("in production: a dev token is id-token-invalid, and the secret's mere presence stops the Worker", async () => {
    const production = await makeWorld();
    const install = await attestedInstall(production);
    for (const provider of ["apple", "google"] as const) {
      expect(await errorCode(await signIn(production, install, provider, dev_(production, newSubject(provider))))).toBe("id-token-invalid");
    }
    for (const value of [DEV_SIGNIN_SECRET, ""]) {
      const misconfigured = await makeWorld({ DEV_TEST_SIGNIN_SECRET: value });
      for (const path of ["/v1/challenge", "/v1/auth/apple"]) {
        const response = await postJson(misconfigured, path, { action: "auth-apple", challenge: base64(new Uint8Array(32)), idToken: "x" });
        expect(response.status).toBe(500);
        expect(await errorCode(response)).toBe("internal");
      }
      const health = await call(misconfigured, "/v1/health");
      expect(health.status).toBe(500);
      expect(logged.some((line) => line.includes("DEV_TEST_SIGNIN_SECRET"))).toBe(true);
      for (const line of logged) expect(line).not.toContain(DEV_SIGNIN_SECRET);
    }
  });
});
