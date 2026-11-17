// The checks every attested request goes through, in this order: the body and its fields; the
// challenge (consumed even if a later check fails); the App Attest assertion over the exact body
// (or, in `dev` only, the bypass secret); then, for requests made while signed in, the device
// session.

import { reason } from "./appleJws";
import { attestPolicy, verifyAssertion } from "./appAttest";
import { equalStrings, fromBase64, hex, sha256 } from "./bytes";
import { AUTH_HEADERS, type Action } from "./contract";
import * as db from "./db";
import type { Env, Settings } from "./env";
import { Refusal, readJsonBody, stringField } from "./http";
import { SESSION_TOKEN_PATTERN, sessionTokenHash } from "./identity";
import { logEvent } from "./log";
import type { Deps } from "./service";

export const CHALLENGE_BYTES = 32;

export interface Attested<T> {
  /** The endpoint's own fields, read before anything was consumed. */
  fields: T;
  /** The challenge's bytes (an ID token's nonce is their hash). */
  challenge: Uint8Array;
  /** The App Attest key that signed the request; null when the dev bypass let it through. */
  attestKeyId: string | null;
}

/**
 * Authenticates an attested request. `readFields` checks the endpoint's own fields (throwing
 * `bad-request`) before the challenge is spent.
 */
export async function authenticate<T>(
  request: Request,
  env: Env,
  settings: Settings,
  deps: Deps,
  action: Action,
  readFields: (body: Record<string, unknown>) => T,
): Promise<Attested<T>> {
  const { bytes, value } = await readJsonBody(request);
  if (stringField(value, "action", 32) !== action) throw new Refusal("bad-request", "action does not match the endpoint");
  const challengeText = stringField(value, "challenge", 64);
  const fields = readFields(value);
  const challenge = await useChallenge(env, challengeText, deps);

  const bypass = request.headers.get(AUTH_HEADERS.bypass);
  // Only `dev` has a bypass secret at all (readSettings refuses one in production); check the
  // environment again anyway so no configuration can make production honour it.
  const bypassed =
    settings.environment === "dev" &&
    settings.attestBypassSecret !== undefined &&
    bypass !== null &&
    equalStrings(bypass, settings.attestBypassSecret);
  if (bypassed) {
    logEvent("attest-bypassed");
    return { fields, challenge, attestKeyId: null };
  }
  const attestKeyId = await checkAssertion(request, env, settings, bytes, deps);
  return { fields, challenge, attestKeyId };
}

async function checkAssertion(request: Request, env: Env, settings: Settings, body: Uint8Array, deps: Deps): Promise<string> {
  const keyIdText = request.headers.get(AUTH_HEADERS.keyId);
  const assertionText = request.headers.get(AUTH_HEADERS.assertion);
  if (!keyIdText || !assertionText || keyIdText.length > 64 || assertionText.length > 8192) {
    throw new Refusal("assertion-invalid", "missing assertion headers");
  }
  let assertion: Uint8Array;
  try {
    assertion = fromBase64(assertionText);
  } catch {
    throw new Refusal("assertion-invalid", "assertion is not base64");
  }
  const device = await db.getDevice(env.DB, keyIdText);
  if (!device) throw new Refusal("device-unknown", "no such key");
  const policy = attestPolicy(settings.environment, settings.appId);
  if (!policy.environments.has(device.environment)) throw new Refusal("device-unknown", "key from another App Attest environment");
  let counter: number;
  try {
    ({ counter } = await verifyAssertion({ assertion, clientData: body, publicKey: device.publicKey, previousCounter: device.counter, policy }));
  } catch (error) {
    throw new Refusal("assertion-invalid", reason(error));
  }
  // Atomic: of two requests carrying the same counter, only one gets through.
  if (!(await db.advanceCounter(env.DB, keyIdText, counter, deps.now().getTime()))) {
    throw new Refusal("assertion-invalid", "counter already used");
  }
  return keyIdText;
}

export async function useChallenge(env: Env, challengeText: string, deps: Deps): Promise<Uint8Array> {
  let bytes: Uint8Array;
  try {
    bytes = fromBase64(challengeText);
  } catch {
    throw new Refusal("challenge-invalid", "not base64");
  }
  if (bytes.length !== CHALLENGE_BYTES) throw new Refusal("challenge-invalid", "wrong length");
  if (!(await db.consumeChallenge(env.DB, hex(await sha256(bytes)), deps.now().getTime()))) {
    throw new Refusal("challenge-invalid", "unknown, used or expired");
  }
  return bytes;
}

/** Reads the `deviceSessionToken` field (shape only; `requireSession` checks it). */
export function sessionTokenField(body: Record<string, unknown>): string {
  const token = stringField(body, "deviceSessionToken", 64);
  if (!SESSION_TOKEN_PATTERN.test(token)) throw new Refusal("bad-request", "field deviceSessionToken");
  return token;
}

export interface SignedIn {
  session: db.DeviceSession;
  account: db.Account;
}

/**
 * The account behind a device session. The session must exist, and must have been made with the
 * App Attest key that signed this request (so a copied token is useless on another device).
 * Accounts being deleted are refused unless `allowDeleting`.
 */
export async function requireSession(env: Env, deps: Deps, token: string, attestKeyId: string | null, options: { allowDeleting?: boolean } = {}): Promise<SignedIn> {
  const session = await db.getSessionByTokenHash(env.DB, await sessionTokenHash(token));
  if (!session) throw new Refusal("session-invalid", "no such session");
  if (session.attestKeyId !== null && attestKeyId !== null && session.attestKeyId !== attestKeyId) {
    throw new Refusal("session-invalid", "session belongs to another App Attest key");
  }
  const account = await db.getAccount(env.DB, session.accountId);
  if (!account) throw new Refusal("session-invalid", "no such account");
  if (account.deletingSince !== null && !options.allowDeleting) throw new Refusal("account-deleting", "account is being deleted");
  await db.touchSession(env.DB, session.sessionId, deps.now().getTime());
  return { session, account };
}
