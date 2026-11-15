// X.509 certificates, as far as Apple's chains need: parse (strictly), check a chain to a pinned
// root, read extensions by OID. Signatures are checked with WebCrypto over the certificate's own
// `tbsCertificate` bytes. Only the algorithms Apple uses are accepted: ECDSA on P-256 or P-384,
// with SHA-256 or SHA-384. Anything else is refused.

import { derSignatureToRaw, equalBytes } from "./bytes";
import { TAG, children, expectTag, oidToString, readOne, readTime, type DerElement } from "./der";

const OID = {
  ecPublicKey: "1.2.840.10045.2.1",
  p256: "1.2.840.10045.3.1.7",
  p384: "1.3.132.0.34",
  ecdsaSha256: "1.2.840.10045.4.3.2",
  ecdsaSha384: "1.2.840.10045.4.3.3",
  basicConstraints: "2.5.29.19",
  keyUsage: "2.5.29.15",
} as const;

/** Extensions this code understands, so they may be marked critical. */
const UNDERSTOOD_CRITICAL = new Set<string>([OID.basicConstraints, OID.keyUsage]);

/** Allowed difference between clocks when checking validity dates (as Apple's own library does). */
const CLOCK_SKEW_MS = 60_000;

type Curve = "P-256" | "P-384";

export interface Extension {
  critical: boolean;
  /** The contents of `extnValue` (the DER inside the OCTET STRING). */
  value: Uint8Array;
}

export interface Certificate {
  raw: Uint8Array;
  tbs: Uint8Array;
  signatureHash: "SHA-256" | "SHA-384";
  signature: Uint8Array;
  issuer: Uint8Array;
  subject: Uint8Array;
  notBefore: Date;
  notAfter: Date;
  curve: Curve;
  /** The public key as an uncompressed point (`04 || X || Y`). */
  publicPoint: Uint8Array;
  spki: Uint8Array;
  extensions: Map<string, Extension>;
  isCA: boolean;
  pathLength: number | undefined;
  /** First byte of the KeyUsage bits, if the extension is present. */
  keyUsage: number | undefined;
}

export function parseCertificate(der: Uint8Array): Certificate {
  const certificate = expectTag(readOne(der), TAG.SEQUENCE, "certificate");
  const [tbsElement, algorithm, signatureValue, ...extra] = children(certificate);
  if (extra.length) throw new Error("x509: extra fields");
  expectTag(tbsElement, TAG.SEQUENCE, "tbsCertificate");
  const signatureHash = signatureHashOf(expectTag(algorithm, TAG.SEQUENCE, "signatureAlgorithm"));
  const signature = bitStringBytes(expectTag(signatureValue, TAG.BIT_STRING, "signature"));

  const fields = children(tbsElement!);
  let index = 0;
  const versionField = fields[index];
  if (!versionField || versionField.tag !== 0xa0) throw new Error("x509: not a version 3 certificate");
  const version = expectTag(readOne(versionField.value), TAG.INTEGER, "version");
  if (version.value.length !== 1 || version.value[0] !== 2) throw new Error("x509: not a version 3 certificate");
  index++;
  expectTag(fields[index++], TAG.INTEGER, "serialNumber");
  const innerAlgorithm = expectTag(fields[index++], TAG.SEQUENCE, "signature");
  if (!equalBytes(innerAlgorithm.raw, algorithm!.raw)) throw new Error("x509: signature algorithms differ");
  const issuer = expectTag(fields[index++], TAG.SEQUENCE, "issuer");
  const validity = children(expectTag(fields[index++], TAG.SEQUENCE, "validity"));
  if (validity.length !== 2) throw new Error("x509: bad validity");
  const notBefore = readTime(validity[0]!);
  const notAfter = readTime(validity[1]!);
  const subject = expectTag(fields[index++], TAG.SEQUENCE, "subject");
  const spki = expectTag(fields[index++], TAG.SEQUENCE, "subjectPublicKeyInfo");
  const { curve, point } = parsePublicKey(spki);

  // Optional issuerUniqueID [1] and subjectUniqueID [2], then extensions [3].
  while (fields[index] && (fields[index]!.tag === 0x81 || fields[index]!.tag === 0xa1 || fields[index]!.tag === 0x82 || fields[index]!.tag === 0xa2)) index++;
  const extensions = new Map<string, Extension>();
  const extensionsField = fields[index];
  if (extensionsField) {
    if (extensionsField.tag !== 0xa3) throw new Error("x509: unexpected field");
    index++;
    const list = expectTag(readOne(extensionsField.value), TAG.SEQUENCE, "extensions");
    for (const item of children(list)) {
      const parts = children(expectTag(item, TAG.SEQUENCE, "extension"));
      const oid = oidToString(expectTag(parts[0], TAG.OID, "extnID").value);
      let critical = false;
      let valueIndex = 1;
      if (parts[1]?.tag === TAG.BOOLEAN) {
        critical = booleanOf(parts[1]);
        // DER: a DEFAULT value must be omitted, so an explicit FALSE is not DER.
        if (!critical) throw new Error("x509: explicit non-critical flag");
        valueIndex = 2;
      }
      const value = expectTag(parts[valueIndex], TAG.OCTET_STRING, "extnValue").value;
      if (parts.length !== valueIndex + 1) throw new Error("x509: bad extension");
      if (extensions.has(oid)) throw new Error("x509: duplicate extension");
      if (critical && !UNDERSTOOD_CRITICAL.has(oid)) throw new Error("x509: unknown critical extension");
      extensions.set(oid, { critical, value });
    }
  }
  if (index !== fields.length) throw new Error("x509: unexpected field");

  let isCA = false;
  let pathLength: number | undefined;
  const basic = extensions.get(OID.basicConstraints);
  if (basic) {
    const parts = children(expectTag(readOne(basic.value), TAG.SEQUENCE, "basicConstraints"));
    let at = 0;
    if (parts[at]?.tag === TAG.BOOLEAN) {
      isCA = booleanOf(parts[at]!);
      if (!isCA) throw new Error("x509: explicit cA FALSE");
      at++;
    }
    if (parts[at]?.tag === TAG.INTEGER) {
      pathLength = smallInteger(parts[at]!);
      at++;
    }
    if (at !== parts.length) throw new Error("x509: bad basicConstraints");
  }
  let keyUsage: number | undefined;
  const usage = extensions.get(OID.keyUsage);
  if (usage) {
    const bits = expectTag(readOne(usage.value), TAG.BIT_STRING, "keyUsage");
    if (bits.value.length < 2) throw new Error("x509: bad keyUsage");
    keyUsage = bits.value[1]!;
  }

  return {
    raw: der,
    tbs: tbsElement!.raw,
    signatureHash,
    signature,
    issuer: issuer.raw,
    subject: subject.raw,
    notBefore,
    notAfter,
    curve,
    publicPoint: point,
    spki: spki.raw,
    extensions,
    isCA,
    pathLength,
    keyUsage,
  };
}

/**
 * Checks `chain` (leaf first, root last): each certificate is signed by the next, names chain,
 * every certificate is within its validity dates at `at`, every issuer is a CA allowed to sign
 * certificates, and the root signs itself. Whether the root is trusted is the caller's check.
 */
export async function verifyChain(chain: Certificate[], at: Date): Promise<void> {
  if (chain.length < 1) throw new Error("x509: empty chain");
  for (const certificate of chain) {
    if (at.getTime() + CLOCK_SKEW_MS < certificate.notBefore.getTime()) throw new Error("x509: certificate not yet valid");
    if (at.getTime() > certificate.notAfter.getTime()) throw new Error("x509: certificate expired");
  }
  for (let i = 0; i < chain.length; i++) {
    const child = chain[i]!;
    // The last certificate is the root, which signs itself.
    const issuer = i + 1 < chain.length ? chain[i + 1]! : child;
    if (!equalBytes(child.issuer, issuer.subject)) throw new Error("x509: names do not chain");
    if (!(await verifySignedBy(child, issuer))) throw new Error("x509: bad certificate signature");
    if (i > 0) {
      // `child` here is an issuer of chain[i - 1].
      if (!child.isCA) throw new Error("x509: issuer is not a CA");
      if (child.keyUsage !== undefined && !(child.keyUsage & 0x04)) throw new Error("x509: issuer may not sign certificates");
      // Number of intermediate CAs below this one in the chain (not counting the leaf).
      const below = i - 1;
      if (child.pathLength !== undefined && below > child.pathLength) throw new Error("x509: path too long");
    }
  }
}

async function verifySignedBy(child: Certificate, issuer: Certificate): Promise<boolean> {
  const key = await importPublicKey(issuer);
  const size = issuer.curve === "P-256" ? 32 : 48;
  let raw: Uint8Array;
  try {
    raw = derSignatureToRaw(child.signature, size);
  } catch {
    return false;
  }
  return crypto.subtle.verify({ name: "ECDSA", hash: child.signatureHash }, key, raw, child.tbs);
}

export function importPublicKey(certificate: Certificate): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", certificate.publicPoint, { name: "ECDSA", namedCurve: certificate.curve }, false, ["verify"]);
}

/** The DER inside an extension's OCTET STRING, or undefined. */
export function extensionValue(certificate: Certificate, oid: string): Uint8Array | undefined {
  return certificate.extensions.get(oid)?.value;
}

function signatureHashOf(algorithm: DerElement): "SHA-256" | "SHA-384" {
  const parts = children(algorithm);
  // RFC 5758: the ECDSA algorithm identifiers carry no parameters.
  if (parts.length !== 1) throw new Error("x509: unexpected algorithm parameters");
  const oid = oidToString(expectTag(parts[0], TAG.OID, "algorithm").value);
  if (oid === OID.ecdsaSha256) return "SHA-256";
  if (oid === OID.ecdsaSha384) return "SHA-384";
  throw new Error("x509: unsupported signature algorithm");
}

function parsePublicKey(spki: DerElement): { curve: Curve; point: Uint8Array } {
  const [algorithm, key, ...extra] = children(spki);
  if (extra.length) throw new Error("x509: bad public key");
  const [keyType, parameters, ...more] = children(expectTag(algorithm, TAG.SEQUENCE, "algorithm"));
  if (more.length) throw new Error("x509: bad public key algorithm");
  if (oidToString(expectTag(keyType, TAG.OID, "key type").value) !== OID.ecPublicKey) {
    throw new Error("x509: not an elliptic-curve key");
  }
  const curveOid = oidToString(expectTag(parameters, TAG.OID, "curve").value);
  const curve: Curve | undefined = curveOid === OID.p256 ? "P-256" : curveOid === OID.p384 ? "P-384" : undefined;
  if (!curve) throw new Error("x509: unsupported curve");
  const point = bitStringBytes(expectTag(key, TAG.BIT_STRING, "public key"));
  const expected = curve === "P-256" ? 65 : 97;
  if (point.length !== expected || point[0] !== 0x04) throw new Error("x509: not an uncompressed point");
  return { curve, point };
}

function bitStringBytes(element: DerElement): Uint8Array {
  if (element.value.length < 1 || element.value[0] !== 0) throw new Error("x509: bit string with unused bits");
  return element.value.subarray(1);
}

function booleanOf(element: DerElement): boolean {
  if (element.value.length !== 1) throw new Error("x509: bad boolean");
  if (element.value[0] === 0xff) return true;
  if (element.value[0] === 0x00) return false;
  throw new Error("x509: non-DER boolean");
}

function smallInteger(element: DerElement): number {
  const value = element.value;
  if (value.length < 1 || value.length > 2 || value[0]! & 0x80) throw new Error("x509: bad integer");
  if (value.length === 2 && value[0] === 0 && !(value[1]! & 0x80)) throw new Error("x509: non-minimal integer");
  return value.length === 1 ? value[0]! : value[0]! * 256 + value[1]!;
}
