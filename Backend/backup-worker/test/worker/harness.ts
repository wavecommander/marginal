// Drives the Worker inside the Workers runtime with a local D1 database and R2 bucket, a clock
// the test sets, and throwaway roots of trust standing in for Apple's.

import { env } from "cloudflare:workers";
import type { Env } from "../../src/env";
import { handle, runScheduled, type CronResult, type Deps } from "../../src/service";
import { attestPki, makeAssertion, makeAttestation, newDevice, sha256, type AttestPki, type Device } from "../helpers/attest";
import { appleLikeChain, base64, signWithChain, type AppleChain } from "../helpers/pki";
import { APP_ID, testVars } from "../helpers/settings";

export interface World {
  chain: AppleChain;
  pki: AttestPki;
  clock: { now: Date };
  env: Env;
  deps: Deps;
}

export async function makeWorld(overrides: Partial<Record<keyof Env, unknown>> = {}, depsOverrides: Partial<Deps> = {}): Promise<World> {
  const chain = await appleLikeChain();
  const pki = await attestPki();
  const clock = { now: new Date("2026-11-15T12:00:00Z") };
  const worldEnv = { ...testVars(overrides), DB: env.DB, BUCKET: env.BUCKET } as Env;
  const deps: Deps = { now: () => clock.now, appleRoots: [chain.root.der], appAttestRoots: [pki.root.der], ...depsOverrides };
  return { chain, pki, clock, env: worldEnv, deps };
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

export interface AuthedOptions {
  signedTransaction: string;
  signedRenewalInfo?: string;
  challenge?: string;
  /** Counter to put in the assertion (default: next). */
  counter?: number;
  extraHeaders?: Record<string, string>;
  bodyOverrides?: Record<string, unknown>;
}

/** POSTs to /v1/session or /v1/delete-my-data with a fresh challenge and an assertion over the body. */
export async function authed(world: World, install: Install | null, action: "session" | "delete-my-data", options: AuthedOptions): Promise<Response> {
  const challenge = options.challenge ?? (await newChallenge(world));
  const body = JSON.stringify({
    action,
    challenge,
    signedTransaction: options.signedTransaction,
    ...(options.signedRenewalInfo ? { signedRenewalInfo: options.signedRenewalInfo } : {}),
    ...options.bodyOverrides,
  });
  const headers: Record<string, string> = { ...options.extraHeaders };
  if (install) {
    const counter = options.counter ?? install.counter + 1;
    install.counter = Math.max(install.counter, counter);
    const assertion = await makeAssertion({ device: install.device, appId: install.appId ?? APP_ID, clientData: new TextEncoder().encode(body), counter });
    headers["x-app-attest-key-id"] = install.keyId;
    headers["x-app-attest-assertion"] = base64(assertion);
  }
  return postJson(world, action === "session" ? "/v1/session" : "/v1/delete-my-data", body, headers);
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
