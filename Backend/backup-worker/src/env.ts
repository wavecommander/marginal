/** Bindings, settings and secrets of the Worker (see wrangler.jsonc and .dev.vars.example). */

import { fromBase64 } from "./bytes";
import { MAX_TTL_SECONDS } from "./tempCredentials";
import { parseCertificate } from "./x509";

export interface Env {
  DB: D1Database;
  BUCKET: R2Bucket;

  ENVIRONMENT: "dev" | "production";
  R2_ACCOUNT_ID: string;
  R2_S3_HOST: string;
  R2_BUCKET_NAME: string;
  APP_BUNDLE_ID: string;
  /** The 10-character App ID prefix (team ID); App Attest's App ID is `<team>.<bundle>`. */
  APPLE_TEAM_ID: string;
  /** The app's numeric Apple ID from App Store Connect. Required in production (notifications carry it). */
  APP_APPLE_ID?: string;
  CREDENTIAL_TTL_SECONDS: string;
  READ_ONLY_DAYS: string;
  DELETE_AFTER_DAYS: string;
  /** JSON object: product ID to storage allowance in bytes. */
  PRODUCT_ALLOWANCES: string;
  /** Allowance in bytes for sandbox and Xcode purchases (App Review, TestFlight, development). */
  SANDBOX_ALLOWANCE_BYTES: string;
  /** How long a usage count is reused before the folder is listed again. */
  USAGE_CACHE_SECONDS: string;
  /**
   * `dev` only: base64 DER of Xcode's StoreKit test certificate (Editor > Save Public Certificate),
   * the root that signs transactions from StoreKit Testing in Xcode. Public, not a secret.
   */
  XCODE_STOREKIT_CERT?: string;
  /** Comma-separated Google OAuth client IDs whose ID tokens are accepted. Empty: Google sign-in is off. */
  GOOGLE_CLIENT_IDS?: string;
  /** Days a subscription stays with an account before another account may take it over (30). */
  SUBSCRIPTION_MOVE_DAYS?: string;

  // Secrets.
  R2_PARENT_ACCESS_KEY_ID: string;
  R2_PARENT_SECRET_ACCESS_KEY: string;
  /** Keys the hashes of sign-in identities and of subscriptions. At least 32 characters. */
  IDENTITY_KEY_SECRET: string;
  /** Sign in with Apple key (Certificates, Identifiers & Profiles > Keys): its 10-character ID. Optional. */
  APPLE_SIWA_KEY_ID?: string;
  /** That key's private key, PKCS#8 PEM. Optional; without the pair, Apple revocation is skipped. */
  APPLE_SIWA_PRIVATE_KEY?: string;
  /** `dev` only: lets the simulator (which has no App Attest) through. Must not exist in production. */
  APP_ATTEST_BYPASS_SECRET?: string;
  /**
   * `dev` only: keys the dev test issuer's HS256 sign-in tokens, so the simulator and end-to-end
   * tests can sign in without Apple or Google (see idToken.ts). Must not exist in production.
   */
  DEV_TEST_SIGNIN_SECRET?: string;
}

/** Settings parsed and checked; `readSettings` throws a plain message naming what is wrong. */
export interface Settings {
  environment: "dev" | "production";
  credentialTTLSeconds: number;
  readOnlyDays: number;
  deleteAfterDays: number;
  /** Product ID to allowance in bytes. */
  allowances: Map<string, number>;
  sandboxAllowanceBytes: number;
  usageCacheSeconds: number;
  bundleId: string;
  /** The 10-character App ID prefix. */
  teamId: string;
  /** `<team>.<bundle>`, what App Attest hashes into the RP ID. */
  appId: string;
  appAppleId: number | undefined;
  r2: {
    accountId: string;
    s3Host: string;
    bucket: string;
    parentAccessKeyId: string;
    parentSecretAccessKey: string;
  };
  identityKeySecret: string;
  /** Google OAuth client IDs accepted as an ID token's audience; empty when Google sign-in is off. */
  googleClientIds: string[];
  subscriptionMoveDays: number;
  /** The Sign in with Apple key, for revoking; undefined when not configured. */
  siwa: { keyId: string; privateKeyPkcs8: Uint8Array } | undefined;
  /** Only ever set in `dev`. */
  attestBypassSecret: string | undefined;
  /** Only ever set in `dev`: the dev test issuer's key; undefined when the issuer is off. */
  devTestSigninSecret: string | undefined;
  /** Only ever set in `dev`. */
  xcodeStoreKitCert: Uint8Array | undefined;
}

const cache = new WeakMap<Env, Settings>();

export function readSettings(env: Env): Settings {
  const cached = cache.get(env);
  if (cached) return cached;
  const settings = parseSettings(env);
  cache.set(env, settings);
  return settings;
}

function parseSettings(env: Env): Settings {
  if (env.ENVIRONMENT !== "dev" && env.ENVIRONMENT !== "production") {
    throw new Error("ENVIRONMENT must be dev or production");
  }
  const production = env.ENVIRONMENT === "production";

  const credentialTTLSeconds = wholeNumber(env.CREDENTIAL_TTL_SECONDS, "CREDENTIAL_TTL_SECONDS");
  if (credentialTTLSeconds < 60 || credentialTTLSeconds > MAX_TTL_SECONDS) {
    throw new Error(`CREDENTIAL_TTL_SECONDS must be 60...${MAX_TTL_SECONDS}`);
  }
  const readOnlyDays = wholeNumber(env.READ_ONLY_DAYS, "READ_ONLY_DAYS");
  const deleteAfterDays = wholeNumber(env.DELETE_AFTER_DAYS, "DELETE_AFTER_DAYS");
  if (deleteAfterDays < readOnlyDays) {
    throw new Error("DELETE_AFTER_DAYS must not be less than READ_ONLY_DAYS");
  }
  if (deleteAfterDays < 1) throw new Error("DELETE_AFTER_DAYS must be at least 1");
  let parsed: unknown;
  try {
    parsed = JSON.parse(env.PRODUCT_ALLOWANCES);
  } catch {
    throw new Error("PRODUCT_ALLOWANCES is not JSON");
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("PRODUCT_ALLOWANCES must be an object of product ID to bytes");
  }
  const allowances = new Map<string, number>();
  for (const [productId, bytes] of Object.entries(parsed)) {
    if (typeof bytes !== "number" || !Number.isSafeInteger(bytes) || bytes <= 0) {
      throw new Error(`PRODUCT_ALLOWANCES: ${productId} must be a positive whole number of bytes`);
    }
    allowances.set(productId, bytes);
  }
  if (allowances.size === 0) throw new Error("PRODUCT_ALLOWANCES names no product");
  const sandboxAllowanceBytes = wholeNumber(env.SANDBOX_ALLOWANCE_BYTES, "SANDBOX_ALLOWANCE_BYTES");
  if (sandboxAllowanceBytes <= 0) throw new Error("SANDBOX_ALLOWANCE_BYTES must be positive");
  const usageCacheSeconds = wholeNumber(env.USAGE_CACHE_SECONDS, "USAGE_CACHE_SECONDS");
  if (usageCacheSeconds > 3600) throw new Error("USAGE_CACHE_SECONDS must be at most 3600");

  const bundleId = matching(env.APP_BUNDLE_ID, /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/, "APP_BUNDLE_ID");
  const teamId = matching(env.APPLE_TEAM_ID, /^[A-Z0-9]{10}$/, "APPLE_TEAM_ID");
  let appAppleId: number | undefined;
  if (env.APP_APPLE_ID) {
    appAppleId = Number(matching(env.APP_APPLE_ID, /^[1-9][0-9]{0,15}$/, "APP_APPLE_ID"));
  } else if (production) {
    throw new Error("APP_APPLE_ID is required in production");
  }

  const accountId = matching(env.R2_ACCOUNT_ID, /^[0-9a-f]{32}$/, "R2_ACCOUNT_ID");
  const s3Host = matching(
    env.R2_S3_HOST,
    production ? /^[0-9a-f]{32}(\.[a-z]{2,4})?\.r2\.cloudflarestorage\.com$/ : /^[a-z0-9.-]+(:[0-9]{1,5})?$/,
    "R2_S3_HOST",
  );
  const bucket = matching(env.R2_BUCKET_NAME, /^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/, "R2_BUCKET_NAME");
  if (!env.R2_PARENT_ACCESS_KEY_ID) throw new Error("R2_PARENT_ACCESS_KEY_ID is not set");
  if (!env.R2_PARENT_SECRET_ACCESS_KEY) throw new Error("R2_PARENT_SECRET_ACCESS_KEY is not set");
  if (!env.IDENTITY_KEY_SECRET || env.IDENTITY_KEY_SECRET.length < 32) {
    throw new Error("IDENTITY_KEY_SECRET must be at least 32 characters");
  }

  const googleClientIds = (env.GOOGLE_CLIENT_IDS ?? "")
    .split(",")
    .map((id) => id.trim())
    .filter((id) => id !== "");
  for (const id of googleClientIds) {
    if (!/^[0-9]{1,30}-[a-z0-9]{1,64}\.apps\.googleusercontent\.com$/.test(id)) {
      throw new Error("GOOGLE_CLIENT_IDS is malformed: a comma-separated list of OAuth client IDs");
    }
  }
  let subscriptionMoveDays = 30;
  if (env.SUBSCRIPTION_MOVE_DAYS !== undefined && env.SUBSCRIPTION_MOVE_DAYS !== "") {
    subscriptionMoveDays = wholeNumber(env.SUBSCRIPTION_MOVE_DAYS, "SUBSCRIPTION_MOVE_DAYS");
    if (subscriptionMoveDays < 1 || subscriptionMoveDays > 3650) throw new Error("SUBSCRIPTION_MOVE_DAYS must be 1...3650");
  }
  const siwa = readSiwaKey(env);

  // The development-only switches cannot be turned on in production: if any is present there,
  // the Worker refuses to serve at all, so the mistake is loud rather than silent.
  let attestBypassSecret: string | undefined;
  let devTestSigninSecret: string | undefined;
  let xcodeStoreKitCert: Uint8Array | undefined;
  if (production) {
    if (env.APP_ATTEST_BYPASS_SECRET !== undefined) {
      throw new Error("APP_ATTEST_BYPASS_SECRET must not exist in production: delete it");
    }
    if (env.DEV_TEST_SIGNIN_SECRET !== undefined) {
      throw new Error("DEV_TEST_SIGNIN_SECRET must not exist in production: delete it");
    }
    if (env.XCODE_STOREKIT_CERT) throw new Error("XCODE_STOREKIT_CERT must not be set in production");
  } else {
    if (env.APP_ATTEST_BYPASS_SECRET !== undefined && env.APP_ATTEST_BYPASS_SECRET !== "") {
      if (env.APP_ATTEST_BYPASS_SECRET.length < 32) {
        throw new Error("APP_ATTEST_BYPASS_SECRET must be at least 32 characters");
      }
      attestBypassSecret = env.APP_ATTEST_BYPASS_SECRET;
    }
    if (env.DEV_TEST_SIGNIN_SECRET !== undefined && env.DEV_TEST_SIGNIN_SECRET !== "") {
      if (env.DEV_TEST_SIGNIN_SECRET.length < 32) {
        throw new Error("DEV_TEST_SIGNIN_SECRET must be at least 32 characters");
      }
      devTestSigninSecret = env.DEV_TEST_SIGNIN_SECRET;
    }
    if (env.XCODE_STOREKIT_CERT) {
      try {
        xcodeStoreKitCert = fromBase64(env.XCODE_STOREKIT_CERT.replace(/\s+/g, ""));
        parseCertificate(xcodeStoreKitCert);
      } catch {
        throw new Error("XCODE_STOREKIT_CERT is not a base64 DER certificate");
      }
    }
  }

  return {
    environment: env.ENVIRONMENT,
    credentialTTLSeconds,
    readOnlyDays,
    deleteAfterDays,
    allowances,
    sandboxAllowanceBytes,
    usageCacheSeconds,
    bundleId,
    teamId,
    appId: `${teamId}.${bundleId}`,
    appAppleId,
    r2: {
      accountId,
      s3Host,
      bucket,
      parentAccessKeyId: env.R2_PARENT_ACCESS_KEY_ID,
      parentSecretAccessKey: env.R2_PARENT_SECRET_ACCESS_KEY,
    },
    identityKeySecret: env.IDENTITY_KEY_SECRET,
    googleClientIds,
    subscriptionMoveDays,
    siwa,
    attestBypassSecret,
    devTestSigninSecret,
    xcodeStoreKitCert,
  };
}

/**
 * The Sign in with Apple key: both values or neither. The PEM may arrive with its line breaks
 * written as a backslash and `n` (as some secret stores keep it). Only its shape is checked here; WebCrypto
 * imports it when it is used.
 */
function readSiwaKey(env: Env): Settings["siwa"] {
  const keyId = env.APPLE_SIWA_KEY_ID ?? "";
  const pem = env.APPLE_SIWA_PRIVATE_KEY ?? "";
  if (keyId === "" && pem === "") return undefined;
  if (keyId === "" || pem === "") throw new Error("APPLE_SIWA_KEY_ID and APPLE_SIWA_PRIVATE_KEY must be set together");
  matching(keyId, /^[A-Z0-9]{10}$/, "APPLE_SIWA_KEY_ID");
  const body = pem.replace(/\\n/g, "\n").trim();
  const match = /^-----BEGIN PRIVATE KEY-----\s+([A-Za-z0-9+/=\s]+?)\s*-----END PRIVATE KEY-----$/.exec(body);
  let der: Uint8Array;
  try {
    if (!match) throw new Error("no PEM");
    der = fromBase64(match[1]!.replace(/\s+/g, ""));
  } catch {
    throw new Error("APPLE_SIWA_PRIVATE_KEY is not a PKCS#8 PEM private key");
  }
  if (der.length < 32 || der[0] !== 0x30) throw new Error("APPLE_SIWA_PRIVATE_KEY is not a PKCS#8 PEM private key");
  return { keyId, privateKeyPkcs8: der };
}

function wholeNumber(value: string | undefined, name: string): number {
  if (value === undefined || !/^[0-9]+$/.test(value)) throw new Error(`${name} must be a whole number`);
  const number = Number(value);
  if (!Number.isSafeInteger(number)) throw new Error(`${name} must be a whole number`);
  return number;
}

function matching(value: string | undefined, pattern: RegExp, name: string): string {
  if (!value || !pattern.test(value)) throw new Error(`${name} is missing or malformed`);
  return value;
}
