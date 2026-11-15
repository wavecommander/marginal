// Verifying what the App Store signs: transactions, renewal info and server notifications.
//
// Each is a JWS (compact serialization, ES256) whose header carries the signing certificate
// chain in `x5c`. Following Apple's App Store Server Library (`SignedDataVerifier`), which
// Apple's documentation directs servers to:
//   - the chain has exactly three certificates: leaf, intermediate, root;
//   - the root is one of the pinned Apple roots (here: byte for byte);
//   - the leaf carries Apple's marker extension 1.2.840.113635.100.6.11.1 and the intermediate
//     1.2.840.113635.100.6.2.1;
//   - each certificate is signed by the next, the intermediate is a CA, and every certificate is
//     within its validity dates at the payload's `signedDate` (Apple's rule when no online
//     revocation check is made, so a transaction signed before a certificate expired stays valid);
//   - the JWS signature verifies with the leaf's key.
// Then the payload: bundle ID, environment, and for transactions the product and its type.
//
// StoreKit Testing in Xcode signs with a self-signed certificate of its own (Apple: "There's no
// certificate chain"). Only the `dev` deployment trusts one, and only the exact certificate
// configured in XCODE_STOREKIT_CERT; a payload signed that way must say `environment: Xcode`.
//
// Not done: Apple's library can also ask Apple's OCSP responders whether a certificate has been
// revoked ("online checks"). This Worker does not; see README, "Limits".

import { equalBytes, fromBase64, fromBase64Url } from "./bytes";
import type { Settings } from "./env";
import { Refusal } from "./http";
import { parseCertificate, verifyChain, importPublicKey, type Certificate } from "./x509";

const LEAF_MARKER = "1.2.840.113635.100.6.11.1";
const INTERMEDIATE_MARKER = "1.2.840.113635.100.6.2.1";
/** A JWS longer than this is not something the App Store sends. */
const MAX_JWS_LENGTH = 32 * 1024;
/** A `signedDate` this far in the future means a broken clock somewhere; refuse. */
const FUTURE_SKEW_MS = 5 * 60_000;

export type AppleEnvironment = "Production" | "Sandbox" | "Xcode";

export interface Trust {
  /** DER of the trusted App Store roots (Apple Root CA - G3 in deployment; generated in tests). */
  appleRoots: Uint8Array[];
  /** DER of Xcode's StoreKit test certificate; `dev` only. */
  xcodeRoot?: Uint8Array;
}

export interface VerifyContext {
  settings: Settings;
  trust: Trust;
  now: Date;
}

export interface Transaction {
  originalTransactionId: string;
  transactionId: string;
  productId: string;
  environment: AppleEnvironment;
  /** ms since 1970 */
  signedDate: number;
  expiresDate: number;
  revocationDate: number | undefined;
}

export interface RenewalInfo {
  originalTransactionId: string;
  environment: AppleEnvironment;
  signedDate: number;
  isInBillingRetryPeriod: boolean;
  gracePeriodExpiresDate: number | undefined;
}

export interface Notification {
  notificationType: string;
  subtype: string | undefined;
  notificationUUID: string;
  signedDate: number;
  environment: AppleEnvironment | undefined;
  signedTransactionInfo: string | undefined;
  signedRenewalInfo: string | undefined;
}

/** Verifies a JWS's signature and chain; returns the payload and how it was signed. Throws a plain Error. */
export async function verifyJws(jws: string, trust: Trust, now: Date): Promise<{ payload: Record<string, unknown>; signer: "apple" | "xcode" }> {
  if (jws.length > MAX_JWS_LENGTH) throw new Error("jws: too long");
  const parts = jws.split(".");
  if (parts.length !== 3) throw new Error("jws: not compact serialization");
  const [headerPart, payloadPart, signaturePart] = parts as [string, string, string];
  const header = jsonObject(fromBase64Url(headerPart), "header");
  const payload = jsonObject(fromBase64Url(payloadPart), "payload");
  if (header.alg !== "ES256") throw new Error("jws: algorithm is not ES256");
  if ("crit" in header) throw new Error("jws: critical header parameters");
  const x5c = header.x5c;
  if (!Array.isArray(x5c) || x5c.some((entry) => typeof entry !== "string")) throw new Error("jws: no x5c");
  const der = (x5c as string[]).map((entry) => fromBase64(entry));

  const signedDate = payload.signedDate;
  if (typeof signedDate !== "number" || !Number.isSafeInteger(signedDate) || signedDate <= 0) {
    throw new Error("jws: no signedDate");
  }
  if (signedDate > now.getTime() + FUTURE_SKEW_MS) throw new Error("jws: signed in the future");
  const effectiveDate = new Date(signedDate);

  let leaf: Certificate;
  let signer: "apple" | "xcode";
  if (der.length === 3) {
    if (!trust.appleRoots.some((root) => equalBytes(root, der[2]!))) throw new Error("jws: root is not trusted");
    const chain = der.map((bytes) => parseCertificate(bytes));
    leaf = chain[0]!;
    if (!leaf.extensions.has(LEAF_MARKER)) throw new Error("jws: leaf lacks Apple's marker");
    if (!chain[1]!.extensions.has(INTERMEDIATE_MARKER)) throw new Error("jws: intermediate lacks Apple's marker");
    await verifyChain(chain, effectiveDate);
    signer = "apple";
  } else if (der.length === 1 && trust.xcodeRoot && equalBytes(trust.xcodeRoot, der[0]!)) {
    leaf = parseCertificate(der[0]!);
    await verifyChain([leaf], effectiveDate);
    signer = "xcode";
  } else {
    throw new Error("jws: unexpected certificate chain");
  }
  if (leaf.curve !== "P-256") throw new Error("jws: leaf key is not P-256");
  if (leaf.keyUsage !== undefined && !(leaf.keyUsage & 0x80)) throw new Error("jws: leaf may not sign");

  const signature = fromBase64Url(signaturePart);
  if (signature.length !== 64) throw new Error("jws: bad signature length");
  const key = await importPublicKey(leaf);
  const valid = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    signature,
    new TextEncoder().encode(`${headerPart}.${payloadPart}`),
  );
  if (!valid) throw new Error("jws: bad signature");

  // An Xcode-signed payload can only be an Xcode payload, and Apple never signs one.
  const environment = payload.environment;
  if (signer === "xcode" && environment !== "Xcode") throw new Error("jws: Xcode signature on a non-Xcode payload");
  if (signer === "apple" && environment === "Xcode") throw new Error("jws: Apple signature on an Xcode payload");
  return { payload, signer };
}

/** Which App Store environments a deployment serves. */
export function environmentAccepted(settings: Settings, environment: unknown): environment is AppleEnvironment {
  if (settings.environment === "production") return environment === "Production" || environment === "Sandbox";
  // `dev` never serves real customers' purchases: its bucket is not the production one.
  return environment === "Sandbox" || (environment === "Xcode" && settings.xcodeStoreKitCert !== undefined);
}

export async function verifyTransaction(jws: string, context: VerifyContext): Promise<Transaction> {
  let payload: Record<string, unknown>;
  try {
    ({ payload } = await verifyJws(jws, trustFor(context), context.now));
  } catch (error) {
    throw new Refusal("transaction-invalid", reason(error));
  }
  if (payload.bundleId !== context.settings.bundleId) throw new Refusal("transaction-invalid", "bundle ID");
  if (!environmentAccepted(context.settings, payload.environment)) {
    throw new Refusal("environment-not-accepted", `environment ${String(payload.environment).slice(0, 16)}`);
  }
  if (payload.type !== "Auto-Renewable Subscription") throw new Refusal("product-unknown", "not an auto-renewable subscription");
  if (typeof payload.productId !== "string" || !context.settings.allowances.has(payload.productId)) {
    throw new Refusal("product-unknown", "product");
  }
  const originalTransactionId = transactionIdField(payload.originalTransactionId);
  const transactionId = transactionIdField(payload.transactionId);
  const expiresDate = payload.expiresDate;
  if (!originalTransactionId || !transactionId || !isTime(expiresDate)) {
    throw new Refusal("transaction-invalid", "missing fields");
  }
  const revocationDate = payload.revocationDate;
  if (revocationDate !== undefined && !isTime(revocationDate)) throw new Refusal("transaction-invalid", "revocation date");
  return {
    originalTransactionId,
    transactionId,
    productId: payload.productId,
    environment: payload.environment,
    signedDate: payload.signedDate as number,
    expiresDate,
    revocationDate,
  };
}

export async function verifyRenewalInfo(jws: string, context: VerifyContext): Promise<RenewalInfo> {
  let payload: Record<string, unknown>;
  try {
    ({ payload } = await verifyJws(jws, trustFor(context), context.now));
  } catch (error) {
    throw new Refusal("transaction-invalid", `renewal info: ${reason(error)}`);
  }
  // Renewal info carries no bundle ID (nor does Apple's library check one); the caller ties it
  // to a verified transaction through the original transaction ID.
  if (!environmentAccepted(context.settings, payload.environment)) {
    throw new Refusal("environment-not-accepted", "renewal info environment");
  }
  const originalTransactionId = transactionIdField(payload.originalTransactionId);
  if (!originalTransactionId) throw new Refusal("transaction-invalid", "renewal info fields");
  const retry = payload.isInBillingRetryPeriod;
  if (retry !== undefined && typeof retry !== "boolean") throw new Refusal("transaction-invalid", "renewal info retry flag");
  const grace = payload.gracePeriodExpiresDate;
  if (grace !== undefined && !isTime(grace)) throw new Refusal("transaction-invalid", "renewal info grace date");
  return {
    originalTransactionId,
    environment: payload.environment,
    signedDate: payload.signedDate as number,
    isInBillingRetryPeriod: retry === true,
    gracePeriodExpiresDate: grace,
  };
}

export async function verifyNotification(signedPayload: string, context: VerifyContext): Promise<Notification> {
  let payload: Record<string, unknown>;
  try {
    ({ payload } = await verifyJws(signedPayload, trustFor(context), context.now));
  } catch (error) {
    throw new Refusal("notification-invalid", reason(error));
  }
  const { notificationType, subtype, notificationUUID } = payload;
  if (typeof notificationType !== "string" || typeof notificationUUID !== "string") {
    throw new Refusal("notification-invalid", "fields");
  }
  if (subtype !== undefined && typeof subtype !== "string") throw new Refusal("notification-invalid", "subtype");
  const data = payload.data;
  let environment: AppleEnvironment | undefined;
  let signedTransactionInfo: string | undefined;
  let signedRenewalInfo: string | undefined;
  if (data !== undefined) {
    if (typeof data !== "object" || data === null || Array.isArray(data)) throw new Refusal("notification-invalid", "data");
    const fields = data as Record<string, unknown>;
    if (fields.bundleId !== context.settings.bundleId) throw new Refusal("notification-invalid", "bundle ID");
    if (!environmentAccepted(context.settings, fields.environment)) {
      throw new Refusal("notification-invalid", "environment");
    }
    environment = fields.environment;
    // As Apple's library does: in production the notification must name this app's Apple ID.
    if (environment === "Production" && fields.appAppleId !== context.settings.appAppleId) {
      throw new Refusal("notification-invalid", "app Apple ID");
    }
    if (fields.signedTransactionInfo !== undefined) {
      if (typeof fields.signedTransactionInfo !== "string") throw new Refusal("notification-invalid", "transaction field");
      signedTransactionInfo = fields.signedTransactionInfo;
    }
    if (fields.signedRenewalInfo !== undefined) {
      if (typeof fields.signedRenewalInfo !== "string") throw new Refusal("notification-invalid", "renewal field");
      signedRenewalInfo = fields.signedRenewalInfo;
    }
  }
  return {
    notificationType,
    subtype,
    notificationUUID,
    signedDate: payload.signedDate as number,
    environment,
    signedTransactionInfo,
    signedRenewalInfo,
  };
}

function trustFor(context: VerifyContext): Trust {
  // Whatever the caller passes, only `dev` may trust an Xcode certificate.
  if (context.settings.environment !== "dev") return { appleRoots: context.trust.appleRoots };
  return context.trust;
}

function jsonObject(bytes: Uint8Array, what: string): Record<string, unknown> {
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes));
  } catch {
    throw new Error(`jws: ${what} is not JSON`);
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error(`jws: ${what} is not an object`);
  return value as Record<string, unknown>;
}

function transactionIdField(value: unknown): string | undefined {
  return typeof value === "string" && /^[0-9]{1,40}$/.test(value) ? value : undefined;
}

function isTime(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value > 0;
}

/** A short reason for the log. Never the payload itself. */
export function reason(error: unknown): string {
  return error instanceof Error ? error.message.slice(0, 120) : "unknown";
}
