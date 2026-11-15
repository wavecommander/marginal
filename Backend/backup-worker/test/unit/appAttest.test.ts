import { beforeAll, describe, expect, it } from "vitest";
import { APPLE_APP_ATTESTATION_ROOT_CA } from "../../src/appleRoots";
import { attestPolicy, verifyAssertion, verifyAttestation, type AttestPolicy } from "../../src/appAttest";
import { fromBase64 } from "../../src/bytes";
import { APPLE_SAMPLE } from "../fixtures/appleAppAttestSample";
import { AAGUID_DEVELOPMENT, attestPki, defaultExtensions, makeAssertion, makeAttestation, newDevice, sha256, type AttestPki, type Device } from "../helpers/attest";
import { encodeCbor, type Encodable } from "../helpers/cborEncode";

const APP_ID = "TEAMID1234.software.tactile.marginal";
const NOW = new Date("2026-11-15T12:00:00Z");
const production = attestPolicy("production", APP_ID);
const development = attestPolicy("dev", APP_ID);

let pki: AttestPki;
let device: Device;
let clientDataHash: Uint8Array;

beforeAll(async () => {
  pki = await attestPki();
  device = await newDevice();
  clientDataHash = await sha256(new Uint8Array(32).fill(7));
});

function verify(attestation: Uint8Array, overrides: { keyId?: Uint8Array; clientDataHash?: Uint8Array; policy?: AttestPolicy; roots?: Uint8Array[]; now?: Date } = {}) {
  return verifyAttestation({
    attestation,
    keyId: overrides.keyId ?? device.keyId,
    clientDataHash: overrides.clientDataHash ?? clientDataHash,
    roots: overrides.roots ?? [pki.root.der],
    policy: overrides.policy ?? production,
    now: overrides.now ?? NOW,
  });
}

describe("Apple's own sample attestation", () => {
  // Rebuilt around Apple's real certificates and authenticator data (see the fixture's notes).
  function sampleObject(): Uint8Array {
    return encodeCbor(
      new Map<string, Encodable>([
        ["fmt", "apple-appattest"],
        ["attStmt", new Map<string, Encodable>([
          ["x5c", [fromBase64(APPLE_SAMPLE.credentialCertificate), fromBase64(APPLE_SAMPLE.intermediate)]],
          ["receipt", new Uint8Array([0])],
        ])],
        ["authData", fromBase64(APPLE_SAMPLE.authData)],
      ]),
    );
  }
  const samplePolicy: AttestPolicy = { appId: APPLE_SAMPLE.appId, environments: new Set(["production"]), validationCategories: new Set([1]) };

  it("passes every step against Apple's real root, within its validity", async () => {
    const result = await verifyAttestation({
      attestation: sampleObject(),
      keyId: fromBase64(APPLE_SAMPLE.keyId),
      // Apple's sample passed the raw challenge as clientDataHash.
      clientDataHash: new TextEncoder().encode(APPLE_SAMPLE.challenge),
      roots: [fromBase64(APPLE_APP_ATTESTATION_ROOT_CA)],
      policy: samplePolicy,
      now: new Date("2026-04-21T12:00:00Z"),
    });
    expect(result.environment).toBe("production");
    expect(result.publicKey.length).toBe(65);
  });

  it("is refused under this service's policy (category 1 is an OS executable) and after expiry", async () => {
    const input = {
      attestation: sampleObject(),
      keyId: fromBase64(APPLE_SAMPLE.keyId),
      clientDataHash: new TextEncoder().encode(APPLE_SAMPLE.challenge),
      roots: [fromBase64(APPLE_APP_ATTESTATION_ROOT_CA)],
    };
    await expect(verifyAttestation({ ...input, policy: { ...production, appId: APPLE_SAMPLE.appId }, now: new Date("2026-04-21T12:00:00Z") })).rejects.toThrow(/category 1/);
    await expect(verifyAttestation({ ...input, policy: samplePolicy, now: NOW })).rejects.toThrow(/expired/);
  });
});

describe("verifyAttestation", () => {
  it("accepts a valid attestation and returns the key", async () => {
    const result = await verify(await makeAttestation({ pki, device, appId: APP_ID, clientDataHash }));
    expect(result.publicKey).toEqual(device.publicPoint);
    expect(result.environment).toBe("production");
  });

  it("refuses the wrong challenge", async () => {
    const attestation = await makeAttestation({ pki, device, appId: APP_ID, clientDataHash });
    await expect(verify(attestation, { clientDataHash: await sha256("another challenge") })).rejects.toThrow(/nonce/);
  });

  it("refuses a nonce that does not cover the authenticator data", async () => {
    const attestation = await makeAttestation({ pki, device, appId: APP_ID, clientDataHash, nonce: new Uint8Array(32) });
    await expect(verify(attestation)).rejects.toThrow(/nonce/);
  });

  it("refuses another app's App ID", async () => {
    const attestation = await makeAttestation({ pki, device, appId: "OTHERTEAM1.com.example.other", clientDataHash });
    await expect(verify(attestation)).rejects.toThrow(/App ID/);
  });

  it("refuses a key ID that is not the key's hash, and a credential ID that is not the key ID", async () => {
    const attestation = await makeAttestation({ pki, device, appId: APP_ID, clientDataHash });
    await expect(verify(attestation, { keyId: new Uint8Array(32).fill(1) })).rejects.toThrow(/key ID/);
    const other = await makeAttestation({ pki, device, appId: APP_ID, clientDataHash, credentialId: new Uint8Array(32).fill(2) });
    await expect(verify(other)).rejects.toThrow(/credential ID/);
  });

  it("refuses a non-zero counter", async () => {
    await expect(verify(await makeAttestation({ pki, device, appId: APP_ID, clientDataHash, counter: 1 }))).rejects.toThrow(/counter/);
  });

  it("takes development keys only in dev", async () => {
    const attestation = await makeAttestation({ pki, device, appId: APP_ID, clientDataHash, aaguid: AAGUID_DEVELOPMENT });
    await expect(verify(attestation)).rejects.toThrow(/environment not accepted/);
    expect((await verify(attestation, { policy: development })).environment).toBe("development");
    const unknown = await makeAttestation({ pki, device, appId: APP_ID, clientDataHash, aaguid: new Uint8Array(16) });
    await expect(verify(unknown, { policy: development })).rejects.toThrow(/AAGUID/);
  });

  it("refuses a chain to another root", async () => {
    const otherPki = await attestPki();
    const attestation = await makeAttestation({ pki: otherPki, device, appId: APP_ID, clientDataHash });
    // Same names as the trusted chain, different keys: the signatures give it away.
    await expect(verify(attestation)).rejects.toThrow(/signature/);
    // Apple's real root does not vouch for a test chain either.
    await expect(verify(attestation, { roots: [fromBase64(APPLE_APP_ATTESTATION_ROOT_CA)] })).rejects.toThrow();
  });

  it("refuses an expired credential certificate", async () => {
    const attestation = await makeAttestation({ pki, device, appId: APP_ID, clientDataHash, notAfter: new Date("2026-06-01T00:00:00Z") });
    await expect(verify(attestation)).rejects.toThrow(/expired/);
  });

  it("checks the validation category: App Store and TestFlight in production, development builds only in dev", async () => {
    for (const category of [2, 4]) {
      await verify(await makeAttestation({ pki, device, appId: APP_ID, clientDataHash, extensions: defaultExtensions(category) }));
    }
    const developmentBuild = await makeAttestation({ pki, device, appId: APP_ID, clientDataHash, extensions: defaultExtensions(3) });
    await expect(verify(developmentBuild)).rejects.toThrow(/category 3/);
    await verify(developmentBuild, { policy: development });
    for (const category of [0, 1, 5, 6, 10]) {
      await expect(verify(await makeAttestation({ pki, device, appId: APP_ID, clientDataHash, extensions: defaultExtensions(category) }))).rejects.toThrow(/category/);
    }
  });

  it("reads the category as a CBOR integer too, refuses other encodings, and accepts no extensions", async () => {
    const integer = new Map<string, Encodable>([["apple_validation_category_01", 4], ["apple_bundle_version_01", "2"]]);
    await verify(await makeAttestation({ pki, device, appId: APP_ID, clientDataHash, extensions: integer }));
    const text = new Map<string, Encodable>([["apple_validation_category_01", "4"]]);
    await expect(verify(await makeAttestation({ pki, device, appId: APP_ID, clientDataHash, extensions: text }))).rejects.toThrow(/unreadable/);
    const badVersion = new Map<string, Encodable>([["apple_bundle_version_01", 5]]);
    await expect(verify(await makeAttestation({ pki, device, appId: APP_ID, clientDataHash, extensions: badVersion }))).rejects.toThrow(/bundle version/);
    await verify(await makeAttestation({ pki, device, appId: APP_ID, clientDataHash, extensions: null }));
  });

  it("refuses something that is not an attestation object", async () => {
    await expect(verify(encodeCbor(new Map([["fmt", "packed"]])))).rejects.toThrow();
    await expect(verify(new Uint8Array([1, 2, 3]))).rejects.toThrow();
  });
});

describe("verifyAssertion", () => {
  const clientData = new TextEncoder().encode('{"action":"session","challenge":"abc"}');

  function check(assertion: Uint8Array, overrides: { clientData?: Uint8Array; previousCounter?: number; policy?: AttestPolicy } = {}) {
    return verifyAssertion({
      assertion,
      clientData: overrides.clientData ?? clientData,
      publicKey: device.publicPoint,
      previousCounter: overrides.previousCounter ?? 0,
      policy: overrides.policy ?? production,
    });
  }

  it("accepts a valid assertion and returns its counter", async () => {
    expect(await check(await makeAssertion({ device, appId: APP_ID, clientData, counter: 1 }))).toEqual({ counter: 1 });
    expect(await check(await makeAssertion({ device, appId: APP_ID, clientData, counter: 9 }), { previousCounter: 8 })).toEqual({ counter: 9 });
  });

  it("refuses a counter that does not increase", async () => {
    await expect(check(await makeAssertion({ device, appId: APP_ID, clientData, counter: 5 }), { previousCounter: 5 })).rejects.toThrow(/counter/);
    await expect(check(await makeAssertion({ device, appId: APP_ID, clientData, counter: 4 }), { previousCounter: 5 })).rejects.toThrow(/counter/);
    await expect(check(await makeAssertion({ device, appId: APP_ID, clientData, counter: 0 }))).rejects.toThrow(/counter/);
  });

  it("refuses a signature over different client data, by another key, or tampered", async () => {
    const assertion = await makeAssertion({ device, appId: APP_ID, clientData, counter: 1 });
    await expect(check(assertion, { clientData: new TextEncoder().encode('{"action":"session","challenge":"abd"}') })).rejects.toThrow(/signature/);
    const stranger = await newDevice();
    await expect(check(await makeAssertion({ device, appId: APP_ID, clientData, counter: 1, signer: stranger.keys.privateKey }))).rejects.toThrow(/signature/);
    const tampered = assertion.slice();
    tampered[20] = tampered[20]! ^ 0x01; // inside the DER signature
    await expect(check(tampered)).rejects.toThrow();
  });

  it("refuses another app's App ID", async () => {
    await expect(check(await makeAssertion({ device, appId: "OTHERTEAM1.com.example.other", clientData, counter: 1 }))).rejects.toThrow(/App ID/);
  });

  it("checks extensions when the assertion carries them (iOS 27 style, with AT and ED flags)", async () => {
    const appStore = new Map<string, Encodable>([["validationCategory", 4], ["bundleVersion", "1.0"]]);
    await check(await makeAssertion({ device, appId: APP_ID, clientData, counter: 1, extensions: appStore, flags: 0xc0 }));
    const developmentBuild = new Map<string, Encodable>([["validationCategory", 3]]);
    await expect(check(await makeAssertion({ device, appId: APP_ID, clientData, counter: 1, extensions: developmentBuild }))).rejects.toThrow(/category 3/);
    await check(await makeAssertion({ device, appId: APP_ID, clientData, counter: 1, extensions: developmentBuild }), { policy: development });
  });
});
