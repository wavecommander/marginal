// Verifying sign-in: Apple's and Google's OpenID Connect ID tokens, and Apple's Sign in with
// Apple server-to-server notifications. Both are RS256 JWTs signed with keys the provider
// publishes as a JSON Web Key Set at a fixed address:
//
//   Apple   https://appleid.apple.com/auth/keys          iss https://appleid.apple.com
//   Google  https://www.googleapis.com/oauth2/v3/certs   iss accounts.google.com or https://accounts.google.com
//
// A token is accepted only if: its header says RS256 and names a key (`kid`) in that set (the
// set is fetched again, at most once per token, when the key is unknown, since providers rotate
// keys); the signature verifies with that key (RSA, at least 2,048 bits); the issuer is the
// provider's; the audience is this app (Apple: the bundle ID; Google: one of GOOGLE_CLIENT_IDS,
// and `azp` too when present); it has not expired and was not issued in the future (a minute's
// skew either way); and, for ID tokens, its `nonce` is the lower-case hex SHA-256 of the
// challenge this request consumed, so a token is good for one request only.
//
// Only the two fixed addresses are ever fetched. Key sets are cached for as long as the
// provider's Cache-Control says, kept within 5 minutes to 24 hours.

import { fromBase64Url, hex, sha256 } from "./bytes";
import type { Settings } from "./env";
import { Refusal } from "./http";
import type { Provider } from "./identity";
import { logError } from "./log";

export const JWKS_URLS: Readonly<Record<Provider, string>> = {
  apple: "https://appleid.apple.com/auth/keys",
  google: "https://www.googleapis.com/oauth2/v3/certs",
};

const ISSUERS: Readonly<Record<Provider, readonly string[]>> = {
  apple: ["https://appleid.apple.com"],
  google: ["accounts.google.com", "https://accounts.google.com"],
};

/** Allowed difference between clocks, either way. */
const SKEW_MS = 60_000;
const MAX_TOKEN_LENGTH = 8 * 1024;
const MAX_JWKS_BYTES = 64 * 1024;
const MIN_CACHE_MS = 5 * 60_000;
const MAX_CACHE_MS = 24 * 60 * 60_000;
const DEFAULT_CACHE_MS = 60 * 60_000;
/** Refetching for an unknown key happens at most this often, so made-up `kid`s cannot drive traffic. */
const REFRESH_COOLDOWN_MS = 60_000;
/** A key set that cannot be refreshed is still used for this long past its expiry. */
const MAX_STALE_MS = 24 * 60 * 60_000;
const FETCH_TIMEOUT_MS = 10_000;

/** One RSA key from a JWKS. */
export interface Jwk {
  kty?: unknown;
  kid?: unknown;
  n?: unknown;
  e?: unknown;
  alg?: unknown;
  use?: unknown;
}

/** Where key sets come from. Tests pass generated sets; deployments a `JwksCache`. */
export interface JwksSource {
  /**
   * The provider's keys. `refresh`: a token named a key not in the set the caller saw, so fetch
   * again if allowed. Throws `JwksUnavailable` when there is nothing usable.
   */
  keys(provider: Provider, refresh: boolean): Promise<Jwk[]>;
}

export class JwksUnavailable extends Error {}

export type OutboundFetch = (url: string, init?: RequestInit) => Promise<Response>;

interface CacheEntry {
  keys: Jwk[];
  fetchedAt: number;
  expiresAt: number;
}

/** Fetches and caches the two providers' key sets. One per isolate is enough. */
export class JwksCache implements JwksSource {
  private readonly entries = new Map<Provider, CacheEntry>();

  constructor(
    private readonly fetcher: OutboundFetch,
    private readonly now: () => number = () => Date.now(),
  ) {}

  async keys(provider: Provider, refresh: boolean): Promise<Jwk[]> {
    const now = this.now();
    const entry = this.entries.get(provider);
    if (entry) {
      const fresh = now < entry.expiresAt;
      if (fresh && !refresh) return entry.keys;
      if (refresh && now - entry.fetchedAt < REFRESH_COOLDOWN_MS) return entry.keys;
    }
    try {
      const fetched = await this.fetch(provider, now);
      this.entries.set(provider, fetched);
      return fetched.keys;
    } catch (error) {
      logError("jwks-fetch-failed", { provider, reason: error instanceof Error ? error.message.slice(0, 120) : "unknown" });
      if (entry && now < entry.expiresAt + MAX_STALE_MS) return entry.keys;
      throw new JwksUnavailable(`${provider} keys unavailable`);
    }
  }

  private async fetch(provider: Provider, now: number): Promise<CacheEntry> {
    const response = await this.fetcher(JWKS_URLS[provider], {
      method: "GET",
      headers: { accept: "application/json" },
      redirect: "error",
      signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
    });
    if (response.status !== 200) throw new Error(`status ${response.status}`);
    const text = await response.text();
    if (text.length > MAX_JWKS_BYTES) throw new Error("key set too large");
    let parsed: unknown;
    try {
      parsed = JSON.parse(text);
    } catch {
      throw new Error("key set is not JSON");
    }
    const keys = (parsed as { keys?: unknown } | null)?.keys;
    if (!Array.isArray(keys) || keys.length === 0) throw new Error("no keys");
    return { keys: keys.filter((key): key is Jwk => typeof key === "object" && key !== null), fetchedAt: now, expiresAt: now + cacheLifetime(response.headers.get("cache-control")) };
  }
}

/** How long to keep a key set, from Cache-Control `max-age`, within bounds. */
export function cacheLifetime(cacheControl: string | null): number {
  if (!cacheControl) return DEFAULT_CACHE_MS;
  if (/(^|[,\s])(no-store|no-cache)([,\s]|$)/i.test(cacheControl)) return MIN_CACHE_MS;
  const match = /(?:^|[,\s])max-age\s*=\s*"?(\d{1,10})"?/i.exec(cacheControl);
  if (!match) return DEFAULT_CACHE_MS;
  return Math.min(MAX_CACHE_MS, Math.max(MIN_CACHE_MS, Number(match[1]) * 1000));
}

export interface JwtContext {
  jwks: JwksSource;
  now: Date;
}

interface Expectations {
  audiences: readonly string[];
  requireExpiry: boolean;
}

/**
 * Verifies an RS256 JWT from `provider` and returns its claims. Throws a plain Error naming
 * what failed (never the token), or `JwksUnavailable`.
 */
export async function verifyProviderJwt(token: string, provider: Provider, expect: Expectations, context: JwtContext): Promise<Record<string, unknown>> {
  if (token.length > MAX_TOKEN_LENGTH) throw new Error("jwt: too long");
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("jwt: not compact serialization");
  const [headerPart, payloadPart, signaturePart] = parts as [string, string, string];
  const header = jsonObject(headerPart, "header");
  const claims = jsonObject(payloadPart, "payload");
  if (header.alg !== "RS256") throw new Error("jwt: algorithm is not RS256");
  if ("crit" in header) throw new Error("jwt: critical header parameters");
  const kid = header.kid;
  if (typeof kid !== "string" || kid.length === 0 || kid.length > 256) throw new Error("jwt: no key ID");
  let signature: Uint8Array;
  try {
    signature = fromBase64Url(signaturePart);
  } catch {
    throw new Error("jwt: signature is not base64url");
  }

  let jwk = (await context.jwks.keys(provider, false)).find((key) => key.kid === kid);
  if (!jwk) jwk = (await context.jwks.keys(provider, true)).find((key) => key.kid === kid);
  if (!jwk) throw new Error("jwt: unknown key");
  const key = await importRsaKey(jwk);
  const valid = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, new TextEncoder().encode(`${headerPart}.${payloadPart}`));
  if (!valid) throw new Error("jwt: bad signature");

  if (typeof claims.iss !== "string" || !ISSUERS[provider].includes(claims.iss)) throw new Error("jwt: issuer");
  const aud = Array.isArray(claims.aud) && claims.aud.length === 1 ? claims.aud[0] : claims.aud;
  if (typeof aud !== "string" || !expect.audiences.includes(aud)) throw new Error("jwt: audience");
  const now = context.now.getTime();
  if (claims.exp !== undefined || expect.requireExpiry) {
    if (!isSeconds(claims.exp)) throw new Error("jwt: no expiry");
    if (now >= claims.exp * 1000 + SKEW_MS) throw new Error("jwt: expired");
  }
  if (!isSeconds(claims.iat)) throw new Error("jwt: no issue time");
  if (claims.iat * 1000 > now + SKEW_MS) throw new Error("jwt: issued in the future");
  return claims;
}

async function importRsaKey(jwk: Jwk): Promise<CryptoKey> {
  if (jwk.kty !== "RSA" || typeof jwk.n !== "string" || typeof jwk.e !== "string") throw new Error("jwt: key is not RSA");
  if (jwk.use !== undefined && jwk.use !== "sig") throw new Error("jwt: key is not for signing");
  if (jwk.alg !== undefined && jwk.alg !== "RS256") throw new Error("jwt: key is for another algorithm");
  let key: CryptoKey;
  try {
    key = await crypto.subtle.importKey(
      "jwk",
      { kty: "RSA", n: jwk.n, e: jwk.e, alg: "RS256", ext: true },
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
  } catch {
    throw new Error("jwt: key does not import");
  }
  if (((key.algorithm as { modulusLength?: number }).modulusLength ?? 0) < 2048) throw new Error("jwt: key too short");
  return key;
}

/** The `nonce` an ID token must carry for a challenge: lower-case hex SHA-256 of its bytes. */
export async function nonceFor(challenge: Uint8Array): Promise<string> {
  return hex(await sha256(challenge));
}

export interface VerifiedIdToken {
  provider: Provider;
  /** The provider's stable user ID. Hash it at once; never store or log it. */
  subject: string;
}

/**
 * Verifies a sign-in ID token for `provider`, bound to this request's challenge. Refuses with
 * `provider-disabled` (Google not configured), `provider-unreachable` (no key set) or
 * `id-token-invalid`.
 */
export async function verifyIdToken(token: string, provider: Provider, nonce: string, settings: Settings, context: JwtContext): Promise<VerifiedIdToken> {
  const audiences = audiencesFor(provider, settings);
  let claims: Record<string, unknown>;
  try {
    claims = await verifyProviderJwt(token, provider, { audiences, requireExpiry: true }, context);
  } catch (error) {
    if (error instanceof JwksUnavailable) throw new Refusal("provider-unreachable", error.message);
    throw new Refusal("id-token-invalid", error instanceof Error ? error.message : "unknown");
  }
  if (typeof claims.nonce !== "string" || claims.nonce !== nonce) throw new Refusal("id-token-invalid", "jwt: nonce");
  if (provider === "google" && claims.azp !== undefined && (typeof claims.azp !== "string" || !audiences.includes(claims.azp))) {
    throw new Refusal("id-token-invalid", "jwt: authorized party");
  }
  const subject = claims.sub;
  if (typeof subject !== "string" || subject.length === 0 || subject.length > 255 || subject.includes("\0")) {
    throw new Refusal("id-token-invalid", "jwt: subject");
  }
  return { provider, subject };
}

export function audiencesFor(provider: Provider, settings: Settings): readonly string[] {
  if (provider === "apple") return [settings.bundleId];
  if (settings.googleClientIds.length === 0) throw new Refusal("provider-disabled", "GOOGLE_CLIENT_IDS is empty");
  return settings.googleClientIds;
}

export interface AppleSignInEvent {
  /** `email-disabled`, `email-enabled`, `consent-revoked`, `account-delete`, or another Apple adds. */
  type: string;
  /** The Apple user ID the event is about. Hash it at once; never store or log it. */
  subject: string;
}

/**
 * Verifies a Sign in with Apple server-to-server notification (`payload`, a JWT signed with
 * Apple's sign-in keys, audience the bundle ID) and returns its event. `events` arrives as a JSON
 * string; an object is accepted too.
 */
export async function verifyAppleSignInNotification(payload: string, settings: Settings, context: JwtContext): Promise<AppleSignInEvent> {
  let claims: Record<string, unknown>;
  try {
    claims = await verifyProviderJwt(payload, "apple", { audiences: [settings.bundleId], requireExpiry: false }, context);
  } catch (error) {
    if (error instanceof JwksUnavailable) throw new Refusal("provider-unreachable", error.message);
    throw new Refusal("notification-invalid", error instanceof Error ? error.message : "unknown");
  }
  let events: unknown = claims.events;
  if (typeof events === "string") {
    try {
      events = JSON.parse(events);
    } catch {
      throw new Refusal("notification-invalid", "events is not JSON");
    }
  }
  if (typeof events !== "object" || events === null || Array.isArray(events)) throw new Refusal("notification-invalid", "events");
  const { type, sub } = events as Record<string, unknown>;
  if (typeof type !== "string" || type.length === 0 || type.length > 64) throw new Refusal("notification-invalid", "event type");
  if (typeof sub !== "string" || sub.length === 0 || sub.length > 255 || sub.includes("\0")) throw new Refusal("notification-invalid", "event subject");
  return { type, subject: sub };
}

function jsonObject(part: string, what: string): Record<string, unknown> {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(fromBase64Url(part)));
  } catch {
    throw new Error(`jwt: ${what} is not JSON`);
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error(`jwt: ${what} is not an object`);
  return value as Record<string, unknown>;
}

function isSeconds(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && value > 0;
}
