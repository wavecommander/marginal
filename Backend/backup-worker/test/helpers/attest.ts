// Builds App Attest attestation and assertion objects the way Apple's are laid out, with a
// throwaway root standing in for Apple's App Attestation Root CA.

import "reflect-metadata";
import * as x509 from "@peculiar/x509";
import { encodeCbor, type Encodable } from "./cborEncode";
import { issue, rawToDer, type Issued } from "./pki";

const NONCE_OID = "1.2.840.113635.100.8.2";
export const AAGUID_PRODUCTION = new Uint8Array([...new TextEncoder().encode("appattest"), 0, 0, 0, 0, 0, 0, 0]);
export const AAGUID_DEVELOPMENT = new TextEncoder().encode("appattestdevelop");

export async function sha256(data: Uint8Array | string): Promise<Uint8Array> {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

function uint32(value: number): Uint8Array {
  return new Uint8Array([(value >>> 24) & 0xff, (value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff]);
}

export interface AttestPki {
  root: Issued;
  intermediate: Issued;
}

export async function attestPki(): Promise<AttestPki> {
  const root = await issue({ name: "Test App Attestation Root CA", ca: true, keyUsage: x509.KeyUsageFlags.keyCertSign | x509.KeyUsageFlags.cRLSign });
  const intermediate = await issue({ name: "Test App Attestation CA 1", issuer: root, ca: true, keyUsage: x509.KeyUsageFlags.keyCertSign | x509.KeyUsageFlags.cRLSign });
  return { root, intermediate };
}

export interface Device {
  keyId: Uint8Array;
  keys: CryptoKeyPair;
  publicPoint: Uint8Array;
}

export async function newDevice(): Promise<Device> {
  const keys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const publicPoint = new Uint8Array((await crypto.subtle.exportKey("raw", keys.publicKey)) as ArrayBuffer);
  return { keys, publicPoint, keyId: await sha256(publicPoint) };
}

export interface AttestationOptions {
  pki: AttestPki;
  device: Device;
  appId: string;
  /** The clientDataHash the app passed to attestKey. */
  clientDataHash: Uint8Array;
  aaguid?: Uint8Array;
  counter?: number;
  /** Override the credential ID (default: the key ID). */
  credentialId?: Uint8Array;
  /** Extensions map appended after the COSE key; `null` for none. */
  extensions?: Map<string, Encodable> | null;
  /** Override the nonce written into the certificate. */
  nonce?: Uint8Array;
  notAfter?: Date;
}

export function defaultExtensions(category = 4): Map<string, Encodable> {
  return new Map<string, Encodable>([
    ["apple_bundle_version_01", "1.0"],
    ["apple_validation_category_01", new Uint8Array([category, 0, 0, 0])],
  ]);
}

export async function makeAttestation(options: AttestationOptions): Promise<Uint8Array> {
  const { pki, device, appId } = options;
  const x = device.publicPoint.subarray(1, 33);
  const y = device.publicPoint.subarray(33, 65);
  const cose = encodeCbor(new Map<number, Encodable>([[1, 2], [3, -7], [-1, 1], [-2, x], [-3, y]]));
  const extensions = options.extensions === null ? new Uint8Array() : encodeCbor(options.extensions ?? defaultExtensions());
  const credentialId = options.credentialId ?? device.keyId;
  const authData = concat(
    await sha256(appId),
    new Uint8Array([0x40]),
    uint32(options.counter ?? 0),
    options.aaguid ?? AAGUID_PRODUCTION,
    new Uint8Array([credentialId.length >> 8, credentialId.length & 0xff]),
    credentialId,
    cose,
    extensions,
  );
  const nonce = options.nonce ?? (await sha256(concat(authData, options.clientDataHash)));
  // SEQUENCE { [1] { OCTET STRING nonce } }, as in Apple's credential certificates.
  const nonceExtension = new Uint8Array([0x30, 0x24, 0xa1, 0x22, 0x04, 0x20, ...nonce]);
  const credCert = await x509.X509CertificateGenerator.create({
    serialNumber: "0a",
    subject: "CN=credential",
    issuer: `CN=${pki.intermediate.name}`,
    notBefore: new Date("2026-01-01T00:00:00Z"),
    notAfter: options.notAfter ?? new Date("2027-01-01T00:00:00Z"),
    signingAlgorithm: { name: "ECDSA", hash: "SHA-256" },
    publicKey: device.keys.publicKey,
    signingKey: pki.intermediate.keys.privateKey,
    extensions: [new x509.Extension(NONCE_OID, false, nonceExtension)],
  });
  return encodeCbor(
    new Map<string, Encodable>([
      ["fmt", "apple-appattest"],
      ["attStmt", new Map<string, Encodable>([["x5c", [new Uint8Array(credCert.rawData), pki.intermediate.der]], ["receipt", new Uint8Array([1, 2, 3])]])],
      ["authData", authData],
    ]),
  );
}

export interface AssertionOptions {
  device: Device;
  appId: string;
  clientData: Uint8Array;
  counter: number;
  extensions?: Map<string, Encodable> | null;
  /** Sign with this key instead of the device's. */
  signer?: CryptoKey;
  flags?: number;
}

export async function makeAssertion(options: AssertionOptions): Promise<Uint8Array> {
  const extensions = options.extensions ? encodeCbor(options.extensions) : new Uint8Array();
  const authenticatorData = concat(
    await sha256(options.appId),
    new Uint8Array([options.flags ?? (extensions.length ? 0x80 : 0x00)]),
    uint32(options.counter),
    extensions,
  );
  const nonce = await sha256(concat(authenticatorData, await sha256(options.clientData)));
  const raw = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, options.signer ?? options.device.keys.privateKey, nonce));
  return encodeCbor(new Map<string, Encodable>([["signature", rawToDer(raw)], ["authenticatorData", authenticatorData]]));
}
