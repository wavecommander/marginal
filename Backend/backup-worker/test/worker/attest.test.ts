import { env } from "cloudflare:workers";
import { beforeAll, describe, expect, it } from "vitest";
import type { ChallengeResponse, ErrorResponse, SignInResponse } from "../../src/contract";
import { AAGUID_DEVELOPMENT, makeAttestation, newDevice, sha256 } from "../helpers/attest";
import { transactionPayload } from "../helpers/apple";
import { base64 } from "../helpers/pki";
import { APP_ID, BYPASS_SECRET } from "../helpers/settings";
import { attestedInstall, authed, call, makeWorld, newChallenge, newSubject, postJson, sign, signInRequest, signedInReader, type Reader, type World } from "./harness";

let world: World;

beforeAll(async () => {
  world = await makeWorld();
});

function decode(text: string): Uint8Array {
  return Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
}

async function code(response: Response): Promise<string> {
  return ((await response.json()) as ErrorResponse).error.code;
}

describe("POST /v1/challenge", () => {
  it("hands out a random 32-byte challenge that lasts five minutes, storing only its hash", async () => {
    const response = await call(world, "/v1/challenge", { method: "POST" });
    expect(response.status).toBe(200);
    const body = (await response.json()) as ChallengeResponse;
    expect(decode(body.challenge).length).toBe(32);
    expect(body.expiresAt).toBe("2026-11-15T12:05:00.000Z");
    const rows = await env.DB.prepare("SELECT challenge_hash FROM challenges").all<{ challenge_hash: string }>();
    expect(rows.results.map((r) => r.challenge_hash)).not.toContain(body.challenge);
    expect(await newChallenge(world)).not.toBe(body.challenge);
  });
});

describe("POST /v1/attest", () => {
  async function attest(options: { challenge?: string; clientDataChallenge?: string; appId?: string; aaguid?: Uint8Array } = {}) {
    const device = await newDevice();
    const challenge = options.challenge ?? (await newChallenge(world));
    const attestation = await makeAttestation({
      pki: world.pki,
      device,
      appId: options.appId ?? APP_ID,
      aaguid: options.aaguid,
      clientDataHash: await sha256(decode(options.clientDataChallenge ?? challenge)),
    });
    const response = await postJson(world, "/v1/attest", { keyId: base64(device.keyId), challenge, attestation: base64(attestation) });
    return { response, device, challenge, attestation };
  }

  it("stores the key and its counter", async () => {
    const { response, device } = await attest();
    expect(response.status).toBe(201);
    expect(await response.json()).toEqual({ keyId: base64(device.keyId), environment: "production" });
    const row = await env.DB.prepare("SELECT counter, environment FROM attested_devices WHERE key_id = ?").bind(base64(device.keyId)).first();
    expect(row).toEqual({ counter: 0, environment: "production" });
  });

  it("refuses a replayed challenge", async () => {
    const first = await attest();
    expect(first.response.status).toBe(201);
    const device = await newDevice();
    const attestation = await makeAttestation({ pki: world.pki, device, appId: APP_ID, clientDataHash: await sha256(decode(first.challenge)) });
    const replay = await postJson(world, "/v1/attest", { keyId: base64(device.keyId), challenge: first.challenge, attestation: base64(attestation) });
    expect(replay.status).toBe(401);
    expect(await code(replay)).toBe("challenge-invalid");
  });

  it("refuses an attestation over a different challenge, and the challenge is spent", async () => {
    const other = await newChallenge(world);
    const { response, challenge } = await attest({ clientDataChallenge: other });
    expect(await code(response)).toBe("attestation-invalid");
    const again = await postJson(world, "/v1/attest", { keyId: base64(new Uint8Array(32)), challenge, attestation: "AA==" });
    expect(await code(again)).toBe("challenge-invalid");
  });

  it("refuses an expired or invented challenge", async () => {
    const challenge = await newChallenge(world);
    world.clock.now = new Date(world.clock.now.getTime() + 5 * 60_000);
    expect(await code((await attest({ challenge })).response)).toBe("challenge-invalid");
    world.clock.now = new Date("2026-11-15T12:00:00Z");
    expect(await code((await attest({ challenge: base64(new Uint8Array(32).fill(9)) })).response)).toBe("challenge-invalid");
  });

  it("refuses the wrong App ID and, in production, a development key", async () => {
    expect(await code((await attest({ appId: "OTHERTEAM1.com.example.other" })).response)).toBe("attestation-invalid");
    expect(await code((await attest({ aaguid: AAGUID_DEVELOPMENT })).response)).toBe("attestation-invalid");
  });

  it("refuses to register the same key twice", async () => {
    const device = await newDevice();
    for (const expected of [201, 409]) {
      const challenge = await newChallenge(world);
      const attestation = await makeAttestation({ pki: world.pki, device, appId: APP_ID, clientDataHash: await sha256(decode(challenge)) });
      const response = await postJson(world, "/v1/attest", { keyId: base64(device.keyId), challenge, attestation: base64(attestation) });
      expect(response.status).toBe(expected);
    }
  });
});

describe("assertions on authenticated requests", () => {
  let signedTransaction: string;
  beforeAll(async () => {
    signedTransaction = await sign(world, transactionPayload({ originalTransactionId: "4000000000000001", transactionId: "4000000000000001" }));
  });

  it("accept a valid assertion and require the counter to increase", async () => {
    const reader = await signedInReader(world);
    const install = reader.install;
    expect((await authed(world, reader, "session", { signedTransaction })).status).toBe(200);
    expect((await authed(world, reader, "session", { signedTransaction, counter: 5 })).status).toBe(200);
    // Same counter again, then a lower one: refused, even with a fresh challenge and a valid signature.
    expect(await code(await authed(world, reader, "session", { signedTransaction, counter: 5 }))).toBe("assertion-invalid");
    expect(await code(await authed(world, reader, "session", { signedTransaction, counter: 3 }))).toBe("assertion-invalid");
    expect((await authed(world, reader, "session", { signedTransaction, counter: 6 })).status).toBe(200);
    const row = await env.DB.prepare("SELECT counter FROM attested_devices WHERE key_id = ?").bind(install.keyId).first<{ counter: number }>();
    expect(row?.counter).toBe(6);
  });

  it("refuse a replayed request (its challenge is spent)", async () => {
    const reader = await signedInReader(world);
    const challenge = await newChallenge(world);
    expect((await authed(world, reader, "delete-my-data", { challenge })).status).toBe(200);
    expect(await code(await authed(world, reader, "delete-my-data", { challenge }))).toBe("challenge-invalid");
  });

  it("refuse an assertion from another app, an unknown key, a missing or tampered assertion", async () => {
    const reader = await signedInReader(world);
    const install = reader.install;
    expect(await code(await authed(world, reader, "session", {}, { ...install, appId: "OTHERTEAM1.com.example.other" }))).toBe("assertion-invalid");
    const unknown = { ...install, keyId: base64(new Uint8Array(32).fill(3)) };
    expect(await code(await authed(world, reader, "session", {}, unknown))).toBe("device-unknown");
    expect(await code(await authed(world, reader, "session", {}, null))).toBe("assertion-invalid");

    // Sign one body, send another.
    const challenge = await newChallenge(world);
    const body = JSON.stringify({ action: "session", challenge, deviceSessionToken: reader.token });
    const { makeAssertion } = await import("../helpers/attest");
    const assertion = await makeAssertion({ device: install.device, appId: APP_ID, clientData: new TextEncoder().encode(body), counter: 50 });
    const altered = body.replace('"session"', '"session" ');
    const response = await postJson(world, "/v1/session", altered, { "x-app-attest-key-id": install.keyId, "x-app-attest-assertion": base64(assertion) });
    expect(await code(response)).toBe("assertion-invalid");
  });

  it("refuse an action that does not match the endpoint", async () => {
    const reader = await signedInReader(world);
    const response = await authed(world, reader, "session", { bodyOverrides: { action: "delete-my-data" } });
    expect(await code(response)).toBe("bad-request");
  });

  it("refuse a device session used from another attested install", async () => {
    const reader = await signedInReader(world);
    const other = await attestedInstall(world);
    expect(await code(await authed(world, reader, "session", { signedTransaction }, other))).toBe("session-invalid");
    // The session still works where it was made.
    expect((await authed(world, reader, "delete-my-data", {})).status).toBe(200);
  });
});

describe("the App Attest bypass", () => {
  let signedTransaction: string;
  beforeAll(async () => {
    signedTransaction = await sign(world, transactionPayload({ originalTransactionId: "4000000000000002", transactionId: "4000000000000002", environment: "Sandbox" }));
  });

  it("works in dev with the right secret only, for sign-in and sessions", async () => {
    const dev = await makeWorld({ ENVIRONMENT: "dev", APP_ATTEST_BYPASS_SECRET: BYPASS_SECRET, R2_S3_HOST: "localhost:8787", APP_APPLE_ID: "" });
    const bypass = { extraHeaders: { "x-app-attest-bypass": BYPASS_SECRET } };
    const signIn = await signInRequest(dev, null, "apple", newSubject("apple"), {}, bypass);
    expect(signIn.status).toBe(200);
    const { deviceSessionToken } = (await signIn.json()) as SignInResponse;
    const reader = { token: deviceSessionToken } as Reader;
    const devSigned = await sign(dev, transactionPayload({ originalTransactionId: "4000000000000003", transactionId: "4000000000000003", environment: "Sandbox" }));
    const good = await authed(dev, reader, "session", { signedTransaction: devSigned, ...bypass }, null);
    expect(good.status).toBe(200);
    const wrong = await authed(dev, reader, "session", { signedTransaction: devSigned, extraHeaders: { "x-app-attest-bypass": `${BYPASS_SECRET}x` } }, null);
    expect(await code(wrong)).toBe("assertion-invalid");
    const wrongSignIn = await signInRequest(dev, null, "apple", newSubject("apple"), {}, { extraHeaders: { "x-app-attest-bypass": `${BYPASS_SECRET}x` } });
    expect(await code(wrongSignIn)).toBe("assertion-invalid");
  });

  it("is never honoured in production, whatever is configured", async () => {
    const reader = await signedInReader(world);
    // Not configured: the header is ignored and an assertion is required.
    const plain = await authed(world, reader, "session", { signedTransaction, extraHeaders: { "x-app-attest-bypass": BYPASS_SECRET } }, null);
    expect(await code(plain)).toBe("assertion-invalid");
    const plainSignIn = await signInRequest(world, null, "apple", newSubject("apple"), {}, { extraHeaders: { "x-app-attest-bypass": BYPASS_SECRET } });
    expect(await code(plainSignIn)).toBe("assertion-invalid");
    // Configured by mistake: the Worker refuses to serve anything at all.
    const misconfigured = await makeWorld({ APP_ATTEST_BYPASS_SECRET: BYPASS_SECRET });
    for (const path of ["/v1/challenge", "/v1/session", "/v1/auth/apple"]) {
      const response = await postJson(misconfigured, path, { action: "session", challenge: base64(new Uint8Array(32)), signedTransaction }, { "x-app-attest-bypass": BYPASS_SECRET });
      expect(response.status).toBe(500);
      expect(await code(response)).toBe("internal");
    }
    const health = await call(misconfigured, "/v1/health");
    expect(health.status).toBe(500);
    expect(await code(health)).toBe("internal");
  });
});
