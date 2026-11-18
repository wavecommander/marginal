import { describe, expect, it } from "vitest";
import { devTestEntitlement, devTestEntitlementApplies } from "../../src/devEntitlement";
import { readSettings } from "../../src/env";
import { xcodeLikeCertificate, base64 } from "../helpers/pki";
import { GOOGLE_CLIENT_ID, OTHER_GOOGLE_CLIENT_ID, siwaKey } from "../helpers/oidc";
import { APP_ID, BYPASS_SECRET, DEV_SIGNIN_SECRET, PRODUCT, testEnv } from "../helpers/settings";

describe("readSettings", () => {
  it("reads a complete production configuration", () => {
    const settings = readSettings(testEnv());
    expect(settings.environment).toBe("production");
    expect(settings.appId).toBe(APP_ID);
    expect(settings.attestBypassSecret).toBeUndefined();
    expect(settings.xcodeStoreKitCert).toBeUndefined();
  });

  it("refuses to start in production if the App Attest bypass secret exists at all", () => {
    expect(() => readSettings(testEnv({ APP_ATTEST_BYPASS_SECRET: BYPASS_SECRET }))).toThrow(/must not exist in production/);
    expect(() => readSettings(testEnv({ APP_ATTEST_BYPASS_SECRET: "" }))).toThrow(/must not exist in production/);
  });

  it("refuses to start in production if the dev test sign-in secret exists at all, naming it but never its value", () => {
    expect(readSettings(testEnv()).devTestSigninSecret).toBeUndefined();
    for (const value of [DEV_SIGNIN_SECRET, "", "short-secret-value"]) {
      let message = "";
      try {
        readSettings(testEnv({ DEV_TEST_SIGNIN_SECRET: value }));
      } catch (error) {
        message = (error as Error).message;
      }
      expect(message).toMatch(/DEV_TEST_SIGNIN_SECRET must not exist in production/);
      expect(message).not.toContain("short-secret-value");
      expect(message).not.toContain(DEV_SIGNIN_SECRET);
    }
  });

  it("takes the dev test sign-in secret in dev: off when empty or absent, at least 32 characters", () => {
    const dev = { ENVIRONMENT: "dev", R2_S3_HOST: "localhost:8787", APP_APPLE_ID: "" };
    expect(readSettings(testEnv({ ...dev, DEV_TEST_SIGNIN_SECRET: DEV_SIGNIN_SECRET })).devTestSigninSecret).toBe(DEV_SIGNIN_SECRET);
    expect(readSettings(testEnv({ ...dev, DEV_TEST_SIGNIN_SECRET: "" })).devTestSigninSecret).toBeUndefined();
    expect(readSettings(testEnv(dev)).devTestSigninSecret).toBeUndefined();
    let message = "";
    try {
      readSettings(testEnv({ ...dev, DEV_TEST_SIGNIN_SECRET: "short-secret-value" }));
    } catch (error) {
      message = (error as Error).message;
    }
    expect(message).toMatch(/DEV_TEST_SIGNIN_SECRET must be at least 32 characters/);
    expect(message).not.toContain("short-secret-value");
  });

  it("refuses to start in production if the dev test entitlement exists at all, naming it but never its value", () => {
    expect(readSettings(testEnv()).devTestEntitlement).toBeUndefined();
    for (const value of [PRODUCT, "", "short-secret-value"]) {
      let message = "";
      try {
        readSettings(testEnv({ DEV_TEST_ENTITLEMENT: value }));
      } catch (error) {
        message = (error as Error).message;
      }
      expect(message).toMatch(/DEV_TEST_ENTITLEMENT must not exist in production/);
      expect(message).not.toContain("short-secret-value");
    }
  });

  it("takes the dev test entitlement in dev: off when empty or absent, a product of PRODUCT_ALLOWANCES", () => {
    const dev = { ENVIRONMENT: "dev", R2_S3_HOST: "localhost:8787", APP_APPLE_ID: "" };
    expect(readSettings(testEnv({ ...dev, DEV_TEST_ENTITLEMENT: PRODUCT })).devTestEntitlement).toBe(PRODUCT);
    expect(readSettings(testEnv({ ...dev, DEV_TEST_ENTITLEMENT: ` ${PRODUCT} ` })).devTestEntitlement).toBe(PRODUCT);
    expect(readSettings(testEnv({ ...dev, DEV_TEST_ENTITLEMENT: "" })).devTestEntitlement).toBeUndefined();
    expect(readSettings(testEnv(dev)).devTestEntitlement).toBeUndefined();
    expect(() => readSettings(testEnv({ ...dev, DEV_TEST_ENTITLEMENT: "on" }))).toThrow(/DEV_TEST_ENTITLEMENT must be a product ID in PRODUCT_ALLOWANCES/);
  });

  it("the dev test entitlement checks the environment, the issuer and the identity again at use", () => {
    const dev = readSettings(testEnv({ ENVIRONMENT: "dev", R2_S3_HOST: "localhost:8787", APP_APPLE_ID: "", DEV_TEST_SIGNIN_SECRET: DEV_SIGNIN_SECRET, DEV_TEST_ENTITLEMENT: PRODUCT }));
    const account = { accountId: "0123456789abcdef0123456789abcdef", folderKey: "f".repeat(64), provider: "apple" as const, identityHash: "a".repeat(64), devTest: true, appAccountToken: "6f9619ff-8b86-d011-b42d-00c04fc964ff", createdAt: 0, identityChangedAt: 0, deletingSince: null };
    const now = Date.parse("2026-11-15T12:00:00Z");
    expect(devTestEntitlement(account, dev, now)).toMatchObject({ namespace: "sandbox", environment: "Xcode", productId: PRODUCT, subscriptionKey: null });
    expect(devTestEntitlementApplies(account, dev)).toBe(true);
    // Settings that claim production (whatever made them), no issuer, an unknown product, a real identity.
    for (const settings of [
      { ...dev, environment: "production" as const },
      { ...dev, devTestSigninSecret: undefined },
      { ...dev, devTestEntitlement: "software.tactile.texts.backup.unknown" },
      { ...dev, devTestEntitlement: undefined },
    ]) {
      expect(devTestEntitlement(account, settings, now)).toBeUndefined();
      expect(devTestEntitlementApplies(account, settings)).toBe(false);
    }
    expect(devTestEntitlement({ ...account, devTest: false }, dev, now)).toBeUndefined();
  });

  it("refuses to start in production with an Xcode test certificate", async () => {
    const cert = await xcodeLikeCertificate();
    expect(() => readSettings(testEnv({ XCODE_STOREKIT_CERT: base64(cert.der) }))).toThrow(/XCODE_STOREKIT_CERT/);
  });

  it("takes both in dev, checked", async () => {
    const cert = await xcodeLikeCertificate();
    const settings = readSettings(testEnv({ ENVIRONMENT: "dev", APP_ATTEST_BYPASS_SECRET: BYPASS_SECRET, XCODE_STOREKIT_CERT: base64(cert.der) }));
    expect(settings.attestBypassSecret).toBe(BYPASS_SECRET);
    expect(settings.xcodeStoreKitCert).toEqual(cert.der);
    expect(() => readSettings(testEnv({ ENVIRONMENT: "dev", APP_ATTEST_BYPASS_SECRET: "short" }))).toThrow(/32/);
    expect(() => readSettings(testEnv({ ENVIRONMENT: "dev", XCODE_STOREKIT_CERT: "bm90IGEgY2VydA==" }))).toThrow(/certificate/);
  });

  it("names the setting that is missing or wrong, never its value", () => {
    const cases: [Record<string, unknown>, RegExp][] = [
      [{ ENVIRONMENT: "staging" }, /ENVIRONMENT/],
      [{ APPLE_TEAM_ID: "" }, /APPLE_TEAM_ID/],
      [{ APP_APPLE_ID: "" }, /APP_APPLE_ID/],
      [{ R2_ACCOUNT_ID: "" }, /R2_ACCOUNT_ID/],
      [{ R2_S3_HOST: "localhost:8787" }, /R2_S3_HOST/],
      [{ R2_BUCKET_NAME: "Bad_Name" }, /R2_BUCKET_NAME/],
      [{ CREDENTIAL_TTL_SECONDS: "7200" }, /CREDENTIAL_TTL_SECONDS/],
      [{ READ_ONLY_DAYS: "61" }, /DELETE_AFTER_DAYS/],
      [{ PRODUCT_ALLOWANCES: "{}" }, /PRODUCT_ALLOWANCES/],
      [{ SANDBOX_ALLOWANCE_BYTES: "-1" }, /SANDBOX_ALLOWANCE_BYTES/],
      [{ IDENTITY_KEY_SECRET: "short-secret-value" }, /IDENTITY_KEY_SECRET/],
      [{ IDENTITY_KEY_SECRET: undefined }, /IDENTITY_KEY_SECRET/],
      [{ GOOGLE_CLIENT_IDS: "short-secret-value" }, /GOOGLE_CLIENT_IDS/],
      [{ SUBSCRIPTION_MOVE_DAYS: "0" }, /SUBSCRIPTION_MOVE_DAYS/],
      [{ SUBSCRIPTION_MOVE_DAYS: "thirty" }, /SUBSCRIPTION_MOVE_DAYS/],
      [{ APPLE_SIWA_KEY_ID: "SIWAKEY123" }, /APPLE_SIWA_KEY_ID and APPLE_SIWA_PRIVATE_KEY/],
      [{ APPLE_SIWA_PRIVATE_KEY: "short-secret-value" }, /APPLE_SIWA_KEY_ID and APPLE_SIWA_PRIVATE_KEY/],
      [{ APPLE_SIWA_KEY_ID: "SIWAKEY123", APPLE_SIWA_PRIVATE_KEY: "short-secret-value" }, /APPLE_SIWA_PRIVATE_KEY is not/],
      [{ APPLE_SIWA_KEY_ID: "bad", APPLE_SIWA_PRIVATE_KEY: "short-secret-value" }, /APPLE_SIWA_KEY_ID/],
      [{ R2_PARENT_SECRET_ACCESS_KEY: "" }, /R2_PARENT_SECRET_ACCESS_KEY/],
    ];
    for (const [overrides, pattern] of cases) {
      let message = "";
      try {
        readSettings(testEnv(overrides));
      } catch (error) {
        message = (error as Error).message;
      }
      expect(message).toMatch(pattern);
      expect(message).not.toContain("short-secret-value");
    }
  });

  it("reads the account settings: Google client IDs, the move window, the optional Sign in with Apple key", async () => {
    const settings = readSettings(testEnv({ GOOGLE_CLIENT_IDS: ` ${GOOGLE_CLIENT_ID} , ${OTHER_GOOGLE_CLIENT_ID}`, SUBSCRIPTION_MOVE_DAYS: "7" }));
    expect(settings.googleClientIds).toEqual([GOOGLE_CLIENT_ID, OTHER_GOOGLE_CLIENT_ID]);
    expect(settings.subscriptionMoveDays).toBe(7);
    expect(settings.siwa).toBeUndefined();
    const defaults = readSettings(testEnv({ GOOGLE_CLIENT_IDS: "", SUBSCRIPTION_MOVE_DAYS: undefined }));
    expect(defaults.googleClientIds).toEqual([]);
    expect(defaults.subscriptionMoveDays).toBe(30);
    const { pem } = await siwaKey();
    const withKey = readSettings(testEnv({ APPLE_SIWA_KEY_ID: "SIWAKEY123", APPLE_SIWA_PRIVATE_KEY: pem }));
    expect(withKey.siwa?.keyId).toBe("SIWAKEY123");
    expect(withKey.teamId).toBe("TEAMID1234");
  });

  it("allows a local S3 host and no app Apple ID in dev", () => {
    const settings = readSettings(testEnv({ ENVIRONMENT: "dev", R2_S3_HOST: "localhost:8787", APP_APPLE_ID: "" }));
    expect(settings.r2.s3Host).toBe("localhost:8787");
    expect(settings.appAppleId).toBeUndefined();
  });
});
