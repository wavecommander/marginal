import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { APPLE_REVOKE_URL, APPLE_TOKEN_URL, appleClientSecret, revokeAppleAuthorization } from "../../src/appleSignIn";
import { readSettings, type Settings } from "../../src/env";
import { decodeJwt, siwaKey } from "../helpers/oidc";
import { BUNDLE_ID, SIWA_KEY_ID, TEAM_ID, testEnv } from "../helpers/settings";

const NOW = new Date("2026-11-15T12:00:00Z");
let settings: Settings;
let publicKey: CryptoKey;
let pem: string;

beforeAll(async () => {
  ({ pem, publicKey } = await siwaKey());
  settings = readSettings(testEnv({ APPLE_SIWA_KEY_ID: SIWA_KEY_ID, APPLE_SIWA_PRIVATE_KEY: pem }));
});

afterEach(() => {
  vi.restoreAllMocks();
});

function base64urlDecode(text: string): Uint8Array {
  return Uint8Array.from(atob(text.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
}

describe("appleClientSecret", () => {
  it("is an ES256 JWT Apple can verify: team, bundle, Apple's audience, five minutes", async () => {
    const secret = await appleClientSecret(settings, NOW);
    const { header, payload } = decodeJwt(secret);
    expect(header).toEqual({ alg: "ES256", kid: SIWA_KEY_ID });
    const iat = NOW.getTime() / 1000;
    expect(payload).toEqual({ iss: TEAM_ID, iat, exp: iat + 300, aud: "https://appleid.apple.com", sub: BUNDLE_ID });
    const [h, p, s] = secret.split(".") as [string, string, string];
    const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, base64urlDecode(s), new TextEncoder().encode(`${h}.${p}`));
    expect(valid).toBe(true);
  });

  it("accepts the PEM with its line breaks written as \\n", async () => {
    const flattened = readSettings(testEnv({ APPLE_SIWA_KEY_ID: SIWA_KEY_ID, APPLE_SIWA_PRIVATE_KEY: pem.replace(/\n/g, "\\n") }));
    expect(flattened.siwa?.privateKeyPkcs8).toEqual(settings.siwa?.privateKeyPkcs8);
  });
});

describe("revokeAppleAuthorization", () => {
  function apple(status = { token: 200, revoke: 200 }, tokens: Record<string, unknown> = { access_token: "a-1", refresh_token: "r-1" }) {
    const calls: { url: string; form: Record<string, string>; contentType: string | null }[] = [];
    const fetcher = async (url: string, init?: RequestInit) => {
      calls.push({ url, form: Object.fromEntries(new URLSearchParams(String(init?.body))), contentType: new Headers(init?.headers).get("content-type") });
      if (url === APPLE_TOKEN_URL) return new Response(JSON.stringify(tokens), { status: status.token });
      return new Response("", { status: status.revoke });
    };
    return { calls, fetcher };
  }

  it("exchanges the code, then revokes the refresh token", async () => {
    const { calls, fetcher } = apple();
    expect(await revokeAppleAuthorization("code-1", settings, fetcher, NOW, "test")).toBe("revoked");
    expect(calls.map((c) => c.url)).toEqual([APPLE_TOKEN_URL, APPLE_REVOKE_URL]);
    expect(calls[0]!.contentType).toBe("application/x-www-form-urlencoded");
    expect(calls[0]!.form).toMatchObject({ client_id: BUNDLE_ID, code: "code-1", grant_type: "authorization_code" });
    expect(calls[1]!.form).toMatchObject({ client_id: BUNDLE_ID, token: "r-1", token_type_hint: "refresh_token" });
    expect(decodeJwt(calls[1]!.form.client_secret!).payload.sub).toBe(BUNDLE_ID);
  });

  it("revokes the access token when Apple returns no refresh token", async () => {
    const { calls, fetcher } = apple(undefined, { access_token: "a-1" });
    expect(await revokeAppleAuthorization("code-1", settings, fetcher, NOW, "test")).toBe("revoked");
    expect(calls[1]!.form).toMatchObject({ token: "a-1", token_type_hint: "access_token" });
  });

  it("logs a failure and does not throw; never logs the code or a token", async () => {
    const lines: string[] = [];
    vi.spyOn(console, "log").mockImplementation((line: string) => void lines.push(line));
    vi.spyOn(console, "error").mockImplementation((line: string) => void lines.push(line));
    for (const status of [{ token: 400, revoke: 200 }, { token: 200, revoke: 500 }]) {
      const { fetcher } = apple(status);
      expect(await revokeAppleAuthorization("code-secret", settings, fetcher, NOW, "test")).toBe("failed");
    }
    const throwing = async () => {
      throw new Error("network down");
    };
    expect(await revokeAppleAuthorization("code-secret", settings, throwing, NOW, "test")).toBe("failed");
    expect(lines.length).toBe(3);
    for (const line of lines) {
      expect(line).not.toContain("code-secret");
      expect(line).not.toContain("r-1");
    }
  });

  it("is skipped, with a log line, when the Sign in with Apple key is not configured", async () => {
    const lines: string[] = [];
    vi.spyOn(console, "log").mockImplementation((line: string) => void lines.push(line));
    const { calls, fetcher } = apple();
    expect(await revokeAppleAuthorization("code-1", readSettings(testEnv()), fetcher, NOW, "test")).toBe("skipped");
    expect(calls).toEqual([]);
    expect(lines.some((line) => line.includes("apple-revoke-skipped"))).toBe(true);
  });
});
