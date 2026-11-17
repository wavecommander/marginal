// Accounts and sign-in: signing in with Apple or Google, changing the sign-in, signing out, the
// account screen, deleting the account, and Apple's sign-in notifications. Every endpoint here
// except the notifications is attested (challenge and App Attest, as for a session).

import { revokeAppleAuthorization } from "./appleSignIn";
import { fromBase64 } from "./bytes";
import type { AccountResponse, DeleteAccountResponse, DeviceInfo, SignInResponse, SignOutResponse } from "./contract";
import * as db from "./db";
import type { Env, Settings } from "./env";
import { Refusal, json, optionalStringField, readJsonBody, stringField } from "./http";
import { identityHash, newAccountId, newFolderKey, newSessionId, newSessionToken, sessionTokenHash, type Provider } from "./identity";
import { audiencesFor, nonceFor, verifyAppleSignInNotification, verifyIdToken } from "./idToken";
import { logEvent, shortKey } from "./log";
import { authenticate, requireSession, sessionTokenField } from "./requestAuth";
import { deleteBudget, type Deps } from "./service";
import { emptyAccountFolders, folderFor } from "./storage";
import { accessAt, allowanceFor, primaryOf, subscriptionInfo } from "./subscription";
import { currentUsage } from "./usage";

const MAX_ID_TOKEN = 8 * 1024;
const MAX_AUTHORIZATION_CODE = 1024;
const MAX_DEVICE_LABEL = 1024;

// ---------------------------------------------------------------------------------------------
// Signing in

export async function signIn(provider: Provider, request: Request, env: Env, settings: Settings, deps: Deps): Promise<Response> {
  const { fields, challenge, attestKeyId } = await authenticate(request, env, settings, deps, provider === "apple" ? "auth-apple" : "auth-google", (body) => {
    // Google not configured: refuse before the challenge is spent.
    audiencesFor(provider, settings);
    return {
      idToken: stringField(body, "idToken", MAX_ID_TOKEN),
      authorizationCode: provider === "apple" ? optionalStringField(body, "authorizationCode", MAX_AUTHORIZATION_CODE) : undefined,
      deviceLabel: deviceLabelField(body),
    };
  });
  const { subject } = await verifyIdToken(fields.idToken, provider, await nonceFor(challenge), settings, { jwks: deps.jwks, now: deps.now() });
  const hash = await identityHash(settings.identityKeySecret, provider, subject);
  const now = deps.now().getTime();

  let account = await db.getAccountByIdentity(env.DB, hash);
  let newAccount = false;
  if (!account) {
    const created: db.Account = {
      accountId: newAccountId(),
      folderKey: newFolderKey(),
      provider,
      identityHash: hash,
      appAccountToken: crypto.randomUUID().toLowerCase(),
      createdAt: now,
      identityChangedAt: now,
      deletingSince: null,
    };
    newAccount = await db.insertAccount(env.DB, created);
    // Lost a race with another first sign-in of the same identity: use the account it made.
    account = newAccount ? created : await db.getAccountByIdentity(env.DB, hash);
    if (!account) throw new Error("sign-in: account neither created nor found");
  }
  if (account.deletingSince !== null) throw new Refusal("account-deleting", "account is being deleted");

  const token = newSessionToken();
  const session: db.DeviceSession = { sessionId: newSessionId(), accountId: account.accountId, attestKeyId, label: fields.deviceLabel ?? null, createdAt: now, lastUsedAt: now };
  await db.insertSession(env.DB, session, await sessionTokenHash(token));
  logEvent("signed-in", { provider, account: shortKey(account.accountId), newAccount });
  const body: SignInResponse = {
    deviceSessionToken: token,
    sessionId: session.sessionId,
    newAccount,
    account: await accountResponse(env, settings, deps, account, session.sessionId),
  };
  return json(200, body);
}

// ---------------------------------------------------------------------------------------------
// Changing the sign-in

export async function changeSignIn(request: Request, env: Env, settings: Settings, deps: Deps): Promise<Response> {
  const { fields, challenge, attestKeyId } = await authenticate(request, env, settings, deps, "auth-change", (body) => {
    const newProvider = stringField(body, "newProvider", 16);
    if (newProvider !== "apple" && newProvider !== "google") throw new Refusal("bad-request", "field newProvider");
    return {
      token: sessionTokenField(body),
      currentIdToken: stringField(body, "currentIdToken", MAX_ID_TOKEN),
      currentAuthorizationCode: optionalStringField(body, "currentAuthorizationCode", MAX_AUTHORIZATION_CODE),
      newProvider: newProvider as Provider,
      newIdToken: stringField(body, "newIdToken", MAX_ID_TOKEN),
    };
  });
  const { session, account } = await requireSession(env, deps, fields.token, attestKeyId);
  if (fields.newProvider === account.provider) throw new Refusal("bad-request", "already this provider");
  if (account.provider === "apple" && fields.currentAuthorizationCode === undefined) {
    throw new Refusal("bad-request", "field currentAuthorizationCode");
  }
  const nonce = await nonceFor(challenge);
  const context = { jwks: deps.jwks, now: deps.now() };

  // 1. Proof from the current sign-in.
  const current = await verifyIdToken(fields.currentIdToken, account.provider, nonce, settings, context);
  if ((await identityHash(settings.identityKeySecret, account.provider, current.subject)) !== account.identityHash) {
    throw new Refusal("identity-mismatch", "current ID token is not this account's");
  }
  // 2. The new sign-in.
  const next = await verifyIdToken(fields.newIdToken, fields.newProvider, nonce, settings, context);
  const nextHash = await identityHash(settings.identityKeySecret, fields.newProvider, next.subject);
  if (await db.getAccountByIdentity(env.DB, nextHash)) throw new Refusal("identity-in-use", "new identity has an account");

  // 3. The swap, in one statement: never two identities, never none.
  const outcome = await db.changeIdentity(env.DB, account.accountId, account.identityHash, fields.newProvider, nextHash, deps.now().getTime());
  if (outcome === "in-use") throw new Refusal("identity-in-use", "new identity has an account");
  if (outcome === "stale") throw new Refusal("identity-mismatch", "account changed meanwhile");
  logEvent("sign-in-changed", { account: shortKey(account.accountId), from: account.provider, to: fields.newProvider });

  // 4. Leaving Apple: revoke the authorization it gave. Never undoes the change.
  if (account.provider === "apple") {
    await revokeAppleAuthorization(fields.currentAuthorizationCode!, settings, deps.fetch, deps.now(), "sign-in-changed");
  }
  const changed: db.Account = { ...account, provider: fields.newProvider, identityHash: nextHash };
  return json(200, await accountResponse(env, settings, deps, changed, session.sessionId));
}

// ---------------------------------------------------------------------------------------------
// Signing out

export async function signOut(request: Request, env: Env, settings: Settings, deps: Deps): Promise<Response> {
  const { fields, attestKeyId } = await authenticate(request, env, settings, deps, "auth-signout", (body) => sessionTokenField(body));
  const { session, account } = await requireSession(env, deps, fields, attestKeyId, { allowDeleting: true });
  const ended = await db.deleteSession(env.DB, session.sessionId);
  logEvent("signed-out", { account: shortKey(account.accountId), sessions: ended });
  const body: SignOutResponse = { ok: true, endedSessions: ended };
  return json(200, body);
}

export async function signOutAll(request: Request, env: Env, settings: Settings, deps: Deps): Promise<Response> {
  const { fields, attestKeyId } = await authenticate(request, env, settings, deps, "auth-signout-all", (body) => sessionTokenField(body));
  const { account } = await requireSession(env, deps, fields, attestKeyId, { allowDeleting: true });
  const ended = await db.deleteAccountSessions(env.DB, account.accountId);
  logEvent("signed-out-everywhere", { account: shortKey(account.accountId), sessions: ended });
  const body: SignOutResponse = { ok: true, endedSessions: ended };
  return json(200, body);
}

// ---------------------------------------------------------------------------------------------
// The account screen

export async function getAccount(request: Request, env: Env, settings: Settings, deps: Deps): Promise<Response> {
  const { fields, attestKeyId } = await authenticate(request, env, settings, deps, "account", (body) => ({
    token: sessionTokenField(body),
    deviceLabel: deviceLabelField(body),
  }));
  const { session, account } = await requireSession(env, deps, fields.token, attestKeyId);
  if (fields.deviceLabel !== undefined) await db.setSessionLabel(env.DB, session.sessionId, fields.deviceLabel);
  return json(200, await accountResponse(env, settings, deps, account, session.sessionId));
}

async function accountResponse(env: Env, settings: Settings, deps: Deps, account: db.Account, currentSessionId: string): Promise<AccountResponse> {
  const now = deps.now().getTime();
  const iso = (ms: number) => new Date(ms).toISOString();
  const devices: DeviceInfo[] = (await db.listSessions(env.DB, account.accountId)).map((session) => ({
    sessionId: session.sessionId,
    createdAt: iso(session.createdAt),
    lastUsedAt: iso(session.lastUsedAt),
    label: session.label,
    current: session.sessionId === currentSessionId,
  }));
  const primary = primaryOf(await db.listSubscribers(env.DB, account.accountId), now, settings);
  let subscription: AccountResponse["subscription"] = null;
  let usage: AccountResponse["usage"] = null;
  if (primary) {
    subscription = subscriptionInfo(primary, accessAt(primary, now, settings), settings);
    const counted = await currentUsage(env, primary, folderFor(account.folderKey, primary.namespace), now, settings);
    const allowance = allowanceFor(primary, settings);
    usage = { bytes: counted.bytes, allowanceBytes: allowance, overAllowance: counted.bytes > allowance || !counted.complete, countedAt: iso(counted.countedAt) };
  }
  return {
    accountId: account.accountId,
    provider: account.provider,
    appAccountToken: account.appAccountToken,
    createdAt: iso(account.createdAt),
    devices,
    subscription,
    usage,
  };
}

// ---------------------------------------------------------------------------------------------
// Deleting the account

export async function deleteAccount(request: Request, env: Env, settings: Settings, deps: Deps): Promise<Response> {
  const { fields, challenge, attestKeyId } = await authenticate(request, env, settings, deps, "account-delete", (body) => ({
    token: sessionTokenField(body),
    idToken: optionalStringField(body, "idToken", MAX_ID_TOKEN),
    authorizationCode: optionalStringField(body, "authorizationCode", MAX_AUTHORIZATION_CODE),
  }));
  const { session, account } = await requireSession(env, deps, fields.token, attestKeyId, { allowDeleting: true });

  if (account.deletingSince === null) {
    // The first call: proof from the current sign-in, then the point of no return.
    if (fields.idToken === undefined) throw new Refusal("bad-request", "field idToken");
    if (account.provider === "apple" && fields.authorizationCode === undefined) throw new Refusal("bad-request", "field authorizationCode");
    const proof = await verifyIdToken(fields.idToken, account.provider, await nonceFor(challenge), settings, { jwks: deps.jwks, now: deps.now() });
    if ((await identityHash(settings.identityKeySecret, account.provider, proof.subject)) !== account.identityHash) {
      throw new Refusal("identity-mismatch", "ID token is not this account's");
    }
    await db.markAccountDeleting(env.DB, account.accountId, deps.now().getTime());
    // Other devices stop now; this one keeps its session until the deletion is done.
    await db.deleteAccountSessions(env.DB, account.accountId, session.sessionId);
    logEvent("account-deletion-started", { account: shortKey(account.accountId) });
    if (account.provider === "apple") {
      await revokeAppleAuthorization(fields.authorizationCode!, settings, deps.fetch, deps.now(), "account-deleted");
    }
  }

  const result = await emptyAccountFolders(env.BUCKET, account.folderKey, deleteBudget(deps));
  if (result.done) {
    await db.removeAccount(env.DB, account.accountId);
    logEvent("account-deleted", { account: shortKey(account.accountId), by: "app" });
  }
  const body: DeleteAccountResponse = { done: result.done, deletedObjects: result.deleted };
  return json(200, body);
}

// ---------------------------------------------------------------------------------------------
// Sign in with Apple server-to-server notifications

/** Events that end every session of the Apple identity's account. The data is kept. */
const ENDING_EVENTS = new Set(["consent-revoked", "account-delete"]);

export async function signInNotification(request: Request, env: Env, settings: Settings, deps: Deps): Promise<Response> {
  const { value } = await readJsonBody(request);
  const payload = stringField(value, "payload", MAX_ID_TOKEN);
  const event = await verifyAppleSignInNotification(payload, settings, { jwks: deps.jwks, now: deps.now() });
  let outcome = "ignored-type";
  if (ENDING_EVENTS.has(event.type)) {
    const account = await db.getAccountByIdentity(env.DB, await identityHash(settings.identityKeySecret, "apple", event.subject));
    if (account) {
      const ended = await db.deleteAccountSessions(env.DB, account.accountId);
      outcome = `sessions-ended:${ended}`;
    } else {
      outcome = "ignored-unknown-identity";
    }
  }
  logEvent("signin-notification", { type: event.type, outcome });
  return json(200, { ok: true });
}

function deviceLabelField(body: Record<string, unknown>): string | undefined {
  const label = optionalStringField(body, "deviceLabel", MAX_DEVICE_LABEL);
  if (label === undefined) return undefined;
  try {
    fromBase64(label);
  } catch {
    throw new Refusal("bad-request", "field deviceLabel");
  }
  return label;
}
