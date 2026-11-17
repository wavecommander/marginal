import { beforeAll, describe, expect, it } from "vitest";
import { verifyNotification, verifyRenewalInfo, verifyTransaction, type VerifyContext } from "../../src/appleJws";
import { APPLE_ROOT_CA_G3 } from "../../src/appleRoots";
import { fromBase64 } from "../../src/bytes";
import { readSettings } from "../../src/env";
import { Refusal } from "../../src/http";
import { DAY, notificationPayload, renewalPayload, transactionPayload } from "../helpers/apple";
import { appleLikeChain, base64, base64url, signJws, signWithChain, xcodeLikeCertificate, type AppleChain, type Issued } from "../helpers/pki";
import { APP_APPLE_ID, BUNDLE_ID, testEnv } from "../helpers/settings";

const NOW = new Date("2026-11-15T12:00:00Z");
let chain: AppleChain;
let xcode: Issued;

beforeAll(async () => {
  chain = await appleLikeChain();
  xcode = await xcodeLikeCertificate();
});

function context(environment: "dev" | "production" = "production", extra: Record<string, unknown> = {}): VerifyContext {
  const settings = readSettings(testEnv({ ENVIRONMENT: environment, ...extra }));
  return { settings, trust: { appleRoots: [chain.root.der], xcodeRoot: settings.xcodeStoreKitCert }, now: NOW };
}

async function refusal(promise: Promise<unknown>): Promise<string> {
  try {
    await promise;
  } catch (error) {
    if (error instanceof Refusal) return `${error.code}: ${error.detail}`;
    throw error;
  }
  throw new Error("expected a refusal");
}

describe("verifyTransaction", () => {
  it("accepts a valid App Store transaction", async () => {
    const transaction = await verifyTransaction(await signWithChain(transactionPayload(), chain), context());
    expect(transaction).toMatchObject({
      originalTransactionId: "2000000000000001",
      productId: "software.tactile.texts.backup.standard",
      environment: "Production",
      revocationDate: undefined,
    });
  });

  it("refuses another app's transaction", async () => {
    expect(await refusal(verifyTransaction(await signWithChain(transactionPayload({ bundleId: "com.example.other" }), chain), context()))).toMatch(/^transaction-invalid: bundle/);
  });

  it("refuses a product that is not a backup product, or not a subscription", async () => {
    expect(await refusal(verifyTransaction(await signWithChain(transactionPayload({ productId: "software.tactile.texts.tip" }), chain), context()))).toMatch(/^product-unknown/);
    expect(await refusal(verifyTransaction(await signWithChain(transactionPayload({ type: "Non-Renewing Subscription" }), chain), context()))).toMatch(/^product-unknown/);
  });

  it("reads the appAccountToken in lower case, and refuses one that is not a UUID", async () => {
    const tokened = await verifyTransaction(await signWithChain(transactionPayload({ appAccountToken: "6F9619FF-8B86-D011-B42D-00C04FC964FF" }), chain), context());
    expect(tokened.appAccountToken).toBe("6f9619ff-8b86-d011-b42d-00c04fc964ff");
    expect((await verifyTransaction(await signWithChain(transactionPayload(), chain), context())).appAccountToken).toBeUndefined();
    expect(await refusal(verifyTransaction(await signWithChain(transactionPayload({ appAccountToken: 7 }), chain), context()))).toMatch(/^transaction-invalid: app account token/);
  });

  it("passes the revocation date on (the session refuses it)", async () => {
    const revokedAt = Date.parse("2026-11-10T00:00:00Z");
    const transaction = await verifyTransaction(await signWithChain(transactionPayload({ revocationDate: revokedAt, revocationReason: 0 }), chain), context());
    expect(transaction.revocationDate).toBe(revokedAt);
  });

  it("accepts Production and Sandbox in production, and refuses Production in dev", async () => {
    await verifyTransaction(await signWithChain(transactionPayload({ environment: "Sandbox" }), chain), context());
    expect(await refusal(verifyTransaction(await signWithChain(transactionPayload(), chain), context("dev")))).toMatch(/^environment-not-accepted/);
    await verifyTransaction(await signWithChain(transactionPayload({ environment: "Sandbox" }), chain), context("dev"));
  });

  it("refuses a chain to an untrusted root", async () => {
    const stranger = await appleLikeChain();
    expect(await refusal(verifyTransaction(await signWithChain(transactionPayload(), stranger), context()))).toMatch(/root is not trusted/);
    // Swapping in the trusted root's bytes does not help: the intermediate was not signed by it.
    const forged = await signJws(transactionPayload(), [stranger.leaf.der, stranger.intermediate.der, chain.root.der], stranger.leaf.keys.privateKey);
    expect(await refusal(verifyTransaction(forged, context()))).toMatch(/signature|chain/);
    // And the real Apple root does not vouch for test certificates.
    const real = { ...context(), trust: { appleRoots: [fromBase64(APPLE_ROOT_CA_G3)] } };
    expect(await refusal(verifyTransaction(await signWithChain(transactionPayload(), chain), real))).toMatch(/root is not trusted/);
  });

  it("refuses a tampered payload", async () => {
    const jws = await signWithChain(transactionPayload(), chain);
    const [header, , signature] = jws.split(".");
    const altered = base64url(new TextEncoder().encode(JSON.stringify(transactionPayload({ expiresDate: Date.parse("2099-01-01T00:00:00Z") }))));
    expect(await refusal(verifyTransaction(`${header}.${altered}.${signature}`, context()))).toMatch(/bad signature/);
  });

  it("refuses a certificate expired when the payload was signed, but not one that expired later", async () => {
    const short = await appleLikeChain({ leafNotBefore: new Date("2026-01-01T00:00:00Z"), leafNotAfter: new Date("2026-06-01T00:00:00Z") });
    const local = { ...context(), trust: { appleRoots: [short.root.der] } };
    const late = transactionPayload({ signedDate: Date.parse("2026-07-01T00:00:00Z") });
    expect(await refusal(verifyTransaction(await signWithChain(late, short), local))).toMatch(/expired/);
    // Signed while the certificate was valid: still valid now (Apple's rule without online checks).
    const early = transactionPayload({ signedDate: Date.parse("2026-05-01T00:00:00Z") });
    await verifyTransaction(await signWithChain(early, short), local);
  });

  it("refuses a chain without Apple's marker extensions", async () => {
    const noLeafMarker = await appleLikeChain({ leafMarker: false });
    expect(await refusal(verifyTransaction(await signWithChain(transactionPayload(), noLeafMarker), { ...context(), trust: { appleRoots: [noLeafMarker.root.der] } }))).toMatch(/marker/);
    const noIntermediateMarker = await appleLikeChain({ intermediateMarker: false });
    expect(await refusal(verifyTransaction(await signWithChain(transactionPayload(), noIntermediateMarker), { ...context(), trust: { appleRoots: [noIntermediateMarker.root.der] } }))).toMatch(/marker/);
  });

  it("refuses other algorithms, a short chain and a signature from another key", async () => {
    const payload = transactionPayload();
    const x5c = [chain.leaf.der, chain.intermediate.der, chain.root.der];
    expect(await refusal(verifyTransaction(await signJws(payload, x5c, chain.leaf.keys.privateKey, { alg: "none" }), context()))).toMatch(/ES256/);
    expect(await refusal(verifyTransaction(await signJws(payload, x5c.slice(0, 2), chain.leaf.keys.privateKey), context()))).toMatch(/chain/);
    expect(await refusal(verifyTransaction(await signJws(payload, x5c, chain.intermediate.keys.privateKey), context()))).toMatch(/signature/);
    expect(await refusal(verifyTransaction("not.a.jws", context()))).toMatch(/^transaction-invalid/);
  });

  it("refuses a payload signed in the future", async () => {
    const future = transactionPayload({ signedDate: NOW.getTime() + DAY });
    expect(await refusal(verifyTransaction(await signWithChain(future, chain), context()))).toMatch(/future/);
  });
});

describe("the Xcode environment", () => {
  async function xcodeTransaction(environment = "Xcode"): Promise<string> {
    return signJws(transactionPayload({ environment }), [xcode.der], xcode.keys.privateKey);
  }

  it("is accepted in dev with the configured test certificate", async () => {
    const transaction = await verifyTransaction(await xcodeTransaction(), context("dev", { XCODE_STOREKIT_CERT: base64(xcode.der) }));
    expect(transaction.environment).toBe("Xcode");
  });

  it("is refused in dev without it, or with another certificate", async () => {
    expect(await refusal(verifyTransaction(await xcodeTransaction(), context("dev")))).toMatch(/^transaction-invalid/);
    const other = await xcodeLikeCertificate();
    expect(await refusal(verifyTransaction(await xcodeTransaction(), context("dev", { XCODE_STOREKIT_CERT: base64(other.der) })))).toMatch(/^transaction-invalid/);
  });

  it("is refused in production, even if the trust list somehow held the certificate", async () => {
    const production = context("production");
    const smuggled = { ...production, trust: { appleRoots: [chain.root.der], xcodeRoot: xcode.der } };
    expect(await refusal(verifyTransaction(await xcodeTransaction(), smuggled))).toMatch(/^transaction-invalid/);
    // And an Apple-signed payload claiming Xcode is refused everywhere.
    expect(await refusal(verifyTransaction(await signWithChain(transactionPayload({ environment: "Xcode" }), chain), production))).toMatch(/Xcode/);
  });

  it("cannot vouch for a Production or Sandbox payload", async () => {
    const dev = context("dev", { XCODE_STOREKIT_CERT: base64(xcode.der) });
    expect(await refusal(verifyTransaction(await xcodeTransaction("Sandbox"), dev))).toMatch(/Xcode signature/);
  });
});

describe("verifyRenewalInfo and verifyNotification", () => {
  it("read renewal info", async () => {
    const renewal = await verifyRenewalInfo(await signWithChain(renewalPayload({ isInBillingRetryPeriod: true, gracePeriodExpiresDate: Date.parse("2026-11-20T00:00:00Z") }), chain), context());
    expect(renewal).toMatchObject({ originalTransactionId: "2000000000000001", isInBillingRetryPeriod: true });
  });

  it("read a notification and check its bundle and Apple ID", async () => {
    const payload = notificationPayload("DID_RENEW", undefined, { signedTransactionInfo: "x.y.z" });
    const notification = await verifyNotification(await signWithChain(payload, chain), context());
    expect(notification).toMatchObject({ notificationType: "DID_RENEW", environment: "Production", signedTransactionInfo: "x.y.z" });

    const wrongApp = notificationPayload("DID_RENEW", undefined, { appAppleId: APP_APPLE_ID + 1 });
    expect(await refusal(verifyNotification(await signWithChain(wrongApp, chain), context()))).toMatch(/Apple ID/);
    const wrongBundle = notificationPayload("DID_RENEW", undefined, { bundleId: `${BUNDLE_ID}.other` });
    expect(await refusal(verifyNotification(await signWithChain(wrongBundle, chain), context()))).toMatch(/bundle/);
    // Sandbox notifications carry no Apple ID.
    const sandbox = notificationPayload("DID_RENEW", undefined, { environment: "Sandbox", appAppleId: undefined });
    await verifyNotification(await signWithChain(sandbox, chain), context());
  });

  it("refuse a forged notification", async () => {
    const stranger = await appleLikeChain();
    expect(await refusal(verifyNotification(await signWithChain(notificationPayload("REFUND", undefined, {}), stranger), context()))).toMatch(/^notification-invalid/);
  });
});
