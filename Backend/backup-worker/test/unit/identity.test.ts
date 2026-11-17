import { createHash, createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";
import {
  devTestNamespace,
  identityHash,
  newAccountId,
  newFolderKey,
  newSessionId,
  newSessionToken,
  normalizeAppAccountToken,
  sessionTokenHash,
  subscriptionKey,
} from "../../src/identity";
import { userPrefix } from "../../src/tempCredentials";

const SECRET = "s".repeat(40);

describe("identityHash", () => {
  it("is a keyed, domain-separated hash of provider and subject", async () => {
    const hash = await identityHash(SECRET, "apple", "001234.abcdef.0123");
    expect(hash).toBe(createHmac("sha256", SECRET).update(["tactile-identity-v1", "apple", "001234.abcdef.0123"].join("\0")).digest("hex"));
  });

  it("differs by provider, subject and secret, and is stable", async () => {
    const a = await identityHash(SECRET, "apple", "123");
    expect(await identityHash(SECRET, "apple", "123")).toBe(a);
    expect(await identityHash(SECRET, "google", "123")).not.toBe(a);
    expect(await identityHash(SECRET, "apple", "124")).not.toBe(a);
    expect(await identityHash("t".repeat(40), "apple", "123")).not.toBe(a);
  });

  it("keeps the dev test issuer's identities in their own namespaces, apart from the real providers'", async () => {
    expect(await identityHash(SECRET, "dev-test:apple", "123")).toBe(createHmac("sha256", SECRET).update(["tactile-identity-v1", "dev-test:apple", "123"].join("\0")).digest("hex"));
    const hashes = await Promise.all((["apple", "google", "dev-test:apple", "dev-test:google"] as const).map((namespace) => identityHash(SECRET, namespace, "123")));
    expect(new Set(hashes).size).toBe(4);
    expect(devTestNamespace("apple")).toBe("dev-test:apple");
    expect(devTestNamespace("google")).toBe("dev-test:google");
    await expect(identityHash(SECRET, "dev-test" as never, "123")).rejects.toThrow(/namespace/);
  });

  it("refuses a weak secret and an empty or oversized subject", async () => {
    await expect(identityHash("short", "apple", "123")).rejects.toThrow(/IDENTITY_KEY_SECRET/);
    await expect(identityHash(SECRET, "apple", "")).rejects.toThrow();
    await expect(identityHash(SECRET, "apple", "x".repeat(256))).rejects.toThrow();
    await expect(identityHash(SECRET, "apple", "a\0b")).rejects.toThrow();
  });
});

describe("subscriptionKey", () => {
  it("is a keyed hash in its own domain, separate per environment", async () => {
    const key = await subscriptionKey(SECRET, "Production", "2000000123456789");
    expect(key).toBe(createHmac("sha256", SECRET).update(["tactile-subscription-v1", "Production", "2000000123456789"].join("\0")).digest("hex"));
    expect(await subscriptionKey(SECRET, "Sandbox", "2000000123456789")).not.toBe(key);
    expect(await subscriptionKey(SECRET, "Production", "2000000123456780")).not.toBe(key);
    // Never equal to an identity hash of the same digits.
    expect(await identityHash(SECRET, "apple", "2000000123456789")).not.toBe(key);
  });

  it("refuses anything that is not a transaction ID", async () => {
    for (const bad of ["", "abc", "12 34", "123/../456", "1".repeat(41)]) {
      await expect(subscriptionKey(SECRET, "Production", bad)).rejects.toThrow(/transaction ID/);
    }
  });
});

describe("random names", () => {
  it("are the right shape and never repeat", () => {
    const ids = new Set<string>();
    for (let i = 0; i < 50; i++) {
      const accountId = newAccountId();
      const folderKey = newFolderKey();
      expect(accountId).toMatch(/^[0-9a-f]{32}$/);
      expect(newSessionId()).toMatch(/^[0-9a-f]{32}$/);
      expect(userPrefix(folderKey)).toBe(`users/${folderKey}/`);
      ids.add(accountId);
      ids.add(folderKey);
    }
    expect(ids.size).toBe(100);
  });

  it("session tokens are 32 random bytes, stored only as their SHA-256", async () => {
    const token = newSessionToken();
    expect(token).toMatch(/^[A-Za-z0-9_-]{43}$/);
    const bytes = Buffer.from(token, "base64url");
    expect(bytes.length).toBe(32);
    expect(await sessionTokenHash(token)).toBe(createHash("sha256").update(bytes).digest("hex"));
    await expect(sessionTokenHash("short")).rejects.toThrow();
    await expect(sessionTokenHash(`${token}=`)).rejects.toThrow();
  });

  it("appAccountTokens compare in lower case and must be UUIDs", () => {
    expect(normalizeAppAccountToken("6F9619FF-8B86-D011-B42D-00C04FC964FF")).toBe("6f9619ff-8b86-d011-b42d-00c04fc964ff");
    expect(normalizeAppAccountToken("not-a-uuid")).toBeUndefined();
    expect(normalizeAppAccountToken("6f9619ff8b86d011b42d00c04fc964ff")).toBeUndefined();
  });
});
