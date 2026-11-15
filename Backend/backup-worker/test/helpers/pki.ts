// Throwaway certificate chains that imitate Apple's, built with an independent X.509 library
// (@peculiar/x509), and JWS signed with them. Nothing here is a real key or certificate.

import "reflect-metadata";
import * as x509 from "@peculiar/x509";

export const LEAF_MARKER = "1.2.840.113635.100.6.11.1";
export const INTERMEDIATE_MARKER = "1.2.840.113635.100.6.2.1";

const P256 = { name: "ECDSA", namedCurve: "P-256", hash: "SHA-256" } as const;
const P384 = { name: "ECDSA", namedCurve: "P-384", hash: "SHA-384" } as const;

export interface Issued {
  der: Uint8Array;
  keys: CryptoKeyPair;
  name: string;
}

let serial = 1;

async function keyPair(algorithm: typeof P256 | typeof P384): Promise<CryptoKeyPair> {
  return (await crypto.subtle.generateKey(algorithm, true, ["sign", "verify"])) as CryptoKeyPair;
}

export async function issue(options: {
  name: string;
  issuer?: Issued;
  curve?: "P-256" | "P-384";
  ca?: boolean;
  notBefore?: Date;
  notAfter?: Date;
  extensions?: x509.Extension[];
  keyUsage?: number;
}): Promise<Issued> {
  const algorithm = options.curve === "P-256" ? P256 : P384;
  const keys = await keyPair(algorithm);
  const signer = options.issuer;
  const signingAlgorithm = signer ? (signer.keys.privateKey.algorithm as { namedCurve?: string }).namedCurve === "P-256" ? P256 : P384 : algorithm;
  const extensions: x509.Extension[] = [...(options.extensions ?? [])];
  if (options.ca) extensions.push(new x509.BasicConstraintsExtension(true, undefined, true));
  if (options.keyUsage !== undefined) extensions.push(new x509.KeyUsagesExtension(options.keyUsage, true));
  const certificate = await x509.X509CertificateGenerator.create({
    serialNumber: (serial++).toString(16).padStart(2, "0"),
    subject: `CN=${options.name}`,
    issuer: signer ? `CN=${signer.name}` : `CN=${options.name}`,
    notBefore: options.notBefore ?? new Date("2020-01-01T00:00:00Z"),
    notAfter: options.notAfter ?? new Date("2040-01-01T00:00:00Z"),
    signingAlgorithm,
    publicKey: keys.publicKey,
    signingKey: signer ? signer.keys.privateKey : keys.privateKey,
    extensions,
  });
  return { der: new Uint8Array(certificate.rawData), keys, name: options.name };
}

export function marker(oid: string): x509.Extension {
  // Apple's markers carry a NULL value.
  return new x509.Extension(oid, false, new Uint8Array([0x05, 0x00]));
}

export interface AppleChain {
  root: Issued;
  intermediate: Issued;
  leaf: Issued;
}

/** A chain shaped like the App Store's: P-384 root and intermediate, P-256 leaf, Apple's markers. */
export async function appleLikeChain(options: { leafNotAfter?: Date; leafNotBefore?: Date; leafMarker?: boolean; intermediateMarker?: boolean } = {}): Promise<AppleChain> {
  const root = await issue({ name: "Test Root CA - G3", ca: true, keyUsage: x509.KeyUsageFlags.keyCertSign | x509.KeyUsageFlags.cRLSign });
  const intermediate = await issue({
    name: "Test Worldwide Developer Relations",
    issuer: root,
    ca: true,
    keyUsage: x509.KeyUsageFlags.keyCertSign | x509.KeyUsageFlags.cRLSign,
    extensions: options.intermediateMarker === false ? [] : [marker(INTERMEDIATE_MARKER)],
  });
  const leaf = await issue({
    name: "Test App Store Receipt Signing",
    issuer: intermediate,
    curve: "P-256",
    keyUsage: x509.KeyUsageFlags.digitalSignature,
    notBefore: options.leafNotBefore,
    notAfter: options.leafNotAfter,
    extensions: options.leafMarker === false ? [] : [marker(LEAF_MARKER)],
  });
  return { root, intermediate, leaf };
}

/** A self-signed P-256 certificate like Xcode's StoreKit test certificate. */
export async function xcodeLikeCertificate(): Promise<Issued> {
  return issue({ name: "StoreKit Testing in Xcode", curve: "P-256", keyUsage: x509.KeyUsageFlags.digitalSignature });
}

export function base64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

export function base64url(bytes: Uint8Array): string {
  return base64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/** Compact JWS, ES256, with `x5c` = the given certificates, signed by `signer`. */
export async function signJws(payload: unknown, x5c: Uint8Array[], signer: CryptoKey, header: Record<string, unknown> = {}): Promise<string> {
  const encoder = new TextEncoder();
  const head = base64url(encoder.encode(JSON.stringify({ alg: "ES256", x5c: x5c.map(base64), ...header })));
  const body = base64url(encoder.encode(JSON.stringify(payload)));
  const signature = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, signer, encoder.encode(`${head}.${body}`)));
  return `${head}.${body}.${base64url(signature)}`;
}

export function signWithChain(payload: unknown, chain: AppleChain): Promise<string> {
  return signJws(payload, [chain.leaf.der, chain.intermediate.der, chain.root.der], chain.leaf.keys.privateKey);
}

/** Raw `r || s` to DER, as App Attest sends signatures. */
export function rawToDer(raw: Uint8Array): Uint8Array {
  const half = raw.length / 2;
  const integer = (bytes: Uint8Array): number[] => {
    let start = 0;
    while (start < bytes.length - 1 && bytes[start] === 0 && !(bytes[start + 1]! & 0x80)) start++;
    const body = Array.from(bytes.subarray(start));
    if (body[0]! & 0x80) body.unshift(0);
    return [0x02, body.length, ...body];
  };
  const content = [...integer(raw.subarray(0, half)), ...integer(raw.subarray(half))];
  return new Uint8Array([0x30, content.length, ...content]);
}
