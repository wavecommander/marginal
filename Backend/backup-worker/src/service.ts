// The endpoints and the daily cron. `index.ts` wires these to the Workers runtime; tests call
// them directly with their own clock, roots of trust, key sets and outbound fetch.

import { changeSignIn, deleteAccount, finishAccountDeletion, getAccount, signIn, signInNotification, signOut, signOutAll } from "./accounts";
import { APPLE_APP_ATTESTATION_ROOT_CA, APPLE_ROOT_CA_G3 } from "./appleRoots";
import { reason, verifyNotification, verifyRenewalInfo, verifyTransaction, type RenewalInfo, type Transaction, type VerifyContext } from "./appleJws";
import { attestPolicy, verifyAttestation } from "./appAttest";
import { fromBase64, hex, randomBytes, sha256, toBase64 } from "./bytes";
import type { AttestResponse, ChallengeResponse, DeleteMyDataResponse, HealthResponse, SessionResponse } from "./contract";
import * as db from "./db";
import { bindSubscription, recordNotification } from "./entitlement";
import { readSettings, type Env, type Settings } from "./env";
import { Refusal, json, optionalStringField, problem, readJsonBody, stringField } from "./http";
import { JwksCache, type JwksSource, type OutboundFetch } from "./idToken";
import { logError, logEvent, shortKey } from "./log";
import { CHALLENGE_BYTES, authenticate, requireSession, sessionTokenField, useChallenge } from "./requestAuth";
import { deleteFolder, emptyAccountFolders, folderFor } from "./storage";
import { DAY_MS, accessAt, allowanceFor, primaryOf, subscriptionInfo, type Subscriber } from "./subscription";
import { ACTIONS, createTempCredentials, type AccessMode } from "./tempCredentials";
import { currentUsage } from "./usage";

/** What tests replace: the clock, the roots of trust, the providers' key sets and outbound requests. */
export interface Deps {
  now(): Date;
  /** DER of the roots trusted for App Store JWS (Apple Root CA - G3). */
  appleRoots: Uint8Array[];
  /** DER of the roots trusted for App Attest (Apple App Attestation Root CA). */
  appAttestRoots: Uint8Array[];
  /** Apple's and Google's sign-in key sets. */
  jwks: JwksSource;
  /** Outbound requests to Apple's token and revoke endpoints. */
  fetch: OutboundFetch;
  /** R2 operations one delete-my-data or account-delete call may spend (two per 1,000 objects). */
  deleteRequestBudget?: number;
  /** R2 operations one cron run may spend. */
  cronBudget?: number;
}

const outboundFetch: OutboundFetch = (url, init) => fetch(url, init);
/** One key-set cache per isolate, shared by its requests. */
const sharedJwks = new JwksCache(outboundFetch);

export function defaultDeps(): Deps {
  return {
    now: () => new Date(),
    appleRoots: [fromBase64(APPLE_ROOT_CA_G3)],
    appAttestRoots: [fromBase64(APPLE_APP_ATTESTATION_ROOT_CA)],
    jwks: sharedJwks,
    fetch: outboundFetch,
  };
}

const CHALLENGE_TTL_MS = 5 * 60_000;
/** Default R2 operations one delete call may spend: up to 100,000 objects. */
export const DELETE_REQUEST_BUDGET = 200;
/** Below this a call deleting two folders might not make progress (see `emptyAccountFolders`). */
export const MIN_DELETE_BUDGET = 3;
/**
 * Default R2 operations one cron run may spend: up to 300,000 objects, inside even the Workers
 * Free plan's 1,000 subrequests to Cloudflare services per invocation, D1 queries included.
 */
const CRON_BUDGET = 600;
/** Subscriptions the cron looks at per run, at most. */
const CRON_MAX_CANDIDATES = 2000;
/** Account deletions the cron finishes per run, at most. */
const CRON_MAX_ACCOUNT_DELETIONS = 50;
/** The cron leaves an account deletion this long to the app before finishing it itself. */
const ACCOUNT_DELETION_GRACE_MS = 15 * 60_000;

export type Handler = (request: Request, env: Env, settings: Settings, deps: Deps) => Promise<Response>;

const ROUTES: Record<string, Partial<Record<string, Handler>>> = {
  "/v1/health": { GET: health },
  "/v1/challenge": { POST: challenge },
  "/v1/attest": { POST: attest },
  "/v1/auth/apple": { POST: (request, env, settings, deps) => signIn("apple", request, env, settings, deps) },
  "/v1/auth/google": { POST: (request, env, settings, deps) => signIn("google", request, env, settings, deps) },
  "/v1/auth/change": { POST: changeSignIn },
  "/v1/auth/signout": { POST: signOut },
  "/v1/auth/signout-all": { POST: signOutAll },
  "/v1/account": { POST: getAccount },
  "/v1/account/delete": { POST: deleteAccount },
  "/v1/session": { POST: session },
  "/v1/delete-my-data": { POST: deleteMyData },
  "/v1/apple/notifications": { POST: appleNotification },
  "/v1/apple/signin-notifications": { POST: signInNotification },
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
  const { fields, attestKeyId } = await authenticate(request, env, settings, deps, "session", (body) => {
    const signedTransaction = optionalStringField(body, "signedTransaction", 32 * 1024);
    const signedRenewalInfo = optionalStringField(body, "signedRenewalInfo", 32 * 1024);
    if (signedRenewalInfo !== undefined && signedTransaction === undefined) throw new Refusal("bad-request", "renewal info without a transaction");
    return { token: sessionTokenField(body), signedTransaction, signedRenewalInfo };
  });
  const { account } = await requireSession(env, deps, fields.token, attestKeyId);
  const now = deps.now().getTime();

  let subscriber: Subscriber | undefined;
  if (fields.signedTransaction !== undefined) {
    const { transaction, renewal } = await verifySubscription(fields.signedTransaction, fields.signedRenewalInfo, settings, deps);
    subscriber = await bindSubscription(env.DB, settings, account, transaction, renewal, now);
  } else {
    subscriber = primaryOf(await db.listSubscribers(env.DB, account.accountId), now, settings);
  }
  if (!subscriber) throw new Refusal("not-subscribed", "no entitlement");

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

  const folder = folderFor(account.folderKey, subscriber.namespace);
  const allowance = allowanceFor(subscriber, settings);
  const usage = await currentUsage(env, subscriber, folder, now, settings);
  const overAllowance = usage.bytes > allowance || !usage.complete;
  const mode: AccessMode = access.kind === "read-only" ? "read-only" : overAllowance ? "read-delete" : "read-write";

  // Look again right before minting: an account deletion may have started during the steps
  // above. From here to the credentials there is no more I/O, so any credential minted is from
  // before the deletion started, which is what the deleted folder's purge time allows for.
  const current = await db.getAccount(env.DB, account.accountId);
  if (!current) throw new Refusal("session-invalid", "account removed during the request");
  if (current.deletingSince !== null) throw new Refusal("account-deleting", "deletion started during the request");

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
  logEvent("session", { account: shortKey(account.accountId), mode, environment: subscriber.environment });
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
  const { fields, attestKeyId } = await authenticate(request, env, settings, deps, "delete-my-data", (body) => sessionTokenField(body));
  const { account } = await requireSession(env, deps, fields, attestKeyId);
  const result = await emptyAccountFolders(env.BUCKET, account.folderKey, deleteBudget(deps));
  if (result.done) await db.resetUsage(env.DB, account.accountId, deps.now().getTime());
  logEvent("delete-my-data", { account: shortKey(account.accountId), done: result.done, deleted: result.deleted });
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
  const subscriber = await recordNotification(env.DB, settings, transaction, renewal, deps.now().getTime());
  if (!subscriber) return ack("ignored-unknown-subscription");
  return ack("applied");
}

// ---------------------------------------------------------------------------------------------
// The daily cron

export interface CronResult {
  challengesRemoved: number;
  /** Account deletions the app left unfinished, finished here. */
  accountsRemoved: number;
  /** Deleted accounts' folders emptied for the last time and forgotten. */
  foldersPurged: number;
  foldersEmptied: number;
  objectsDeleted: number;
  /** True when the budget ran out with work left; the next run continues. */
  unfinished: boolean;
}

export async function runScheduled(env: Env, deps: Deps): Promise<CronResult> {
  const settings = readSettings(env);
  const now = deps.now().getTime();
  const result: CronResult = { challengesRemoved: 0, accountsRemoved: 0, foldersPurged: 0, foldersEmptied: 0, objectsDeleted: 0, unfinished: false };
  result.challengesRemoved = await db.deleteExpiredChallenges(env.DB, now);
  const budget = { operations: deps.cronBudget ?? CRON_BUDGET };

  // Account deletions the app started and did not finish.
  for (const account of await db.accountsBeingDeleted(env.DB, now - ACCOUNT_DELETION_GRACE_MS, CRON_MAX_ACCOUNT_DELETIONS)) {
    if (budget.operations < MIN_DELETE_BUDGET) {
      result.unfinished = true;
      break;
    }
    const deletion = await emptyAccountFolders(env.BUCKET, account.folderKey, budget);
    result.objectsDeleted += deletion.deleted;
    if (!deletion.done) {
      result.unfinished = true;
      break;
    }
    await finishAccountDeletion(env, settings, account, account.deletingSince ?? now, now, "cron");
    result.accountsRemoved++;
  }

  // Deleted accounts' folders, once every credential minted for them has expired: emptied once
  // more (credentials minted before the deletion may have written to them), then forgotten.
  if (!result.unfinished) {
    for (const folderKey of await db.foldersToPurge(env.DB, now, CRON_MAX_ACCOUNT_DELETIONS)) {
      if (budget.operations < MIN_DELETE_BUDGET) {
        result.unfinished = true;
        break;
      }
      const purge = await emptyAccountFolders(env.BUCKET, folderKey, budget);
      result.objectsDeleted += purge.deleted;
      if (!purge.done) {
        result.unfinished = true;
        break;
      }
      await db.forgetDeletedFolder(env.DB, folderKey, now);
      result.foldersPurged++;
    }
  }

  // The lapse policy.
  const cutoff = now - settings.deleteAfterDays * DAY_MS;
  let after = { accountId: "", namespace: "" };
  let examined = 0;
  outer: while (!result.unfinished && examined < CRON_MAX_CANDIDATES) {
    const candidates = await db.deletionCandidates(env.DB, cutoff, after, 50);
    if (candidates.length === 0) break;
    for (const { subscriber, folderKey } of candidates) {
      after = { accountId: subscriber.accountId, namespace: subscriber.namespace };
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
      const folder = folderFor(folderKey, subscriber.namespace);
      const deletion = await deleteFolder(env.BUCKET, folder, budget);
      result.objectsDeleted += deletion.deleted;
      if (!deletion.done) {
        result.unfinished = true;
        break outer;
      }
      if (await db.markDataDeleted(env.DB, subscriber.accountId, subscriber.namespace, subscriber.version, now)) result.foldersEmptied++;
      logEvent("lapsed-data-deleted", { account: shortKey(subscriber.accountId), objects: deletion.deleted });
    }
  }
  if (examined >= CRON_MAX_CANDIDATES) result.unfinished = true;
  logEvent("cron", { ...result });
  return result;
}

// ---------------------------------------------------------------------------------------------
// Shared steps

export function verifyContext(settings: Settings, deps: Deps): VerifyContext {
  return {
    settings,
    trust: { appleRoots: deps.appleRoots, xcodeRoot: settings.xcodeStoreKitCert },
    now: deps.now(),
  };
}

/** Verifies the app's signed transaction and, if sent, its renewal info for the same subscription. */
async function verifySubscription(
  signedTransaction: string,
  signedRenewalInfo: string | undefined,
  settings: Settings,
  deps: Deps,
): Promise<{ transaction: Transaction; renewal: RenewalInfo | undefined }> {
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

export function deleteBudget(deps: Deps): { operations: number } {
  return { operations: Math.max(MIN_DELETE_BUDGET, deps.deleteRequestBudget ?? DELETE_REQUEST_BUDGET) };
}

function decodeBase64Field(text: string, name: string): Uint8Array {
  try {
    return fromBase64(text);
  } catch {
    throw new Refusal("bad-request", `${name} is not base64`);
  }
}
