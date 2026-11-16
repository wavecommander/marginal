// The endpoints and the daily cron. `index.ts` wires these to the Workers runtime; tests call
// them directly with their own clock and trusted roots.

import { APPLE_APP_ATTESTATION_ROOT_CA, APPLE_ROOT_CA_G3 } from "./appleRoots";
import { reason, verifyNotification, verifyRenewalInfo, verifyTransaction, type AppleEnvironment, type RenewalInfo, type Transaction, type VerifyContext } from "./appleJws";
import { attestPolicy, verifyAssertion, verifyAttestation } from "./appAttest";
import { equalStrings, fromBase64, hex, randomBytes, sha256, toBase64 } from "./bytes";
import { AUTH_HEADERS, type AttestResponse, type ChallengeResponse, type DeleteMyDataResponse, type HealthResponse, type SessionResponse } from "./contract";
import * as db from "./db";
import { readSettings, type Env, type Settings } from "./env";
import { Refusal, json, optionalStringField, problem, readJsonBody, stringField } from "./http";
import { logError, logEvent, shortKey } from "./log";
import { countUsage, deleteFolder, folderFor } from "./storage";
import { DAY_MS, accessAt, allowanceFor, applyRenewalInfo, applyTransaction, newSubscriber, subscriptionInfo, type Subscriber } from "./subscription";
import { ACTIONS, createTempCredentials, type AccessMode } from "./tempCredentials";
import { userKey } from "./userKey";

/** What tests replace: the clock and the roots of trust. */
export interface Deps {
  now(): Date;
  /** DER of the roots trusted for App Store JWS (Apple Root CA - G3). */
  appleRoots: Uint8Array[];
  /** DER of the roots trusted for App Attest (Apple App Attestation Root CA). */
  appAttestRoots: Uint8Array[];
  /** R2 operations one delete-my-data call may spend (two per 1,000 objects). */
  deleteRequestBudget?: number;
  /** R2 operations one cron run may spend. */
  cronBudget?: number;
}

export function defaultDeps(): Deps {
  return {
    now: () => new Date(),
    appleRoots: [fromBase64(APPLE_ROOT_CA_G3)],
    appAttestRoots: [fromBase64(APPLE_APP_ATTESTATION_ROOT_CA)],
  };
}

const CHALLENGE_BYTES = 32;
const CHALLENGE_TTL_MS = 5 * 60_000;
/** Default R2 operations one delete-my-data call may spend: up to 100,000 objects. */
const DELETE_REQUEST_BUDGET = 200;
/**
 * Default R2 operations one cron run may spend: up to 300,000 objects, inside even the Workers
 * Free plan's 1,000 subrequests to Cloudflare services per invocation, D1 queries included.
 */
const CRON_BUDGET = 600;
/** Subscriptions the cron looks at per run, at most. */
const CRON_MAX_CANDIDATES = 2000;

type Handler = (request: Request, env: Env, settings: Settings, deps: Deps) => Promise<Response>;

const ROUTES: Record<string, Partial<Record<string, Handler>>> = {
  "/v1/health": { GET: health },
  "/v1/challenge": { POST: challenge },
  "/v1/attest": { POST: attest },
  "/v1/session": { POST: session },
  "/v1/delete-my-data": { POST: deleteMyData },
  "/v1/apple/notifications": { POST: appleNotification },
};

export async function handle(request: Request, env: Env, deps: Deps): Promise<Response> {
  const path = new URL(request.url).pathname;
  const route = ROUTES[path];
  if (!route) return problem("not-found");
  const handler = route[request.method];
  if (!handler) return problem("method-not-allowed", undefined, { allow: Object.keys(route).join(", ") });
  let settings: Settings;
  try {
    settings = readSettings(env);
  } catch (error) {
    // The message names the setting, never its value.
    logError("settings-invalid", { reason: reason(error) });
    return problem("internal");
  }
  try {
    return await handler(request, env, settings, deps);
  } catch (error) {
    if (error instanceof Refusal) {
      logEvent("refused", { path, code: error.code, reason: error.detail });
      return problem(error.code, error.subscription);
    }
    // Never echo an internal error to a client: it could carry a secret or a stack.
    logError("unhandled", { path, reason: reason(error) });
    return problem("internal");
  }
}

// ---------------------------------------------------------------------------------------------

async function health(_request: Request, _env: Env, settings: Settings): Promise<Response> {
  const body: HealthResponse = { ok: true, environment: settings.environment };
  return json(200, body);
}

async function challenge(request: Request, env: Env, _settings: Settings, deps: Deps): Promise<Response> {
  const { value } = await readJsonBody(request, true);
  if (Object.keys(value).length !== 0) throw new Refusal("bad-request", "challenge takes no fields");
  const now = deps.now().getTime();
  const bytes = randomBytes(CHALLENGE_BYTES);
  const expiresAt = now + CHALLENGE_TTL_MS;
  await db.storeChallenge(env.DB, hex(await sha256(bytes)), expiresAt, now);
  const body: ChallengeResponse = { challenge: toBase64(bytes), expiresAt: new Date(expiresAt).toISOString() };
  return json(200, body);
}

async function attest(request: Request, env: Env, settings: Settings, deps: Deps): Promise<Response> {
  const { value } = await readJsonBody(request);
  const keyIdText = stringField(value, "keyId", 64);
  const challengeText = stringField(value, "challenge", 64);
  const attestationText = stringField(value, "attestation", 48 * 1024);
  const keyId = decodeBase64Field(keyIdText, "keyId");
  if (keyId.length !== 32) throw new Refusal("bad-request", "keyId length");
  const attestation = decodeBase64Field(attestationText, "attestation");
  const challengeBytes = await useChallenge(env, challengeText, deps);

  let verified;
  try {
    verified = await verifyAttestation({
      attestation,
      keyId,
      clientDataHash: await sha256(challengeBytes),
      roots: deps.appAttestRoots,
      policy: attestPolicy(settings.environment, settings.appId),
      now: deps.now(),
    });
  } catch (error) {
    throw new Refusal("attestation-invalid", reason(error));
  }
  const stored = await db.insertDevice(env.DB, keyIdText, { publicKey: verified.publicKey, counter: 0, environment: verified.environment }, deps.now().getTime());
  if (!stored) throw new Refusal("device-already-attested", "key already registered");
  logEvent("device-attested", { environment: verified.environment });
  const body: AttestResponse = { keyId: keyIdText, environment: verified.environment };
  return json(201, body);
}

async function session(request: Request, env: Env, settings: Settings, deps: Deps): Promise<Response> {
  const { transaction, renewal } = await authenticate(request, env, settings, deps, "session");
  const now = deps.now().getTime();
  const key = await userKeyFor(settings, transaction);
  const subscriber = await recordSubscription(env.DB, key, transaction, renewal, now, settings, true);
  if (!subscriber) throw new Error("session: subscriber not recorded");
  const access = accessAt(subscriber, now, settings);
  const info = subscriptionInfo(subscriber, access, settings);

  switch (access.kind) {
    case "revoked":
      throw new Refusal("subscription-revoked", "revoked", info);
    case "data-deleted":
    case "deletion-due":
      throw new Refusal("data-deleted", access.kind, info);
    case "lapsed":
      throw new Refusal("subscription-lapsed", "lapsed", info);
  }

  const folder = folderFor(key, subscriber.environment);
  const allowance = allowanceFor(subscriber, settings);
  const usage = await currentUsage(env, subscriber, folder, now, settings);
  const overAllowance = usage.bytes > allowance || !usage.complete;
  const mode: AccessMode = access.kind === "read-only" ? "read-only" : overAllowance ? "read-delete" : "read-write";

  const credentials = await createTempCredentials({
    accountId: settings.r2.accountId,
    s3Host: settings.r2.s3Host,
    bucket: settings.r2.bucket,
    parentAccessKeyId: settings.r2.parentAccessKeyId,
    parentSecretAccessKey: settings.r2.parentSecretAccessKey,
    actions: ACTIONS[mode],
    prefixes: [folder],
    ttlSeconds: settings.credentialTTLSeconds,
    now: new Date(now),
  });
  logEvent("session", { user: shortKey(key), mode, environment: subscriber.environment });
  const body: SessionResponse = {
    mode,
    credentials,
    storage: {
      endpoint: `https://${settings.r2.s3Host}`,
      host: settings.r2.s3Host,
      region: "auto",
      bucket: settings.r2.bucket,
      prefix: folder,
    },
    subscription: info,
    usage: {
      bytes: usage.bytes,
      allowanceBytes: allowance,
      overAllowance,
      countedAt: new Date(usage.countedAt).toISOString(),
    },
  };
  return json(200, body);
}

async function deleteMyData(request: Request, env: Env, settings: Settings, deps: Deps): Promise<Response> {
  const { transaction } = await authenticate(request, env, settings, deps, "delete-my-data");
  const key = await userKeyFor(settings, transaction);
  const folder = folderFor(key, transaction.environment);
  const result = await deleteFolder(env.BUCKET, folder, { operations: deps.deleteRequestBudget ?? DELETE_REQUEST_BUDGET });
  if (result.done) await db.deleteSubscriber(env.DB, key);
  logEvent("delete-my-data", { user: shortKey(key), done: result.done, deleted: result.deleted });
  const body: DeleteMyDataResponse = { done: result.done, deletedObjects: result.deleted };
  return json(200, body);
}

/** Notification types that change what a subscription allows. Everything else is acknowledged and ignored. */
const HANDLED_NOTIFICATIONS = new Set([
  "SUBSCRIBED",
  "DID_RENEW",
  "DID_CHANGE_RENEWAL_PREF",
  "DID_CHANGE_RENEWAL_STATUS",
  "OFFER_REDEEMED",
  "DID_FAIL_TO_RENEW",
  "GRACE_PERIOD_EXPIRED",
  "EXPIRED",
  "REFUND",
  "REFUND_REVERSED",
  "REVOKE",
  "RENEWAL_EXTENDED",
]);

async function appleNotification(request: Request, env: Env, settings: Settings, deps: Deps): Promise<Response> {
  const { value } = await readJsonBody(request);
  const signedPayload = stringField(value, "signedPayload", 60 * 1024);
  const context = verifyContext(settings, deps);
  const notification = await verifyNotification(signedPayload, context);
  const ack = (outcome: string) => {
    logEvent("notification", { type: notification.notificationType, subtype: notification.subtype, outcome });
    return json(200, { ok: true });
  };
  // Partial refunds of multi-seat purchases (REFUND / SEATS) do not apply to this service's products.
  if (!HANDLED_NOTIFICATIONS.has(notification.notificationType) || (notification.notificationType === "REFUND" && notification.subtype !== undefined)) {
    return ack("ignored-type");
  }
  if (!notification.signedTransactionInfo) return ack("ignored-no-transaction");

  let transaction: Transaction;
  let renewal: RenewalInfo | undefined;
  try {
    transaction = await verifyTransaction(notification.signedTransactionInfo, context);
    if (notification.signedRenewalInfo) renewal = await verifyRenewalInfo(notification.signedRenewalInfo, context);
  } catch (error) {
    if (error instanceof Refusal && error.code === "product-unknown") return ack("ignored-product");
    throw new Refusal("notification-invalid", error instanceof Refusal ? error.detail : reason(error));
  }
  if (transaction.environment !== notification.environment) throw new Refusal("notification-invalid", "environments differ");
  if (renewal && (renewal.originalTransactionId !== transaction.originalTransactionId || renewal.environment !== transaction.environment)) {
    throw new Refusal("notification-invalid", "renewal info is for another subscription");
  }
  const key = await userKeyFor(settings, transaction);
  const now = deps.now().getTime();
  const subscriber = await recordSubscription(env.DB, key, transaction, renewal, now, settings, false);
  if (!subscriber) return ack("ignored-unknown-subscription");
  return ack("applied");
}

// ---------------------------------------------------------------------------------------------
// The daily cron

export interface CronResult {
  challengesRemoved: number;
  foldersEmptied: number;
  objectsDeleted: number;
  /** True when the budget ran out with work left; the next run continues. */
  unfinished: boolean;
}

export async function runScheduled(env: Env, deps: Deps): Promise<CronResult> {
  const settings = readSettings(env);
  const now = deps.now().getTime();
  const result: CronResult = { challengesRemoved: 0, foldersEmptied: 0, objectsDeleted: 0, unfinished: false };
  result.challengesRemoved = await db.deleteExpiredChallenges(env.DB, now);

  const budget = { operations: deps.cronBudget ?? CRON_BUDGET };
  const cutoff = now - settings.deleteAfterDays * DAY_MS;
  let afterKey = "";
  let examined = 0;
  outer: while (examined < CRON_MAX_CANDIDATES) {
    const candidates = await db.deletionCandidates(env.DB, cutoff, afterKey, 50);
    if (candidates.length === 0) break;
    for (const subscriber of candidates) {
      afterKey = subscriber.userKey;
      examined++;
      const access = accessAt(subscriber, now, settings);
      const due =
        access.kind === "deletion-due" ||
        (access.kind === "revoked" && now >= access.endedAt + settings.deleteAfterDays * DAY_MS);
      if (!due) continue;
      if (budget.operations < 2) {
        result.unfinished = true;
        break outer;
      }
      const folder = folderFor(subscriber.userKey, subscriber.environment);
      const deletion = await deleteFolder(env.BUCKET, folder, budget);
      result.objectsDeleted += deletion.deleted;
      if (!deletion.done) {
        result.unfinished = true;
        break outer;
      }
      if (await db.markDataDeleted(env.DB, subscriber.userKey, subscriber.version, now)) result.foldersEmptied++;
      logEvent("lapsed-data-deleted", { user: shortKey(subscriber.userKey), objects: deletion.deleted });
    }
  }
  if (examined >= CRON_MAX_CANDIDATES) result.unfinished = true;
  logEvent("cron", { ...result });
  return result;
}

// ---------------------------------------------------------------------------------------------
// Shared steps

function verifyContext(settings: Settings, deps: Deps): VerifyContext {
  return {
    settings,
    trust: { appleRoots: deps.appleRoots, xcodeRoot: settings.xcodeStoreKitCert },
    now: deps.now(),
  };
}

/**
 * Authenticates a request: its challenge (single use), its App Attest assertion over the exact
 * body (or, in `dev` only, the bypass secret) and its signed subscription.
 */
async function authenticate(
  request: Request,
  env: Env,
  settings: Settings,
  deps: Deps,
  action: "session" | "delete-my-data",
): Promise<{ transaction: Transaction; renewal: RenewalInfo | undefined }> {
  const { bytes, value } = await readJsonBody(request);
  if (stringField(value, "action", 32) !== action) throw new Refusal("bad-request", "action does not match the endpoint");
  const challengeText = stringField(value, "challenge", 64);
  const signedTransaction = stringField(value, "signedTransaction", 32 * 1024);
  const signedRenewalInfo = optionalStringField(value, "signedRenewalInfo", 32 * 1024);
  await useChallenge(env, challengeText, deps);

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
  } else {
    await checkAssertion(request, env, settings, bytes, deps);
  }

  const context = verifyContext(settings, deps);
  const transaction = await verifyTransaction(signedTransaction, context);
  let renewal: RenewalInfo | undefined;
  if (signedRenewalInfo) {
    renewal = await verifyRenewalInfo(signedRenewalInfo, context);
    if (renewal.originalTransactionId !== transaction.originalTransactionId || renewal.environment !== transaction.environment) {
      throw new Refusal("transaction-invalid", "renewal info is for another subscription");
    }
  }
  return { transaction, renewal };
}

async function checkAssertion(request: Request, env: Env, settings: Settings, body: Uint8Array, deps: Deps): Promise<void> {
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
}

async function useChallenge(env: Env, challengeText: string, deps: Deps): Promise<Uint8Array> {
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

/**
 * The user's key. Production subscriptions use the documented keyed hash; sandbox and Xcode ones
 * a separately keyed one, so a test purchase can never land on a customer's row or folder.
 */
async function userKeyFor(settings: Settings, transaction: Pick<Transaction, "originalTransactionId" | "environment">): Promise<string> {
  return userKey(namespacedSecret(settings.userKeySecret, transaction.environment), transaction.originalTransactionId);
}

function namespacedSecret(secret: string, environment: AppleEnvironment): string {
  return environment === "Production" ? secret : `${secret}\u0000${environment}`;
}

/**
 * Applies a verified transaction (and renewal info) to the stored subscription, newest wins.
 * `create`: whether to start a row for an unknown subscription (sessions do, notifications do
 * not). Returns the stored state, or null if unknown and not created.
 */
async function recordSubscription(
  database: D1Database,
  key: string,
  transaction: Transaction,
  renewal: RenewalInfo | undefined,
  now: number,
  settings: Settings,
  create: boolean,
): Promise<Subscriber | null> {
  for (let attempt = 0; attempt < 4; attempt++) {
    const existing = await db.getSubscriber(database, key);
    if (!existing && !create) return null;
    let next = existing ? applyTransaction(existing, transaction) : newSubscriber(key, transaction, now);
    if (renewal) next = applyRenewalInfo(next, renewal);
    // A resubscription after the lapse policy deleted the data starts afresh.
    if (next.dataDeletedAt !== null && accessAt(next, now, settings).kind === "active") next = { ...next, dataDeletedAt: null };
    if (existing && sameState(existing, next)) return existing;
    if (await db.saveSubscriber(database, next, existing !== null, now)) {
      return { ...next, version: next.version + 1 };
    }
  }
  throw new Error("subscriber row kept changing");
}

function sameState(a: Subscriber, b: Subscriber): boolean {
  return (
    a.productId === b.productId &&
    a.environment === b.environment &&
    a.expiresAt === b.expiresAt &&
    a.revokedAt === b.revokedAt &&
    a.inBillingRetry === b.inBillingRetry &&
    a.graceExpiresAt === b.graceExpiresAt &&
    a.billingRetryEndedAt === b.billingRetryEndedAt &&
    a.txnSignedAt === b.txnSignedAt &&
    a.renewalSignedAt === b.renewalSignedAt &&
    a.dataDeletedAt === b.dataDeletedAt
  );
}

async function currentUsage(env: Env, subscriber: Subscriber, folder: string, now: number, settings: Settings): Promise<{ bytes: number; complete: boolean; countedAt: number }> {
  if (subscriber.usageCheckedAt !== null && now - subscriber.usageCheckedAt < settings.usageCacheSeconds * 1000) {
    return { bytes: subscriber.usageBytes, complete: true, countedAt: subscriber.usageCheckedAt };
  }
  const usage = await countUsage(env.BUCKET, folder);
  if (usage.complete) {
    await db.saveUsage(env.DB, subscriber.userKey, usage.bytes, now);
  } else {
    // Too many objects to count in one go: treated as over the allowance, and not cached.
    logEvent("usage-count-incomplete", { user: shortKey(subscriber.userKey) });
  }
  return { bytes: usage.bytes, complete: usage.complete, countedAt: now };
}

function decodeBase64Field(text: string, name: string): Uint8Array {
  try {
    return fromBase64(text);
  } catch {
    throw new Refusal("bad-request", `${name} is not base64`);
  }
}
