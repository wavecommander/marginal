import { createHash, createHmac } from "node:crypto";
import { describe, expect, it } from "vitest";
import { ACTIONS, MAX_TTL_SECONDS, createTempCredentials, userPrefix, type TempCredentialRequest } from "../../src/tempCredentials";

const USER = "a".repeat(64);
const NOW = new Date("2026-11-15T12:00:00Z");

function request(overrides: Partial<TempCredentialRequest> = {}): TempCredentialRequest {
  return {
    accountId: "0123456789abcdef0123456789abcdef",
    s3Host: "0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com",
    bucket: "tactile-texts-backups-dev",
    parentAccessKeyId: "parent-access-key-id",
    parentSecretAccessKey: "parent-secret-access-key",
    actions: ACTIONS["read-write"],
    prefixes: [userPrefix(USER)],
    ttlSeconds: 900,
    now: NOW,
    ...overrides,
  };
}

function decode(part: string): unknown {
  return JSON.parse(Buffer.from(part, "base64url").toString("utf8"));
}

/** The session token is base64("jwt/" + signed JWT). */
function jwtOf(sessionToken: string): string {
  const text = Buffer.from(sessionToken, "base64").toString("utf8");
  expect(text.startsWith("jwt/")).toBe(true);
  return text.slice(4);
}

describe("createTempCredentials", () => {
  it("builds the credential exactly as R2's local-signing rule says", async () => {
    const credentials = await createTempCredentials(request());
    const jwt = jwtOf(credentials.sessionToken);
    const [header, payload, signature] = jwt.split(".") as [string, string, string];

    expect(decode(header)).toEqual({ alg: "HS256", typ: "JWT" });
    expect(decode(payload)).toEqual({
      bucket: "tactile-texts-backups-dev",
      actions: ACTIONS["read-write"],
      paths: { prefixPaths: [`users/${USER}/`], objectPaths: [] },
      sub: "0123456789abcdef0123456789abcdef",
      iss: "parent-access-key-id",
      aud: "0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com",
      iat: NOW.getTime() / 1000,
      exp: NOW.getTime() / 1000 + 900,
    });

    // Signed with HS256 using the parent secret, computed here independently with node:crypto.
    const expected = createHmac("sha256", "parent-secret-access-key").update(`${header}.${payload}`).digest("base64url");
    expect(signature).toBe(expected);

    // The parent's access key ID is reused; the temporary secret is the hex SHA-256 of the JWT.
    expect(credentials.accessKeyId).toBe("parent-access-key-id");
    expect(credentials.secretAccessKey).toBe(createHash("sha256").update(jwt).digest("hex"));
    expect(credentials.expiresAt).toBe("2026-11-15T12:15:00.000Z");
  });

  it("never contains the parent secret", async () => {
    const credentials = await createTempCredentials(request());
    const everything = JSON.stringify(credentials) + jwtOf(credentials.sessionToken);
    expect(everything).not.toContain("parent-secret-access-key");
  });

  it("names actions, never a preset scope", async () => {
    const credentials = await createTempCredentials(request({ actions: ACTIONS["read-only"] }));
    const payload = decode(jwtOf(credentials.sessionToken).split(".")[1]!) as Record<string, unknown>;
    expect(payload.actions).toEqual(["HeadObject", "GetObject", "ListObjectsV2"]);
    expect(payload).not.toHaveProperty("scope");
  });

  it("refuses a credential that would open the whole bucket", async () => {
    await expect(createTempCredentials(request({ prefixes: [] }))).rejects.toThrow(/no prefixes/);
  });

  it("refuses a prefix that is not a folder", async () => {
    // `users/ab` would also match `users/abc/...`: another user's folder.
    for (const prefix of ["users/ab", "/users/ab/", "users//ab/", "/"]) {
      await expect(createTempCredentials(request({ prefixes: [prefix] }))).rejects.toThrow(/folder path/);
    }
  });

  it("refuses no actions, a missing value and an unreasonable lifetime", async () => {
    await expect(createTempCredentials(request({ actions: [] }))).rejects.toThrow(/no actions/);
    await expect(createTempCredentials(request({ parentSecretAccessKey: "" }))).rejects.toThrow(/parentSecretAccessKey/);
    await expect(createTempCredentials(request({ ttlSeconds: 59 }))).rejects.toThrow(/ttlSeconds/);
    await expect(createTempCredentials(request({ ttlSeconds: MAX_TTL_SECONDS + 1 }))).rejects.toThrow(/ttlSeconds/);
    await expect(createTempCredentials(request({ ttlSeconds: 900.5 }))).rejects.toThrow(/ttlSeconds/);
  });
});

describe("access modes", () => {
  it("read-only can read and list and nothing else", () => {
    expect(ACTIONS["read-only"]).toEqual(["HeadObject", "GetObject", "ListObjectsV2"]);
  });

  it("read-delete can make room but cannot upload", () => {
    const actions = ACTIONS["read-delete"];
    expect(actions).toContain("DeleteObject");
    for (const upload of ["PutObject", "CreateMultipartUpload", "UploadPart", "CompleteMultipartUpload"] as const) {
      expect(actions).not.toContain(upload);
    }
  });

  it("read-write covers what the app's S3 client does and no bulk or copy operations", () => {
    const actions = ACTIONS["read-write"];
    for (const needed of ["HeadObject", "GetObject", "ListObjectsV2", "PutObject", "DeleteObject",
      "CreateMultipartUpload", "UploadPart", "CompleteMultipartUpload", "AbortMultipartUpload"] as const) {
      expect(actions).toContain(needed);
    }
    for (const unneeded of ["DeleteObjects", "CopyObject", "UploadPartCopy", "ListObjectsV1"] as const) {
      expect(actions).not.toContain(unneeded);
    }
  });
});

describe("userPrefix", () => {
  it("is the user's folder, ending in a slash", () => {
    expect(userPrefix(USER)).toBe(`users/${USER}/`);
  });

  it("accepts only a user key", () => {
    for (const bad of ["", "abc", "A".repeat(64), `${"a".repeat(63)}/`, "../" + "a".repeat(61)]) {
      expect(() => userPrefix(bad)).toThrow();
    }
  });
});
