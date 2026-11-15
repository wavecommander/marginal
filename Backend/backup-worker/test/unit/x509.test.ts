import { createHash } from "node:crypto";
import { describe, expect, it } from "vitest";
import { APPLE_APP_ATTESTATION_ROOT_CA, APPLE_ROOT_CA_G3 } from "../../src/appleRoots";
import { derSignatureToRaw, fromBase64, fromBase64Url, toBase64 } from "../../src/bytes";
import { decodeCbor } from "../../src/cbor";
import { oidToString, readOne, readTime } from "../../src/der";
import { parseCertificate, verifyChain } from "../../src/x509";
import { APPLE_SAMPLE } from "../fixtures/appleAppAttestSample";
import { appleLikeChain, issue, rawToDer } from "../helpers/pki";

function sampleChain(): Uint8Array[] {
  return [fromBase64(APPLE_SAMPLE.credentialCertificate), fromBase64(APPLE_SAMPLE.intermediate)];
}

describe("pinned Apple roots", () => {
  it("are the certificates Apple publishes (by SHA-256 fingerprint)", () => {
    expect(createHash("sha256").update(fromBase64(APPLE_ROOT_CA_G3)).digest("hex")).toBe(
      "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179",
    );
    expect(createHash("sha256").update(fromBase64(APPLE_APP_ATTESTATION_ROOT_CA)).digest("hex")).toBe(
      "1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932",
    );
  });

  it("parse, sign themselves and are P-384 CAs", async () => {
    for (const root of [APPLE_ROOT_CA_G3, APPLE_APP_ATTESTATION_ROOT_CA]) {
      const certificate = parseCertificate(fromBase64(root));
      expect(certificate.curve).toBe("P-384");
      expect(certificate.isCA).toBe(true);
      await verifyChain([certificate], new Date("2026-11-15T00:00:00Z"));
    }
  });

  it("Apple's real App Attest sample chains to the pinned App Attestation root", async () => {
    const [leaf, intermediate] = sampleChain().map((der) => parseCertificate(der));
    const root = parseCertificate(fromBase64(APPLE_APP_ATTESTATION_ROOT_CA));
    // Within the credential certificate's three days of validity.
    await verifyChain([leaf!, intermediate!, root], new Date("2026-04-21T12:00:00Z"));
    // After it.
    await expect(verifyChain([leaf!, intermediate!, root], new Date("2026-11-15T00:00:00Z"))).rejects.toThrow(/expired/);
    // Not to the App Store root.
    const g3 = parseCertificate(fromBase64(APPLE_ROOT_CA_G3));
    await expect(verifyChain([leaf!, intermediate!, g3], new Date("2026-04-21T12:00:00Z"))).rejects.toThrow(/names do not chain/);
  });
});

describe("verifyChain with generated certificates", () => {
  it("accepts a good chain and refuses a tampered certificate", async () => {
    const chain = await appleLikeChain();
    const parsed = [chain.leaf, chain.intermediate, chain.root].map((issued) => parseCertificate(issued.der));
    await verifyChain(parsed, new Date("2026-11-15T00:00:00Z"));

    // Flip one byte inside the leaf's subject name: the intermediate's signature no longer covers it.
    const tampered = chain.leaf.der.slice();
    const index = findBytes(tampered, new TextEncoder().encode("Receipt"));
    tampered[index] = tampered[index]! ^ 0x01;
    const bad = [parseCertificate(tampered), parsed[1]!, parsed[2]!];
    await expect(verifyChain(bad, new Date("2026-11-15T00:00:00Z"))).rejects.toThrow(/signature/);
  });

  it("refuses an issuer that is not a CA", async () => {
    const root = await issue({ name: "Root", ca: true });
    const notCA = await issue({ name: "Not a CA", issuer: root });
    const leaf = await issue({ name: "Leaf", issuer: notCA, curve: "P-256" });
    const parsed = [leaf, notCA, root].map((issued) => parseCertificate(issued.der));
    await expect(verifyChain(parsed, new Date("2026-11-15T00:00:00Z"))).rejects.toThrow(/not a CA/);
  });

  it("refuses certificates outside their validity dates", async () => {
    const chain = await appleLikeChain({ leafNotBefore: new Date("2026-01-01T00:00:00Z"), leafNotAfter: new Date("2026-06-01T00:00:00Z") });
    const parsed = [chain.leaf, chain.intermediate, chain.root].map((issued) => parseCertificate(issued.der));
    await verifyChain(parsed, new Date("2026-03-01T00:00:00Z"));
    await expect(verifyChain(parsed, new Date("2026-06-01T00:00:01Z"))).rejects.toThrow(/expired/);
    await expect(verifyChain(parsed, new Date("2025-12-31T23:58:00Z"))).rejects.toThrow(/not yet valid/);
  });
});

describe("strict decoding", () => {
  it("DER refuses indefinite and non-minimal lengths and trailing data", () => {
    expect(() => readOne(new Uint8Array([0x30, 0x80, 0x00, 0x00]))).toThrow(/indefinite/);
    expect(() => readOne(new Uint8Array([0x04, 0x81, 0x01, 0x00]))).toThrow(/non-minimal/);
    expect(() => readOne(new Uint8Array([0x05, 0x00, 0x00]))).toThrow(/trailing/);
    expect(() => readOne(new Uint8Array([0x04, 0x05, 0x00]))).toThrow(/truncated/);
  });

  it("reads OIDs and times", () => {
    expect(oidToString(new Uint8Array([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x08, 0x02]))).toBe("1.2.840.113635.100.8.2");
    expect(readTime(readOne(new Uint8Array([0x17, 0x0d, ...new TextEncoder().encode("260421181312Z")]))).toISOString()).toBe("2026-04-21T18:13:12.000Z");
    expect(() => readTime(readOne(new Uint8Array([0x17, 0x0d, ...new TextEncoder().encode("260231181312Z")])))).toThrow(/impossible/);
  });

  it("CBOR refuses trailing data, duplicate keys, tags and indefinite lengths", () => {
    expect(() => decodeCbor(new Uint8Array([0x01, 0x02]))).toThrow(/trailing/);
    expect(() => decodeCbor(new Uint8Array([0xa2, 0x01, 0x01, 0x01, 0x02]))).toThrow(/duplicate/);
    expect(() => decodeCbor(new Uint8Array([0xc0, 0x01]))).toThrow(/unsupported/);
    expect(() => decodeCbor(new Uint8Array([0x5f, 0x40, 0xff]))).toThrow(/unsupported length/);
    expect(decodeCbor(new Uint8Array([0x26]))).toBe(-7);
  });

  it("converts DER ECDSA signatures and refuses malformed ones", () => {
    const raw = new Uint8Array(64).map((_, i) => (i === 0 || i === 32 ? 0x80 : i));
    expect(derSignatureToRaw(rawToDer(raw), 32)).toEqual(raw);
    const der = rawToDer(raw);
    expect(() => derSignatureToRaw(new Uint8Array([...der, 0]), 32)).toThrow();
    expect(() => derSignatureToRaw(der.subarray(0, der.length - 1), 32)).toThrow();
  });

  it("base64 decoders refuse the wrong alphabet", () => {
    expect(() => fromBase64("ab-_")).toThrow();
    expect(() => fromBase64Url("ab+/")).toThrow();
    expect(toBase64(fromBase64("AQID"))).toBe("AQID");
  });
});

function findBytes(haystack: Uint8Array, needle: Uint8Array): number {
  outer: for (let i = 0; i <= haystack.length - needle.length; i++) {
    for (let j = 0; j < needle.length; j++) if (haystack[i + j] !== needle[j]) continue outer;
    return i;
  }
  throw new Error("not found");
}
