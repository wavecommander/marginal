// Who a reader is, to this service, and the random names it hands out.
//
// A reader is an account. An account has exactly one sign-in identity: Apple's or Google's
// stable user ID (the ID token's `sub`) for this app. The service never stores that ID. It
// stores a keyed hash of it,
//
//     identityHash = hex(HMAC-SHA256(IDENTITY_KEY_SECRET,
//                        "tactile-identity-v1\0" || provider || "\0" || subject))
//
// so a database row cannot be worked back to an Apple or Google account without the Worker's
// secret. `provider` there is the identity's namespace: `apple` or `google` for the real
// providers, and `dev-test:apple` or `dev-test:google` for identities from the `dev`
// deployment's test issuer (see idToken.ts), so a test token can never reach, prove or take over
// an account made with a real Apple or Google sign-in, whatever its subject. Subscriptions are found the same way, in their own domain:
//
//     subscriptionKey = hex(HMAC-SHA256(IDENTITY_KEY_SECRET,
//                           "tactile-subscription-v1\0" || environment || "\0" || originalTransactionId))
//
// Everything else that names an account is random: its ID, its folder, its appAccountToken and
// each device session. Changing IDENTITY_KEY_SECRET therefore loses every sign-in and every
// subscription binding (folders are unaffected); set it once and keep it.

import type { AppleEnvironment } from "./appleJws";
import { fromBase64Url, hex, randomBytes, sha256, toBase64Url } from "./bytes";

export type Provider = "apple" | "google";

/**
 * The namespace an identity is hashed in: the real provider's, or the dev test issuer's
 * stand-in for it. Never stored; only the hash is.
 */
export type IdentityNamespace = Provider | "dev-test:apple" | "dev-test:google";

const NAMESPACES: ReadonlySet<string> = new Set<IdentityNamespace>(["apple", "google", "dev-test:apple", "dev-test:google"]);

/** The namespace of identities from the dev test issuer standing in for `provider`. */
export function devTestNamespace(provider: Provider): IdentityNamespace {
  return provider === "apple" ? "dev-test:apple" : "dev-test:google";
}

const IDENTITY_DOMAIN = "tactile-identity-v1\0";
const SUBSCRIPTION_DOMAIN = "tactile-subscription-v1\0";

async function hmacHex(secret: string, message: string): Promise<string> {
  if (secret.length < 32) throw new Error("IDENTITY_KEY_SECRET must be at least 32 characters");
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return hex(new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(message))));
}

export async function identityHash(secret: string, namespace: IdentityNamespace, subject: string): Promise<string> {
  if (!NAMESPACES.has(namespace)) throw new Error("identityHash: unknown namespace");
  if (subject.length === 0 || subject.length > 255 || subject.includes("\0")) throw new Error("identityHash: not a subject");
  return hmacHex(secret, `${IDENTITY_DOMAIN}${namespace}\0${subject}`);
}

export async function subscriptionKey(secret: string, environment: AppleEnvironment, originalTransactionId: string): Promise<string> {
  if (environment !== "Production" && environment !== "Sandbox" && environment !== "Xcode") throw new Error("subscriptionKey: environment");
  // Apple's IDs are decimal digits; refuse anything else so no other string can be hashed in.
  if (!/^[0-9]{1,40}$/.test(originalTransactionId)) throw new Error("not an original transaction ID");
  return hmacHex(secret, `${SUBSCRIPTION_DOMAIN}${environment}\0${originalTransactionId}`);
}

/** A new account's ID: 32 hex digits. */
export function newAccountId(): string {
  return hex(randomBytes(16));
}

/** A new account's folder name: 64 hex digits (what `userPrefix` accepts). */
export function newFolderKey(): string {
  return hex(randomBytes(32));
}

/** A new device session's public ID: 32 hex digits. */
export function newSessionId(): string {
  return hex(randomBytes(16));
}

/** A device session token: 32 random bytes, unpadded base64url (43 characters). Shown once. */
export function newSessionToken(): string {
  return toBase64Url(randomBytes(32));
}

export const SESSION_TOKEN_PATTERN = /^[A-Za-z0-9_-]{43}$/;

/** What is stored for a session token: hex SHA-256 of its 32 bytes. Throws on anything else. */
export async function sessionTokenHash(token: string): Promise<string> {
  if (!SESSION_TOKEN_PATTERN.test(token)) throw new Error("not a session token");
  const bytes = fromBase64Url(token);
  if (bytes.length !== 32) throw new Error("not a session token");
  return hex(await sha256(bytes));
}

/** StoreKit's appAccountToken is a UUID; it is compared in lower case. Undefined if malformed. */
export function normalizeAppAccountToken(value: string): string | undefined {
  const lower = value.toLowerCase();
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(lower) ? lower : undefined;
}
