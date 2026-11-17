// Drives the Worker inside the Workers runtime with a local D1 database and R2 bucket, a clock
// the test sets, throwaway roots of trust standing in for Apple's, generated sign-in key sets
// standing in for Apple's and Google's, and a recording stand-in for Apple's token and revoke
// endpoints.

import { env } from "cloudflare:workers";
import { ENDPOINT_ACTIONS, type SessionResponse, type SignInResponse } from "../../src/contract";
import type { Env } from "../../src/env";
import type { Provider } from "../../src/identity";
import { handle, runScheduled, type CronResult, type Deps } from "../../src/service";
import { attestPki, makeAssertion, makeAttestation, newDevice, sha256, type AttestPki, type Device } from "../helpers/attest";
import { TestJwks, devTestClaims, idTokenClaims, nonceOf, rsaSigningKey, signDevTestToken, signRs256, siwaKey, type SigningKey } from "../helpers/oidc";
import { appleLikeChain, base64, signWithChain, type AppleChain } from "../helpers/pki";
import { APP_ID, DEV_SIGNIN_SECRET, SIWA_KEY_ID, testVars } from "../helpers/settings";

/** A request the Worker sent to Apple's token or revoke endpoint. */
export interface OutboundCall {
  url: string;
  form: Record<string, string>;
}

export interface World {
  chain: AppleChain;
  pki: AttestPki;
  clock: { now: Date };
  env: Env;
  deps: Deps;
  jwks: TestJwks;
  signingKeys: Record<Provider, SigningKey>;
  /** Requests to Apple's token and revoke endpoints, in order. */
  outbound: OutboundCall[];
  /** Status Apple's endpoints answer (default 200). */
  appleStatus: { token: number; revoke: number };
}

export async function makeWorld(
  overrides: Partial<Record<keyof Env, unknown>> = {},
  depsOverrides: Partial<Deps> = {},
  bindings: Partial<Pick<Env, "BUCKET">> = {},
): Promise<World> {
  const chain = await appleLikeChain();
  const pki = await attestPki();
  const clock = { now: new Date("2026-11-15T12:00:00Z") };
  const jwks = new TestJwks();
  const signingKeys = { apple: await rsaSigningKey(), google: await rsaSigningKey() };
  jwks.visible.apple.push(signingKeys.apple.jwk);
  jwks.visible.google.push(signingKeys.google.jwk);
  const siwa = await siwaKey();
  const outbound: OutboundCall[] = [];
  const appleStatus = { token: 200, revoke: 200 };
  const fetcher = async (url: string, init?: RequestInit): Promise<Response> => {
    const form = Object.fromEntries(new URLSearchParams(String(init?.body ?? "")));
    outbound.push({ url, form });
    if (url === "https://appleid.apple.com/auth/token") {
      return new Response(JSON.stringify({ access_token: "test-access", refresh_token: `test-refresh-for-${form.code}`, token_type: "Bearer", expires_in: 3600 }), {
        status: appleStatus.token,
        headers: { "content-type": "application/json" },
      });
    }
    if (url === "https://appleid.apple.com/auth/revoke") return new Response("", { status: appleStatus.revoke });
    throw new Error(`unexpected outbound request to ${url}`);
  };
  const worldEnv = {
    ...testVars({ APPLE_SIWA_KEY_ID: SIWA_KEY_ID, APPLE_SIWA_PRIVATE_KEY: siwa.pem, ...overrides }),
    DB: env.DB,
    BUCKET: env.BUCKET,
    ...bindings,
  } as Env;
  const deps: Deps = { now: () => clock.now, appleRoots: [chain.root.der], appAttestRoots: [pki.root.der], jwks, fetch: fetcher, ...depsOverrides };
  return { chain, pki, clock, env: worldEnv, deps, jwks, signingKeys, outbound, appleStatus };
}

export function call(world: World, path: string, init: RequestInit = {}): Promise<Response> {
  return handle(new Request(`https://backup.example${path}`, init), world.env, world.deps);
}

export function postJson(world: World, path: string, body: unknown, headers: Record<string, string> = {}): Promise<Response> {
  return call(world, path, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: typeof body === "string" ? body : JSON.stringify(body) });
}

export function cron(world: World): Promise<CronResult> {
  return runScheduled(world.env, world.deps);
}

export async function newChallenge(world: World): Promise<string> {
  const response = await call(world, "/v1/challenge", { method: "POST" });
  if (response.status !== 200) throw new Error(`challenge: ${response.status}`);
  return ((await response.json()) as { challenge: string }).challenge;
}

function decode(text: string): Uint8Array {
  return Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
}

/** An app install: an attested key and its assertion counter. */
export interface Install {
  device: Device;
  keyId: string;
  counter: number;
  /** Overrides for the App ID the device signs with. */
  appId?: string;
}

export async function attestedInstall(world: World): Promise<Install> {
  const device = await newDevice();
  const challenge = await newChallenge(world);
  const attestation = await makeAttestation({ pki: world.pki, device, appId: APP_ID, clientDataHash: await sha256(decode(challenge)) });
  const response = await postJson(world, "/v1/attest", { keyId: base64(device.keyId), challenge, attestation: base64(attestation) });
  if (response.status !== 201) throw new Error(`attest: ${response.status} ${await response.text()}`);
  return { device, keyId: base64(device.keyId), counter: 0 };
}

export interface AttestedOptions {
  challenge?: string;
  /** Counter to put in the assertion (default: next). */
  counter?: number;
  extraHeaders?: Record<string, string>;
}

/**
 * POSTs an attested request: a fresh challenge (unless given), `action` for the path, the body
 * the test builds from the challenge, and (with an install) an assertion over the exact body.
 */
export async function attestedPost(
  world: World,
  install: Install | null,
  path: keyof typeof ENDPOINT_ACTIONS,
  body: Record<string, unknown> | ((challenge: string) => Promise<Record<string, unknown>> | Record<string, unknown>),
  options: AttestedOptions = {},
): Promise<Response> {
  const challenge = options.challenge ?? (await newChallenge(world));
  const fields = typeof body === "function" ? await body(challenge) : body;
  const text = JSON.stringify({ action: ENDPOINT_ACTIONS[path], challenge, ...fields });
  const headers: Record<string, string> = { ...options.extraHeaders };
  if (install) {
    const counter = options.counter ?? install.counter + 1;
    install.counter = Math.max(install.counter, counter);
    const assertion = await makeAssertion({ device: install.device, appId: install.appId ?? APP_ID, clientData: new TextEncoder().encode(text), counter });
    headers["x-app-attest-key-id"] = install.keyId;
    headers["x-app-attest-assertion"] = base64(assertion);
  }
  return postJson(world, path, text, headers);
}

/** An ID token from the world's stand-in for `provider`, for `subject`, bound to `challenge`. */
export async function idToken(world: World, provider: Provider, subject: string, challenge: string, overrides: Record<string, unknown> = {}, key?: SigningKey): Promise<string> {
  return signRs256(idTokenClaims(provider, subject, await nonceOf(challenge), world.clock.now, overrides), key ?? world.signingKeys[provider]);
}

/** A dev test issuer token for `subject`, bound to `challenge`, keyed with `secret` (default: the test one). */
export async function devIdToken(world: World, subject: string, challenge: string, overrides: Record<string, unknown> = {}, secret = DEV_SIGNIN_SECRET): Promise<string> {
  return signDevTestToken(devTestClaims(subject, await nonceOf(challenge), world.clock.now, overrides), secret);
}

let subjectCounter = 0;

/** A made-up provider user ID, unique per call. */
export function newSubject(provider: Provider): string {
  subjectCounter++;
  return provider === "apple" ? `000${subjectCounter}.0a1b2c3d4e5f60718293a4b5c6d7e8f9.${String(subjectCounter).padStart(4, "0")}` : `1170000000000000${String(subjectCounter).padStart(5, "0")}`;
}

export async function signInRequest(world: World, install: Install | null, provider: Provider, subject: string, extra: Record<string, unknown> = {}, options: AttestedOptions = {}): Promise<Response> {
  return attestedPost(
    world,
    install,
    provider === "apple" ? "/v1/auth/apple" : "/v1/auth/google",
    async (challenge) => ({ idToken: await idToken(world, provider, subject, challenge), ...(provider === "apple" ? { authorizationCode: "c-sign-in" } : {}), ...extra }),
    options,
  );
}

/** A reader signed in on one app install. */
export interface Reader {
  install: Install;
  provider: Provider;
  subject: string;
  token: string;
  sessionId: string;
  accountId: string;
  appAccountToken: string;
}

/** Attests a new install and signs in with `subject` (a new one by default). */
export async function signedInReader(world: World, provider: Provider = "apple", subject = newSubject(provider), install?: Install): Promise<Reader> {
  const theInstall = install ?? (await attestedInstall(world));
  const response = await signInRequest(world, theInstall, provider, subject);
  if (response.status !== 200) throw new Error(`sign-in: ${response.status} ${await response.text()}`);
  const body = (await response.json()) as SignInResponse;
  return {
    install: theInstall,
    provider,
    subject,
    token: body.deviceSessionToken,
    sessionId: body.sessionId,
    accountId: body.account.accountId,
    appAccountToken: body.account.appAccountToken,
  };
}

export interface AuthedOptions extends AttestedOptions {
  signedTransaction?: string;
  signedRenewalInfo?: string;
  bodyOverrides?: Record<string, unknown>;
  /** Send this instead of the reader's device session token. */
  token?: string;
}

/** POSTs to /v1/session or /v1/delete-my-data as `reader`. */
export function authed(world: World, reader: Reader, action: "session" | "delete-my-data", options: AuthedOptions = {}, install: Install | null = reader.install): Promise<Response> {
  return attestedPost(
    world,
    install,
    action === "session" ? "/v1/session" : "/v1/delete-my-data",
    {
      deviceSessionToken: options.token ?? reader.token,
      ...(options.signedTransaction ? { signedTransaction: options.signedTransaction } : {}),
      ...(options.signedRenewalInfo ? { signedRenewalInfo: options.signedRenewalInfo } : {}),
      ...options.bodyOverrides,
    },
    options,
  );
}

export async function sessionOk(response: Response): Promise<SessionResponse> {
  if (response.status !== 200) throw new Error(`${response.status} ${await response.text()}`);
  return response.json();
}

export async function errorCode(response: Response): Promise<string> {
  return ((await response.json()) as { error: { code: string } }).error.code;
}

export function sign(world: World, payload: Record<string, unknown>): Promise<string> {
  return signWithChain(payload, world.chain);
}

/** The JWT inside an R2 session token: base64("jwt/" + JWT). */
export function sessionTokenPayload(sessionToken: string): Record<string, unknown> {
  const text = atob(sessionToken);
  if (!text.startsWith("jwt/")) throw new Error("not an R2 session token");
  const payload = text.slice(4).split(".")[1]!;
  return JSON.parse(atob(payload.replace(/-/g, "+").replace(/_/g, "/")));
}

export async function putObjects(prefix: string, count: number, size = 1): Promise<void> {
  const body = new Uint8Array(size);
  const batch: Promise<unknown>[] = [];
  for (let i = 0; i < count; i++) {
    batch.push(env.BUCKET.put(`${prefix}obj-${String(i).padStart(6, "0")}`, body));
    if (batch.length === 50) await Promise.all(batch.splice(0));
  }
  await Promise.all(batch);
}

export async function countObjects(prefix: string): Promise<number> {
  let count = 0;
  let cursor: string | undefined;
  for (;;) {
    const listed = await env.BUCKET.list({ prefix, cursor });
    count += listed.objects.length;
    if (!listed.truncated) return count;
    cursor = listed.cursor;
  }
}

/** The local bucket, with a hook the test can set to run once before the next `list`. */
export function hookedBucket(): { bucket: R2Bucket; beforeNextList: { run: (() => Promise<void>) | null } } {
  const beforeNextList: { run: (() => Promise<void>) | null } = { run: null };
  const bucket = {
    async list(options?: R2ListOptions) {
      const hook = beforeNextList.run;
      beforeNextList.run = null;
      if (hook) await hook();
      return env.BUCKET.list(options);
    },
    delete: (keys: string | string[]) => env.BUCKET.delete(keys),
  } as unknown as R2Bucket;
  return { bucket, beforeNextList };
}

/** The deleted-folder tombstone for a folder key, if any. */
export function deletedFolder(folderKey: string): Promise<Record<string, unknown> | null> {
  return env.DB.prepare("SELECT * FROM deleted_folders WHERE folder_key = ?").bind(folderKey).first<Record<string, unknown>>();
}

/** Every D1 row that mentions the account, by table. */
export async function rowsFor(accountId: string): Promise<Record<string, number>> {
  const counts: Record<string, number> = {};
  for (const table of ["accounts", "device_sessions", "subscribers"]) {
    const row = await env.DB.prepare(`SELECT COUNT(*) AS n FROM ${table} WHERE account_id = ?`).bind(accountId).first<{ n: number }>();
    counts[table] = row?.n ?? 0;
  }
  return counts;
}
