import { exports } from "cloudflare:workers";
import { afterEach, beforeAll, beforeEach, describe, expect, it, vi } from "vitest";
import type { ErrorResponse, SessionResponse } from "../../src/contract";
import { MAX_BODY_BYTES } from "../../src/http";
import { renewalPayload, signedNotification, transactionPayload } from "../helpers/apple";
import { base64, signJws, xcodeLikeCertificate } from "../helpers/pki";
import { BYPASS_SECRET, SECRET_VALUES } from "../helpers/settings";
import { attestedInstall, authed, call, makeWorld, newChallenge, postJson, sign, type Install, type World } from "./harness";

let world: World;
let install: Install;
let logged: string[] = [];

beforeAll(async () => {
  world = await makeWorld();
  install = await attestedInstall(world);
});

beforeEach(() => {
  logged = [];
  for (const level of ["log", "info", "warn", "error", "debug"] as const) {
    vi.spyOn(console, level).mockImplementation((...args: unknown[]) => {
      logged.push(args.map((arg) => (typeof arg === "string" ? arg : JSON.stringify(arg))).join(" "));
    });
  }
});

afterEach(() => {
  vi.restoreAllMocks();
});

async function code(response: Response): Promise<string> {
  return ((await response.json()) as ErrorResponse).error.code;
}

describe("requests that are refused before any work", () => {
  it("unknown paths and wrong methods", async () => {
    expect(await code(await call(world, "/v1/nothing"))).toBe("not-found");
    const wrong = await call(world, "/v1/session", { method: "GET" });
    expect(wrong.status).toBe(405);
    expect(wrong.headers.get("allow")).toBe("POST");
    expect(await code(wrong)).toBe("method-not-allowed");
    expect((await call(world, "/v1/health", { method: "POST" })).headers.get("allow")).toBe("GET");
  });

  it("oversized bodies, whatever the declared length", async () => {
    const big = "x".repeat(MAX_BODY_BYTES + 1);
    const declared = await postJson(world, "/v1/apple/notifications", { signedPayload: big });
    expect(declared.status).toBe(413);
    // Streamed without a length.
    const stream = new ReadableStream({
      start(controller) {
        controller.enqueue(new TextEncoder().encode(`{"signedPayload":"${big}"}`));
        controller.close();
      },
    });
    const streamed = await call(world, "/v1/apple/notifications", { method: "POST", headers: { "content-type": "application/json" }, body: stream, duplex: "half" } as RequestInit);
    expect(streamed.status).toBe(413);
  });

  it("wrong content type, malformed JSON, missing or wrong fields", async () => {
    const text = await call(world, "/v1/attest", { method: "POST", headers: { "content-type": "text/plain" }, body: "{}" });
    expect(await code(text)).toBe("unsupported-media-type");
    expect(await code(await postJson(world, "/v1/attest", "{not json"))).toBe("bad-request");
    expect(await code(await postJson(world, "/v1/attest", "[]"))).toBe("bad-request");
    expect(await code(await postJson(world, "/v1/attest", { keyId: "AA==" }))).toBe("bad-request");
    expect(await code(await postJson(world, "/v1/session", { action: "session", challenge: await newChallenge(world) }))).toBe("bad-request");
    expect(await code(await postJson(world, "/v1/session", { action: "session", challenge: 5, signedTransaction: "a.b.c" }))).toBe("bad-request");
    expect(await code(await postJson(world, "/v1/challenge", { anything: 1 }))).toBe("bad-request");
    expect(await code(await postJson(world, "/v1/apple/notifications", {}))).toBe("bad-request");
  });

  it("every error is the stable shape with no internals", async () => {
    const response = await postJson(world, "/v1/apple/notifications", { signedPayload: "a.b.c" });
    expect(response.status).toBe(401);
    expect(response.headers.get("content-type")).toBe("application/json; charset=utf-8");
    expect(response.headers.get("cache-control")).toBe("no-store");
    const body = await response.json();
    expect(body).toEqual({ error: { code: "notification-invalid", message: "The notification could not be verified." } });
  });
});

describe("nothing sensitive leaves the Worker", () => {
  it("no secret, signed payload, credential or full user key in any log line or error", async () => {
    const transaction = transactionPayload({ originalTransactionId: "7000000000000001", transactionId: "7000000000000001" });
    const signedTransaction = await sign(world, transaction);
    const signedRenewalInfo = await sign(world, renewalPayload({ originalTransactionId: "7000000000000001" }));
    const ok = await authed(world, install, "session", { signedTransaction, signedRenewalInfo });
    expect(ok.status).toBe(200);
    const session = (await ok.json()) as SessionResponse;
    const userKey = session.storage.prefix.split("/")[1]!;

    // A spread of refusals, each with secrets in play.
    const responses: Response[] = [
      await authed(world, install, "session", { signedTransaction: signedTransaction.slice(0, -4) + "AAAA" }),
      await authed(world, null, "session", { signedTransaction, extraHeaders: { "x-app-attest-bypass": BYPASS_SECRET } }),
      await postJson(world, "/v1/apple/notifications", { signedPayload: signedTransaction }),
      await postJson(world, "/v1/apple/notifications", { signedPayload: await signedNotification(world.chain, "DID_RENEW", undefined, transaction, undefined) }),
    ];
    const misconfigured = await makeWorld({ USER_KEY_SECRET: "too-short" });
    responses.push(await call(misconfigured, "/v1/health"));
    const bodies = await Promise.all(responses.map((r) => r.text()));

    const forbidden = [
      ...SECRET_VALUES,
      "too-short",
      signedTransaction,
      signedTransaction.split(".")[1]!,
      signedRenewalInfo,
      session.credentials.secretAccessKey,
      session.credentials.sessionToken,
      userKey,
      install.keyId,
      "7000000000000001",
    ];
    expect(logged.length).toBeGreaterThan(3);
    for (const line of [...logged, ...bodies]) {
      for (const secret of forbidden) expect(line).not.toContain(secret);
      expect(line).not.toMatch(/at .*\.ts:\d+/); // no stack traces
    }
    // The settings problem is named in the log, without the value.
    expect(logged.some((line) => line.includes("USER_KEY_SECRET"))).toBe(true);
  });
});

describe("the Xcode environment end to end", () => {
  it("dev with the test certificate gives a session in the sandbox namespace; production refuses", async () => {
    const xcode = await xcodeLikeCertificate();
    const signed = await signJws(transactionPayload({ originalTransactionId: "7", transactionId: "7", environment: "Xcode" }), [xcode.der], xcode.keys.privateKey);
    const dev = await makeWorld({ ENVIRONMENT: "dev", XCODE_STOREKIT_CERT: base64(xcode.der), APP_ATTEST_BYPASS_SECRET: BYPASS_SECRET, R2_S3_HOST: "localhost:8787", APP_APPLE_ID: "" });
    const response = await authed(dev, null, "session", { signedTransaction: signed, extraHeaders: { "x-app-attest-bypass": BYPASS_SECRET } });
    expect(response.status).toBe(200);
    const body = (await response.json()) as SessionResponse;
    expect(body.storage.prefix).toMatch(/^sandbox\/[0-9a-f]{64}\/$/);
    expect(body.subscription.environment).toBe("Xcode");
    expect(body.storage.endpoint).toBe("https://localhost:8787");

    const refused = await authed(world, install, "session", { signedTransaction: signed });
    expect(refused.status).toBe(401);
    expect(await code(refused)).toBe("transaction-invalid");
  });
});

describe("through the deployed entry point and wrangler.jsonc", () => {
  it("GET /v1/health answers", async () => {
    const response = await exports.default.fetch("https://backup.example/v1/health");
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ ok: true, environment: "dev" });
  });
});
