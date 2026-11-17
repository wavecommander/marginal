// Throwaway stand-ins for Apple's and Google's sign-in: RSA key sets, ID tokens signed with them,
// Sign in with Apple notifications, and a Sign in with Apple private key. Nothing here is real.

import { JwksUnavailable, type Jwk, type JwksSource } from "../../src/idToken";
import type { Provider } from "../../src/identity";
import { base64, base64url } from "./pki";

export const APPLE_ISSUER = "https://appleid.apple.com";
export const GOOGLE_ISSUER = "https://accounts.google.com";
export const GOOGLE_CLIENT_ID = "123456789012-abcdefghijklmnopqrstuvwxyz012345.apps.googleusercontent.com";
export const OTHER_GOOGLE_CLIENT_ID = "123456789012-zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz.apps.googleusercontent.com";

export interface SigningKey {
  kid: string;
  keys: CryptoKeyPair;
  jwk: Jwk;
}

let kidCounter = 0;

export async function rsaSigningKey(options: { kid?: string; modulusLength?: number } = {}): Promise<SigningKey> {
  const keys = (await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: options.modulusLength ?? 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const exported = (await crypto.subtle.exportKey("jwk", keys.publicKey)) as JsonWebKey;
  const kid = options.kid ?? `test-key-${++kidCounter}`;
  return { kid, keys, jwk: { kty: "RSA", kid, use: "sig", alg: "RS256", n: exported.n, e: exported.e } };
}

/** A compact RS256 JWT. */
export async function signRs256(claims: Record<string, unknown>, key: SigningKey, header: Record<string, unknown> = {}): Promise<string> {
  const encoder = new TextEncoder();
  const head = base64url(encoder.encode(JSON.stringify({ alg: "RS256", kid: key.kid, typ: "JWT", ...header })));
  const body = base64url(encoder.encode(JSON.stringify(claims)));
  const signature = new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key.keys.privateKey, encoder.encode(`${head}.${body}`)));
  return `${head}.${body}.${base64url(signature)}`;
}

/** The lower-case hex SHA-256 of a base64 challenge's bytes: what the app sends as `nonce`. */
export async function nonceOf(challenge: string): Promise<string> {
  const bytes = Uint8Array.from(atob(challenge), (c) => c.charCodeAt(0));
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Claims shaped like each provider's ID token. */
export function idTokenClaims(provider: Provider, subject: string, nonce: string, now: Date, overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const iat = Math.floor(now.getTime() / 1000);
  if (provider === "apple") {
    return {
      iss: APPLE_ISSUER,
      aud: "software.tactile.texts",
      exp: iat + 600,
      iat,
      sub: subject,
      nonce,
      c_hash: "x",
      email: "reader@privaterelay.appleid.com",
      email_verified: true,
      is_private_email: true,
      auth_time: iat,
      nonce_supported: true,
      ...overrides,
    };
  }
  return {
    iss: GOOGLE_ISSUER,
    azp: GOOGLE_CLIENT_ID,
    aud: GOOGLE_CLIENT_ID,
    sub: subject,
    email: "reader@example.com",
    email_verified: true,
    nonce,
    iat,
    exp: iat + 3600,
    ...overrides,
  };
}

/**
 * Claims of a dev test issuer token (README, "The dev test issuer"): issuer
 * `tactile-texts-dev-test`, audience the bundle ID, 10 minutes' life.
 */
export function devTestClaims(subject: string, nonce: string, now: Date, overrides: Record<string, unknown> = {}): Record<string, unknown> {
  const iat = Math.floor(now.getTime() / 1000);
  return { iss: "tactile-texts-dev-test", aud: "software.tactile.texts", sub: subject, nonce, iat, exp: iat + 600, email: "tester@example.com", ...overrides };
}

/**
 * A dev test issuer token as the app's debug build mints it: header {"alg":"HS256","typ":"JWT"},
 * HMAC-SHA256 over `<header>.<payload>` keyed with the UTF-8 bytes of `secret`.
 */
export async function signDevTestToken(claims: Record<string, unknown>, secret: string, header: Record<string, unknown> = {}): Promise<string> {
  const encoder = new TextEncoder();
  const head = base64url(encoder.encode(JSON.stringify({ alg: "HS256", typ: "JWT", ...header })));
  const body = base64url(encoder.encode(JSON.stringify(claims)));
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(`${head}.${body}`)));
  return `${head}.${body}.${base64url(signature)}`;
}

/** Key sets the test controls. Keys in `pending` appear only when the verifier asks for a refresh. */
export class TestJwks implements JwksSource {
  readonly visible: Record<Provider, Jwk[]> = { apple: [], google: [] };
  readonly pending: Record<Provider, Jwk[]> = { apple: [], google: [] };
  refreshes = 0;
  unavailable = false;

  async keys(provider: Provider, refresh: boolean): Promise<Jwk[]> {
    if (this.unavailable) throw new JwksUnavailable("test: unavailable");
    if (refresh) {
      this.refreshes++;
      this.visible[provider].push(...this.pending[provider].splice(0));
    }
    return this.visible[provider];
  }
}

/** A P-256 key as Apple issues for Sign in with Apple, as PKCS#8 PEM, with its public half. */
export async function siwaKey(): Promise<{ pem: string; publicKey: CryptoKey }> {
  const keys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", keys.privateKey)) as ArrayBuffer);
  const body = base64(der).replace(/(.{64})/g, "$1\n").trim();
  return { pem: `-----BEGIN PRIVATE KEY-----\n${body}\n-----END PRIVATE KEY-----\n`, publicKey: keys.publicKey };
}

export function decodeJwt(token: string): { header: Record<string, unknown>; payload: Record<string, unknown> } {
  const [h, p] = token.split(".");
  const decode = (part: string) => JSON.parse(atob(part.replace(/-/g, "+").replace(/_/g, "/")));
  return { header: decode(h!), payload: decode(p!) };
}
