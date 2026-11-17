// Revoking a Sign in with Apple authorization, as Apple requires when an account is deleted (App
// Store Review Guideline 5.1.1(v)) and as this service also does when an account leaves Apple
// for Google.
//
// Apple ("Revoke tokens", "Generate and validate tokens"): exchange the app's fresh
// authorization code at https://appleid.apple.com/auth/token for a refresh token, then post that
// token to https://appleid.apple.com/auth/revoke. Both calls authenticate with a client secret:
// an ES256 JWT signed with a Sign in with Apple key (APPLE_SIWA_KEY_ID, APPLE_SIWA_PRIVATE_KEY),
// `iss` the team ID, `sub` the client ID (the bundle ID), `aud` https://appleid.apple.com, valid
// five minutes here.
//
// Revocation never decides whether the change or the deletion happens: it runs afterwards, and
// a failure, or a deployment without the key, is logged and the request still succeeds.

import { toBase64Url } from "./bytes";
import type { Settings } from "./env";
import type { OutboundFetch } from "./idToken";
import { logError, logEvent } from "./log";

export const APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token";
export const APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke";
const CLIENT_SECRET_SECONDS = 300;
const FETCH_TIMEOUT_MS = 10_000;

export type RevokeOutcome = "revoked" | "skipped" | "failed";

/** The client secret for Apple's token and revoke endpoints. Throws if the key is not configured or does not import. */
export async function appleClientSecret(settings: Settings, now: Date): Promise<string> {
  if (!settings.siwa) throw new Error("Sign in with Apple key not configured");
  const key = await crypto.subtle.importKey("pkcs8", settings.siwa.privateKeyPkcs8, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const encoder = new TextEncoder();
  const iat = Math.floor(now.getTime() / 1000);
  const header = toBase64Url(encoder.encode(JSON.stringify({ alg: "ES256", kid: settings.siwa.keyId })));
  const payload = toBase64Url(
    encoder.encode(JSON.stringify({ iss: settings.teamId, iat, exp: iat + CLIENT_SECRET_SECONDS, aud: "https://appleid.apple.com", sub: settings.bundleId })),
  );
  // WebCrypto's ECDSA signature is already JWS's fixed-width r || s.
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, encoder.encode(`${header}.${payload}`)));
  return `${header}.${payload}.${toBase64Url(signature)}`;
}

/** Exchanges `authorizationCode` and revokes what it grants. Never throws; logs the outcome (never a token). */
export async function revokeAppleAuthorization(authorizationCode: string, settings: Settings, fetcher: OutboundFetch, now: Date, why: string): Promise<RevokeOutcome> {
  if (!settings.siwa) {
    logEvent("apple-revoke-skipped", { why, reason: "APPLE_SIWA_KEY_ID and APPLE_SIWA_PRIVATE_KEY are not set" });
    return "skipped";
  }
  try {
    const clientSecret = await appleClientSecret(settings, now);
    const exchange = await post(fetcher, APPLE_TOKEN_URL, {
      client_id: settings.bundleId,
      client_secret: clientSecret,
      code: authorizationCode,
      grant_type: "authorization_code",
    });
    if (exchange.status !== 200) {
      logError("apple-revoke-failed", { why, step: "token", status: exchange.status });
      return "failed";
    }
    const tokens = (await exchange.json().catch(() => null)) as { refresh_token?: unknown; access_token?: unknown } | null;
    const refresh = typeof tokens?.refresh_token === "string" ? tokens.refresh_token : undefined;
    const access = typeof tokens?.access_token === "string" ? tokens.access_token : undefined;
    if (!refresh && !access) {
      logError("apple-revoke-failed", { why, step: "token", reason: "no token in the response" });
      return "failed";
    }
    const revoke = await post(fetcher, APPLE_REVOKE_URL, {
      client_id: settings.bundleId,
      client_secret: clientSecret,
      token: (refresh ?? access)!,
      token_type_hint: refresh ? "refresh_token" : "access_token",
    });
    if (revoke.status !== 200) {
      logError("apple-revoke-failed", { why, step: "revoke", status: revoke.status });
      return "failed";
    }
    logEvent("apple-revoked", { why });
    return "revoked";
  } catch (error) {
    logError("apple-revoke-failed", { why, reason: error instanceof Error ? error.message.slice(0, 120) : "unknown" });
    return "failed";
  }
}

function post(fetcher: OutboundFetch, url: string, form: Record<string, string>): Promise<Response> {
  return fetcher(url, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
    body: new URLSearchParams(form).toString(),
    redirect: "error",
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
}
