// Made-up settings for tests. None of these values opens anything real.

import type { Env } from "../../src/env";
import { GOOGLE_CLIENT_ID } from "./oidc";

export const BUNDLE_ID = "software.tactile.texts";
export const PRODUCT = "software.tactile.texts.backup.standard";
export const OTHER_PRODUCT = "software.tactile.texts.backup.large";
export const TEAM_ID = "TEAMID1234";
export const APP_ID = `${TEAM_ID}.${BUNDLE_ID}`;
export const APP_APPLE_ID = 1234567890;
export const ALLOWANCE = 10_000;
export const SANDBOX_ALLOWANCE = 1_000;
export const BYPASS_SECRET = "dev-bypass-secret-0123456789abcdef-not-real";
export const SIWA_KEY_ID = "SIWAKEY123";
export const SECRET_VALUES = [
  "test-parent-secret-access-key-not-real",
  "test-identity-key-secret-0123456789abcdef-not-real",
  BYPASS_SECRET,
];

/** The variables and secrets, without bindings. */
export function testVars(overrides: Partial<Record<keyof Env, unknown>> = {}): Omit<Env, "DB" | "BUCKET"> {
  return {
    ENVIRONMENT: "production",
    R2_ACCOUNT_ID: "0123456789abcdef0123456789abcdef",
    R2_S3_HOST: "0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com",
    R2_BUCKET_NAME: "tactile-texts-backups",
    APP_BUNDLE_ID: BUNDLE_ID,
    APPLE_TEAM_ID: TEAM_ID,
    APP_APPLE_ID: String(APP_APPLE_ID),
    CREDENTIAL_TTL_SECONDS: "900",
    READ_ONLY_DAYS: "30",
    DELETE_AFTER_DAYS: "60",
    PRODUCT_ALLOWANCES: JSON.stringify({ [PRODUCT]: ALLOWANCE, [OTHER_PRODUCT]: ALLOWANCE * 10 }),
    SANDBOX_ALLOWANCE_BYTES: String(SANDBOX_ALLOWANCE),
    USAGE_CACHE_SECONDS: "300",
    XCODE_STOREKIT_CERT: "",
    R2_PARENT_ACCESS_KEY_ID: "test-parent-access-key-id",
    R2_PARENT_SECRET_ACCESS_KEY: SECRET_VALUES[0]!,
    IDENTITY_KEY_SECRET: SECRET_VALUES[1]!,
    GOOGLE_CLIENT_IDS: GOOGLE_CLIENT_ID,
    SUBSCRIPTION_MOVE_DAYS: "30",
    ...overrides,
  } as Omit<Env, "DB" | "BUCKET">;
}

export function testEnv(overrides: Partial<Record<keyof Env, unknown>> = {}): Env {
  return { DB: undefined as unknown as D1Database, BUCKET: undefined as unknown as R2Bucket, ...testVars(overrides) } as Env;
}
