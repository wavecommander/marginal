import { describe, expect, it } from "vitest";
import { readSettings } from "../../src/env";
import { xcodeLikeCertificate, base64 } from "../helpers/pki";
import { APP_ID, BYPASS_SECRET, testEnv } from "../helpers/settings";

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
      [{ USER_KEY_SECRET: "short-secret-value" }, /USER_KEY_SECRET/],
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

  it("allows a local S3 host and no app Apple ID in dev", () => {
    const settings = readSettings(testEnv({ ENVIRONMENT: "dev", R2_S3_HOST: "localhost:8787", APP_APPLE_ID: "" }));
    expect(settings.r2.s3Host).toBe("localhost:8787");
    expect(settings.appAppleId).toBeUndefined();
  });
});
