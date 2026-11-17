// Short-lived, scoped R2 credentials, minted here in the Worker.
//
// R2 "temporary credentials" are derived from a parent R2 API token by signing a JWT with the
// parent's secret access key (Cloudflare R2 docs, "Temporary credentials", local signing):
//
//   1. JWT payload: the bucket, the permitted operations and, optionally, the allowed paths.
//      Standard claims: sub = account ID, iss = parent access key ID, aud = the bucket's S3
//      endpoint host, iat, exp.
//   2. Sign with HS256, key = the parent secret access key (its UTF-8 bytes).
//   3. Temporary secret access key = lower-case hex SHA-256 of the signed JWT.
//      Session token = base64("jwt/" + signed JWT).
//      Access key ID = the parent's access key ID, reused.
//
// The client signs S3 requests with the access key ID and the temporary secret, and sends the
// session token as `X-Amz-Security-Token`. R2 checks the JWT's signature and expiry and then
// refuses anything outside its bucket, actions and paths. The parent secret never leaves the
// Worker, and revoking the parent token ends every credential derived from it.
//
// Limiting by S3 *action* (rather than a preset scope) is only available with local signing,
// which is why the Worker mints credentials itself instead of calling the Cloudflare API.

/** The S3 operations R2 lets a temporary credential name. */
export type R2Action =
  | "HeadObject"
  | "GetObject"
  | "GetBucketLocation"
  | "ListObjectsV1"
  | "ListObjectsV2"
  | "ListMultipartUploads"
  | "ListParts"
  | "PutObject"
  | "DeleteObject"
  | "DeleteObjects"
  | "CopyObject"
  | "CreateMultipartUpload"
  | "UploadPart"
  | "UploadPartCopy"
  | "AbortMultipartUpload"
  | "CompleteMultipartUpload";

/** What a credential lets its holder do. */
export type AccessMode =
  /** Back up and restore. */
  | "read-write"
  /** Restore only (a subscription that has ended, within the read-only period). */
  | "read-only"
  /** Restore and delete, but not upload (over the storage allowance: lets the user make room). */
  | "read-delete";

const READ: R2Action[] = ["HeadObject", "GetObject", "ListObjectsV2"];

/**
 * Exactly the operations the app's S3 client performs in each mode, and no others.
 * (`AbortMultipartUpload` stays allowed wherever deleting is, so an interrupted upload can
 * always be cleaned up.)
 */
export const ACTIONS: Record<AccessMode, R2Action[]> = {
  "read-only": READ,
  "read-delete": [...READ, "DeleteObject", "AbortMultipartUpload"],
  "read-write": [
    ...READ,
    "PutObject",
    "DeleteObject",
    "CreateMultipartUpload",
    "UploadPart",
    "CompleteMultipartUpload",
    "AbortMultipartUpload",
  ],
};

export interface TempCredentialRequest {
  /** The Cloudflare account that owns the bucket. */
  accountId: string;
  /** The bucket's S3 endpoint host, e.g. `<account id>.r2.cloudflarestorage.com`. */
  s3Host: string;
  bucket: string;
  parentAccessKeyId: string;
  parentSecretAccessKey: string;
  actions: R2Action[];
  /**
   * Key prefixes the credential may touch. Each must end with `/`, so `users/ab/` can never
   * also match `users/abc/`.
   */
  prefixes: string[];
  ttlSeconds: number;
  /** For tests. */
  now?: Date;
}

export interface TempCredentials {
  accessKeyId: string;
  secretAccessKey: string;
  sessionToken: string;
  /** When R2 stops accepting it (ISO 8601). */
  expiresAt: string;
}

/** Longest lifetime this service will ever issue: a credential is a bearer token. */
export const MAX_TTL_SECONDS = 3600;

export async function createTempCredentials(request: TempCredentialRequest): Promise<TempCredentials> {
  const { accountId, s3Host, bucket, parentAccessKeyId, parentSecretAccessKey, actions, prefixes, ttlSeconds } = request;
  for (const [name, value] of Object.entries({ accountId, s3Host, bucket, parentAccessKeyId, parentSecretAccessKey })) {
    if (!value) throw new Error(`createTempCredentials: ${name} is empty`);
  }
  if (actions.length === 0) throw new Error("createTempCredentials: no actions");
  // A credential with no path limit would open the whole bucket: every user's backups.
  if (prefixes.length === 0) throw new Error("createTempCredentials: no prefixes");
  for (const prefix of prefixes) {
    if (!prefix.endsWith("/") || prefix.startsWith("/") || prefix.includes("//") || prefix.length < 2) {
      throw new Error("createTempCredentials: a prefix must be a folder path ending in /");
    }
  }
  if (!Number.isInteger(ttlSeconds) || ttlSeconds < 60 || ttlSeconds > MAX_TTL_SECONDS) {
    throw new Error(`createTempCredentials: ttlSeconds must be 60...${MAX_TTL_SECONDS}`);
  }

  const issuedAt = Math.floor((request.now ?? new Date()).getTime() / 1000);
  const expiresAt = issuedAt + ttlSeconds;
  const header = { alg: "HS256", typ: "JWT" };
  const payload = {
    bucket,
    actions,
    paths: { prefixPaths: prefixes, objectPaths: [] as string[] },
    sub: accountId,
    iss: parentAccessKeyId,
    aud: s3Host,
    iat: issuedAt,
    exp: expiresAt,
  };

  const encoder = new TextEncoder();
  const signingInput = `${base64url(encoder.encode(JSON.stringify(header)))}.${base64url(encoder.encode(JSON.stringify(payload)))}`;
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(parentSecretAccessKey),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(signingInput)));
  const jwt = `${signingInput}.${base64url(signature)}`;

  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", encoder.encode(jwt)));
  return {
    accessKeyId: parentAccessKeyId,
    secretAccessKey: hex(digest),
    sessionToken: btoa(`jwt/${jwt}`),
    expiresAt: new Date(expiresAt * 1000).toISOString(),
  };
}

/** The folder an account's backups live in. `folderKey` is 64 lower-case hex digits (see `identity.ts`). */
export function userPrefix(folderKey: string): string {
  if (!/^[0-9a-f]{64}$/.test(folderKey)) throw new Error("userPrefix: not a folder key");
  return `users/${folderKey}/`;
}

function base64url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
