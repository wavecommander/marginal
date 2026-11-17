import { beforeAll, describe, expect, it } from "vitest";
import { readSettings } from "../../src/env";
import { Refusal } from "../../src/http";
import { DEV_TEST_ISSUER, JWKS_URLS, JwksCache, cacheLifetime, verifyAppleSignInNotification, verifyIdToken, type Jwk } from "../../src/idToken";
import { GOOGLE_CLIENT_ID, OTHER_GOOGLE_CLIENT_ID, TestJwks, devTestClaims, idTokenClaims, rsaSigningKey, signDevTestToken, signRs256, type SigningKey } from "../helpers/oidc";
import { BUNDLE_ID, DEV_SIGNIN_SECRET, testEnv } from "../helpers/settings";

const NOW = new Date("2026-11-15T12:00:00Z");
const NONCE = "ab".repeat(32);
const settings = readSettings(testEnv());
let apple: SigningKey;
let google: SigningKey;
let jwks: TestJwks;

beforeAll(async () => {
  apple = await rsaSigningKey();
  google = await rsaSigningKey();
});

function fresh(): TestJwks {
  jwks = new TestJwks();
  jwks.visible.apple.push(apple.jwk);
  jwks.visible.google.push(google.jwk);
  return jwks;
}

async function verify(token: string, provider: "apple" | "google" = "apple", nonce = NONCE, theSettings = settings) {
  return verifyIdToken(token, provider, nonce, theSettings, { jwks: jwks ?? fresh(), now: NOW });
}

async function refusal(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (error) {
    if (error instanceof Refusal) return `${error.code}: ${error.detail}`;
    throw error;
  }
  throw new Error("expected a refusal");
}

describe("verifyIdToken", () => {
  it("accepts Apple's and Google's tokens and returns only the subject", async () => {
    fresh();
    expect(await verify(await signRs256(idTokenClaims("apple", "001.abc.002", NONCE, NOW), apple))).toEqual({ provider: "apple", namespace: "apple", issuer: "provider", subject: "001.abc.002" });
    expect(await verify(await signRs256(idTokenClaims("google", "1170001", NONCE, NOW), google), "google")).toEqual({ provider: "google", namespace: "google", issuer: "provider", subject: "1170001" });
    // Both of Google's issuer spellings, and an audience given as a one-element list.
    expect(await verify(await signRs256(idTokenClaims("google", "1170001", NONCE, NOW, { iss: "accounts.google.com", aud: [GOOGLE_CLIENT_ID] }), google), "google")).toMatchObject({ subject: "1170001" });
  });

  it("refuses the wrong audience, issuer, nonce, expiry, issue time, subject or authorized party", async () => {
    fresh();
    const iat = Math.floor(NOW.getTime() / 1000);
    const cases: [Parameters<typeof idTokenClaims>[0], Record<string, unknown>, RegExp][] = [
      ["apple", { aud: "com.example.other" }, /audience/],
      ["apple", { aud: ["software.tactile.texts", "x"] }, /audience/],
      ["google", { aud: OTHER_GOOGLE_CLIENT_ID, azp: OTHER_GOOGLE_CLIENT_ID }, /audience/],
      ["google", { azp: OTHER_GOOGLE_CLIENT_ID }, /authorized party/],
      ["apple", { iss: "https://accounts.google.com" }, /issuer/],
      ["google", { iss: "https://appleid.apple.com" }, /issuer/],
      ["apple", { nonce: "cd".repeat(32) }, /nonce/],
      ["apple", { nonce: undefined }, /nonce/],
      ["apple", { exp: iat - 61 }, /expired/],
      ["apple", { exp: undefined }, /expiry/],
      ["apple", { iat: iat + 120 }, /future/],
      ["apple", { sub: "" }, /subject/],
      ["apple", { sub: 42 }, /subject/],
    ];
    for (const [provider, overrides, pattern] of cases) {
      const token = await signRs256(idTokenClaims(provider, "s-1", NONCE, NOW, overrides), provider === "apple" ? apple : google);
      expect(await refusal(verify(token, provider))).toMatch(new RegExp(`^id-token-invalid: .*${pattern.source}`));
    }
    // Within a minute's skew either way is accepted.
    expect(await verify(await signRs256(idTokenClaims("apple", "s-1", NONCE, NOW, { exp: iat - 59, iat: iat + 59 }), apple))).toMatchObject({ subject: "s-1" });
  });

  it("refuses a bad signature, another provider's key, an unknown key and other algorithms", async () => {
    fresh();
    const good = await signRs256(idTokenClaims("apple", "s-1", NONCE, NOW), apple);
    const [h, p, s] = good.split(".") as [string, string, string];
    const tampered = `${h}.${p.slice(0, -2)}${p.slice(-2) === "AA" ? "BB" : "AA"}.${s}`;
    expect(await refusal(verify(tampered))).toMatch(/^id-token-invalid/);
    expect(await refusal(verify(`${h}.${p}.${s.slice(0, -4)}AAAA`))).toMatch(/bad signature/);
    // Signed with Google's key but claiming Apple's: the kid is not in Apple's set.
    expect(await refusal(verify(await signRs256(idTokenClaims("apple", "s-1", NONCE, NOW), google)))).toMatch(/unknown key/);
    // A stranger's key under Apple's kid.
    const stranger = await rsaSigningKey({ kid: apple.kid });
    expect(await refusal(verify(await signRs256(idTokenClaims("apple", "s-1", NONCE, NOW), stranger)))).toMatch(/bad signature/);
    expect(await refusal(verify(await signRs256(idTokenClaims("apple", "s-1", NONCE, NOW), apple, { alg: "HS256" })))).toMatch(/algorithm/);
    expect(await refusal(verify(await signRs256(idTokenClaims("apple", "s-1", NONCE, NOW), apple, { alg: "none" })))).toMatch(/algorithm/);
    expect(await refusal(verify(await signRs256(idTokenClaims("apple", "s-1", NONCE, NOW), apple, { crit: ["x"] })))).toMatch(/critical/);
    expect(await refusal(verify("a.b"))).toMatch(/compact/);
    expect(await refusal(verify("x".repeat(9000)))).toMatch(/too long/);
  });

  it("asks for the key set again, once, when a token names an unknown key", async () => {
    fresh();
    const rotated = await rsaSigningKey();
    jwks.pending.apple.push(rotated.jwk);
    expect(await verify(await signRs256(idTokenClaims("apple", "s-1", NONCE, NOW), rotated))).toMatchObject({ subject: "s-1" });
    expect(jwks.refreshes).toBe(1);
    // A key that never appears: one refresh, then refused.
    const never = await rsaSigningKey();
    expect(await refusal(verify(await signRs256(idTokenClaims("apple", "s-1", NONCE, NOW), never)))).toMatch(/unknown key/);
    expect(jwks.refreshes).toBe(2);
  });

  it("refuses keys that are short, not RSA, or for something else", async () => {
    fresh();
    const short = await rsaSigningKey({ modulusLength: 1024 });
    jwks.visible.apple.push(short.jwk);
    expect(await refusal(verify(await signRs256(idTokenClaims("apple", "s-1", NONCE, NOW), short)))).toMatch(/too short/);
    const encryption = await rsaSigningKey();
    jwks.visible.apple.push({ ...encryption.jwk, use: "enc" });
    expect(await refusal(verify(await signRs256(idTokenClaims("apple", "s-1", NONCE, NOW), encryption)))).toMatch(/not for signing/);
    const ec: Jwk = { kty: "EC", kid: "ec-1" };
    jwks.visible.apple.push(ec);
    expect(await refusal(verify(await signRs256(idTokenClaims("apple", "s-1", NONCE, NOW), { ...apple, kid: "ec-1" })))).toMatch(/not RSA/);
  });

  it("refuses Google when no client ID is configured, and says when the keys cannot be had", async () => {
    fresh();
    const token = await signRs256(idTokenClaims("google", "s-1", NONCE, NOW), google);
    expect(await refusal(verify(token, "google", NONCE, readSettings(testEnv({ GOOGLE_CLIENT_IDS: "" }))))).toMatch(/^provider-disabled/);
    jwks.unavailable = true;
    expect(await refusal(verify(token, "google"))).toMatch(/^provider-unreachable/);
  });
});

describe("the dev test issuer", () => {
  const devSettings = readSettings(testEnv({ ENVIRONMENT: "dev", R2_S3_HOST: "localhost:8787", APP_APPLE_ID: "", DEV_TEST_SIGNIN_SECRET: DEV_SIGNIN_SECRET }));
  const devOff = readSettings(testEnv({ ENVIRONMENT: "dev", R2_S3_HOST: "localhost:8787", APP_APPLE_ID: "" }));
  const devToken = (overrides: Record<string, unknown> = {}, secret = DEV_SIGNIN_SECRET, header: Record<string, unknown> = {}) =>
    signDevTestToken(devTestClaims("tester-1", NONCE, NOW, overrides), secret, header);

  it("stands in for Apple and Google in dev with the secret, in each provider's dev-test namespace", async () => {
    fresh();
    expect(DEV_TEST_ISSUER).toBe("tactile-texts-dev-test");
    const token = await devToken();
    expect(await verify(token, "apple", NONCE, devSettings)).toEqual({ provider: "apple", namespace: "dev-test:apple", issuer: "dev-test", subject: "tester-1" });
    // No Google client IDs needed: the audience is the bundle ID for either.
    const noGoogle = readSettings(testEnv({ ENVIRONMENT: "dev", R2_S3_HOST: "localhost:8787", APP_APPLE_ID: "", GOOGLE_CLIENT_IDS: "", DEV_TEST_SIGNIN_SECRET: DEV_SIGNIN_SECRET }));
    expect(await verify(token, "google", NONCE, noGoogle)).toEqual({ provider: "google", namespace: "dev-test:google", issuer: "dev-test", subject: "tester-1" });
    // An audience given as a one-element list, no `typ`, no email, and a minute's skew.
    const iat = Math.floor(NOW.getTime() / 1000);
    expect(await verify(await devToken({ aud: [BUNDLE_ID], email: undefined, iat: iat + 59, exp: iat + 59 + 600 }, DEV_SIGNIN_SECRET, { typ: undefined }), "apple", NONCE, devSettings)).toMatchObject({ subject: "tester-1" });
    expect(await verify(await devToken({ iat: iat - 600, exp: iat - 59 }), "apple", NONCE, devSettings)).toMatchObject({ subject: "tester-1" });
  });

  it("is refused in production, even with settings that somehow carry the secret, and in dev without the secret", async () => {
    fresh();
    const token = await devToken();
    expect(await refusal(verify(token, "apple"))).toMatch(/^id-token-invalid: jwt: algorithm is not RS256/);
    const forced = { ...devSettings, environment: "production" as const };
    expect(await refusal(verify(token, "apple", NONCE, forced))).toMatch(/^id-token-invalid: jwt: algorithm is not RS256/);
    expect(await refusal(verify(token, "google", NONCE, forced))).toMatch(/^id-token-invalid/);
    expect(await refusal(verify(token, "apple", NONCE, devOff))).toMatch(/^id-token-invalid: jwt: algorithm is not RS256/);
  });

  it("refuses a wrong secret, issuer, audience, nonce, expiry, issue time, lifetime, subject or header", async () => {
    fresh();
    const iat = Math.floor(NOW.getTime() / 1000);
    const cases: [Promise<string>, RegExp][] = [
      [devToken({}, `${DEV_SIGNIN_SECRET}x`), /bad signature/],
      [devToken({ iss: "https://appleid.apple.com" }), /issuer/],
      [devToken({ iss: "https://accounts.google.com" }), /issuer/],
      [devToken({ iss: undefined }), /issuer/],
      [devToken({ aud: "com.example.other" }), /audience/],
      [devToken({ aud: GOOGLE_CLIENT_ID }), /audience/],
      [devToken({ aud: [BUNDLE_ID, "x"] }), /audience/],
      [devToken({ nonce: "cd".repeat(32) }), /nonce/],
      [devToken({ nonce: undefined }), /nonce/],
      [devToken({ iat: iat - 661, exp: iat - 61 }), /expired/],
      [devToken({ exp: undefined }), /expiry/],
      [devToken({ iat: undefined }), /issue time/],
      [devToken({ iat: iat + 120, exp: iat + 600 }), /future/],
      [devToken({ exp: iat + 601 }), /lifetime/],
      [devToken({ exp: iat }), /lifetime/],
      [devToken({ sub: "" }), /subject/],
      [devToken({ sub: "x".repeat(256) }), /subject/],
      [devToken({ sub: "a\0b" }), /subject/],
      [devToken({}, DEV_SIGNIN_SECRET, { typ: "JOSE+JSON" }), /type/],
      [devToken({}, DEV_SIGNIN_SECRET, { crit: ["x"] }), /critical/],
    ];
    for (const [token, pattern] of cases) {
      expect(await refusal(verify(await token, "apple", NONCE, devSettings))).toMatch(new RegExp(`^id-token-invalid: .*${pattern.source}`));
    }
    // A tampered payload under a good signature.
    const [h, , s] = (await devToken()).split(".") as [string, string, string];
    const other = (await devToken({ sub: "tester-2" })).split(".")[1]!;
    expect(await refusal(verify(`${h}.${other}.${s}`, "apple", NONCE, devSettings))).toMatch(/bad signature/);
  });

  it("never lets HS256 through the real providers' path (no algorithm confusion)", async () => {
    fresh();
    // An HS256 token claiming Apple's issuer, keyed with the dev secret: refused in dev too.
    const asApple = await signDevTestToken(idTokenClaims("apple", "001.abc.002", NONCE, NOW), DEV_SIGNIN_SECRET);
    expect(await refusal(verify(asApple, "apple", NONCE, devSettings))).toMatch(/^id-token-invalid: dev-test jwt: issuer/);
    const asGoogle = await signDevTestToken(idTokenClaims("google", "1170001", NONCE, NOW), DEV_SIGNIN_SECRET);
    expect(await refusal(verify(asGoogle, "google", NONCE, devSettings))).toMatch(/^id-token-invalid/);
    // Keyed with Apple's public key material (the classic confusion): refused everywhere.
    const confused = await signDevTestToken(idTokenClaims("apple", "001.abc.002", NONCE, NOW), String(apple.jwk.n), { kid: apple.kid });
    expect(await refusal(verify(confused, "apple"))).toMatch(/^id-token-invalid/);
    expect(await refusal(verify(confused, "apple", NONCE, devSettings))).toMatch(/^id-token-invalid/);
    // RS256 with the dev issuer: the RS256 path's issuer check refuses it.
    expect(await refusal(verify(await signRs256(devTestClaims("tester-1", NONCE, NOW), apple), "apple", NONCE, devSettings))).toMatch(/^id-token-invalid: jwt: issuer/);
  });

  it("is never a Sign in with Apple notification", async () => {
    fresh();
    const iat = Math.floor(NOW.getTime() / 1000);
    const claims = devTestClaims("tester-1", NONCE, NOW, { iss: "https://appleid.apple.com", events: JSON.stringify({ type: "consent-revoked", sub: "tester-1", event_time: iat }) });
    expect(await refusal(verifyAppleSignInNotification(await signDevTestToken(claims, DEV_SIGNIN_SECRET), devSettings, { jwks, now: NOW }))).toMatch(/^notification-invalid: jwt: algorithm/);
    const ownIssuer = devTestClaims("tester-1", NONCE, NOW, { events: JSON.stringify({ type: "consent-revoked", sub: "tester-1", event_time: iat }) });
    expect(await refusal(verifyAppleSignInNotification(await signDevTestToken(ownIssuer, DEV_SIGNIN_SECRET), devSettings, { jwks, now: NOW }))).toMatch(/^notification-invalid/);
  });
});

describe("JwksCache", () => {
  function server() {
    const calls: string[] = [];
    let keys: Jwk[] = [];
    let cacheControl: string | null = "public, max-age=21600";
    let fail = false;
    const fetcher = async (url: string): Promise<Response> => {
      calls.push(url);
      if (fail) throw new Error("network down");
      return new Response(JSON.stringify({ keys }), { status: 200, headers: cacheControl ? { "cache-control": cacheControl } : {} });
    };
    return {
      calls,
      fetcher,
      set: (next: Jwk[]) => (keys = next),
      cacheControl: (value: string | null) => (cacheControl = value),
      fail: (value: boolean) => (fail = value),
    };
  }

  it("fetches only the fixed addresses and keeps the set for its max-age", async () => {
    const s = server();
    s.set([apple.jwk]);
    let now = NOW.getTime();
    const cache = new JwksCache(s.fetcher, () => now);
    expect(await cache.keys("apple", false)).toEqual([apple.jwk]);
    expect(await cache.keys("apple", false)).toEqual([apple.jwk]);
    expect(s.calls).toEqual([JWKS_URLS.apple]);
    now += 6 * 3600_000 - 1;
    await cache.keys("apple", false);
    expect(s.calls.length).toBe(1);
    now += 1;
    await cache.keys("apple", false);
    expect(s.calls.length).toBe(2);
    await cache.keys("google", false);
    expect(s.calls).toEqual([JWKS_URLS.apple, JWKS_URLS.apple, JWKS_URLS.google]);
    expect(JWKS_URLS).toEqual({ apple: "https://appleid.apple.com/auth/keys", google: "https://www.googleapis.com/oauth2/v3/certs" });
  });

  it("refetches for an unknown key at most once a minute", async () => {
    const s = server();
    s.set([apple.jwk]);
    let now = NOW.getTime();
    const cache = new JwksCache(s.fetcher, () => now);
    await cache.keys("apple", false);
    await cache.keys("apple", true); // within the cooldown: the cached set
    expect(s.calls.length).toBe(1);
    now += 60_000;
    s.set([apple.jwk, google.jwk]);
    expect(await cache.keys("apple", true)).toEqual([apple.jwk, google.jwk]);
    expect(s.calls.length).toBe(2);
  });

  it("keeps a set it cannot refresh for a day past its expiry, then gives up", async () => {
    const s = server();
    s.set([apple.jwk]);
    s.cacheControl(null); // default: an hour
    let now = NOW.getTime();
    const cache = new JwksCache(s.fetcher, () => now);
    await cache.keys("apple", false);
    s.fail(true);
    now += 3600_000 + 24 * 3600_000 - 1;
    expect(await cache.keys("apple", false)).toEqual([apple.jwk]);
    now += 1;
    await expect(cache.keys("apple", false)).rejects.toThrow(/unavailable/);
    await expect(new JwksCache(s.fetcher, () => now).keys("google", false)).rejects.toThrow(/unavailable/);
  });

  it("after a failed fetch, fetches again at most once a minute, failing fast or serving stale keys meanwhile", async () => {
    const s = server();
    s.fail(true);
    let now = NOW.getTime();
    const cache = new JwksCache(s.fetcher, () => now);
    // No keys at all: one fetch, then immediate failures until the minute is up.
    for (let i = 0; i < 20; i++) {
      await expect(cache.keys("apple", i % 2 === 0)).rejects.toThrow(/unavailable/);
      now += 1000;
    }
    expect(s.calls.length).toBe(1);
    for (let i = 0; i < 50; i++) {
      await expect(cache.keys("apple", false)).rejects.toThrow(/unavailable/);
      now += 1000;
    }
    // 70 seconds of lookups: one fetch at the start, one when the first minute ended.
    expect(s.calls.length).toBe(2);
    // With an expired set: stale keys while the fetch keeps failing, one fetch a minute.
    s.fail(false);
    s.set([apple.jwk]);
    s.cacheControl(null);
    now += 60_000;
    expect(await cache.keys("apple", false)).toEqual([apple.jwk]);
    const fetches = s.calls.length;
    s.fail(true);
    now += 3600_000;
    for (let i = 0; i < 120; i++) {
      expect(await cache.keys("apple", i % 3 === 0)).toEqual([apple.jwk]);
      now += 1000;
    }
    expect(s.calls.length).toBe(fetches + 2);
    // Recovery: the next fetch after the cooldown succeeds and clears the failure.
    s.fail(false);
    s.set([google.jwk]);
    now += 60_000;
    expect(await cache.keys("apple", false)).toEqual([google.jwk]);
  });

  it("refuses a response that is not a key set", async () => {
    for (const response of [new Response("nope", { status: 500 }), new Response("not json"), new Response(JSON.stringify({ keys: [] })), new Response("x".repeat(70_000))]) {
      const cache = new JwksCache(async () => response, () => NOW.getTime());
      await expect(cache.keys("apple", false)).rejects.toThrow(/unavailable/);
    }
  });

  it("bounds the cache lifetime", () => {
    expect(cacheLifetime("public, max-age=21600, must-revalidate")).toBe(21600_000);
    expect(cacheLifetime("max-age=1")).toBe(5 * 60_000);
    expect(cacheLifetime("max-age=9999999")).toBe(24 * 3600_000);
    expect(cacheLifetime("no-store")).toBe(5 * 60_000);
    expect(cacheLifetime(null)).toBe(3600_000);
    expect(cacheLifetime("private")).toBe(3600_000);
  });
});

describe("verifyAppleSignInNotification", () => {
  function notification(events: unknown, overrides: Record<string, unknown> = {}) {
    const iat = Math.floor(NOW.getTime() / 1000);
    return signRs256({ iss: "https://appleid.apple.com", aud: "software.tactile.texts", iat, jti: "j-1", events, ...overrides }, apple);
  }

  it("reads the event, from a JSON string or an object", async () => {
    fresh();
    const context = { jwks, now: NOW };
    const event = { type: "consent-revoked", sub: "001.abc.002", event_time: NOW.getTime() };
    expect(await verifyAppleSignInNotification(await notification(JSON.stringify(event)), settings, context)).toEqual({ type: "consent-revoked", subject: "001.abc.002", occurredAt: NOW.getTime() });
    expect(await verifyAppleSignInNotification(await notification(event), settings, context)).toEqual({ type: "consent-revoked", subject: "001.abc.002", occurredAt: NOW.getTime() });
  });

  it("refuses one signed more than a day ago, and never dates the event after its signing", async () => {
    fresh();
    const event = JSON.stringify({ type: "consent-revoked", sub: "001.abc.002" });
    const day = 24 * 3600;
    const iat = Math.floor(NOW.getTime() / 1000);
    const old = await notification(event, { iat: iat - day - 1 });
    expect(await refusal(verifyAppleSignInNotification(old, settings, { jwks, now: NOW }))).toMatch(/^notification-invalid: jwt: too old/);
    const edge = await notification(event, { iat: iat - day });
    expect((await verifyAppleSignInNotification(edge, settings, { jwks, now: NOW })).occurredAt).toBe((iat - day) * 1000);
    // event_time in seconds, and one claiming to be later than the notification.
    const seconds = await notification(JSON.stringify({ type: "consent-revoked", sub: "s", event_time: iat - 30 }));
    expect((await verifyAppleSignInNotification(seconds, settings, { jwks, now: NOW })).occurredAt).toBe((iat - 30) * 1000);
    const later = await notification(JSON.stringify({ type: "consent-revoked", sub: "s", event_time: (iat + 3600) * 1000 }));
    expect((await verifyAppleSignInNotification(later, settings, { jwks, now: NOW })).occurredAt).toBe(iat * 1000);
    const bad = await notification(JSON.stringify({ type: "consent-revoked", sub: "s", event_time: "soon" }));
    expect(await refusal(verifyAppleSignInNotification(bad, settings, { jwks, now: NOW }))).toMatch(/event time/);
  });

  it("refuses another app's, a forged one and one without an event", async () => {
    fresh();
    const context = { jwks, now: NOW };
    const event = JSON.stringify({ type: "account-delete", sub: "001.abc.002" });
    expect(await refusal(verifyAppleSignInNotification(await notification(event, { aud: "com.example.other" }), settings, context))).toMatch(/^notification-invalid: .*audience/);
    const forger = await rsaSigningKey({ kid: apple.kid });
    const forged = await signRs256({ iss: "https://appleid.apple.com", aud: "software.tactile.texts", iat: Math.floor(NOW.getTime() / 1000), events: event }, forger);
    expect(await refusal(verifyAppleSignInNotification(forged, settings, context))).toMatch(/^notification-invalid: .*signature/);
    expect(await refusal(verifyAppleSignInNotification(await notification(undefined), settings, context))).toMatch(/^notification-invalid: events/);
    expect(await refusal(verifyAppleSignInNotification(await notification("{nope"), settings, context))).toMatch(/^notification-invalid/);
    expect(await refusal(verifyAppleSignInNotification(await notification(JSON.stringify({ type: "consent-revoked" })), settings, context))).toMatch(/subject/);
  });
});
