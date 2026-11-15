// App Attest: proof that a request comes from the genuine app on a genuine Apple device.
// Apple, "Validating apps that connect to your server" (DeviceCheck), followed step by step.
//
// Attestation (once per app install): the attestation object's certificate chain leads to
// Apple's App Attestation root; the credential certificate's nonce extension equals
// SHA-256(authData || clientDataHash); the key's hash is the key ID; the RP ID is SHA-256 of the
// App ID; the counter is 0; the AAGUID names the App Attest environment; the credential ID is the
// key ID; and the `extensions` in authData carry an acceptable validation category and a bundle
// version. Then the public key is stored.
//
// Assertion (every authenticated request): SHA-256(authenticatorData || SHA-256(clientData)) is
// the nonce; the signature over it verifies with the stored key; the RP ID matches; the counter is
// greater than the last one seen; the challenge embedded in clientData is the one handed out (the
// caller checks that, since it owns the challenge store); and the extensions, when present, carry
// an acceptable validation category and bundle version.
//
// Two gaps in Apple's documentation, handled conservatively:
// - Apple's prose calls the validation category a UInt32, while Apple's published sample encodes
//   it as four little-endian bytes. Both encodings are read; any other is refused.
// - Older systems send no `extensions` at all; then there is nothing to check and nothing is
//   refused for it. (What is in `authData` is covered by Apple's signature on the credential
//   certificate, and in assertions by the device key's signature, so it cannot be stripped.)

import { concat, derSignatureToRaw, equalBytes, sha256 } from "./bytes";
import { decodeCbor, decodeCborPrefix, isBytes, isMap, type CborMap, type CborValue } from "./cbor";
import { TAG, children, readOne } from "./der";
import { parseCertificate, verifyChain } from "./x509";

const NONCE_OID = "1.2.840.113635.100.8.2";
const AAGUID_PRODUCTION = concat(new TextEncoder().encode("appattest"), new Uint8Array(7));
const AAGUID_DEVELOPMENT = new TextEncoder().encode("appattestdevelop");

export type AttestEnvironment = "production" | "development";

export interface AttestPolicy {
  /** SHA-256 of this is the RP ID: `<team ID>.<bundle ID>`. */
  appId: string;
  /** Which App Attest environments' keys are accepted. */
  environments: ReadonlySet<AttestEnvironment>;
  /** Acceptable launch validation categories (Apple: 2 TestFlight, 3 development, 4 App Store). */
  validationCategories: ReadonlySet<number>;
}

/** What each deployment accepts. Production: App Store and TestFlight builds only. */
export function attestPolicy(environment: "dev" | "production", appId: string): AttestPolicy {
  return environment === "production"
    ? { appId, environments: new Set(["production"]), validationCategories: new Set([2, 4]) }
    : { appId, environments: new Set(["production", "development"]), validationCategories: new Set([2, 3, 4]) };
}

export interface VerifiedAttestation {
  /** Uncompressed P-256 point, 65 bytes. */
  publicKey: Uint8Array;
  environment: AttestEnvironment;
}

export async function verifyAttestation(input: {
  attestation: Uint8Array;
  keyId: Uint8Array;
  clientDataHash: Uint8Array;
  roots: Uint8Array[];
  policy: AttestPolicy;
  now: Date;
}): Promise<VerifiedAttestation> {
  const { attestation, keyId, clientDataHash, roots, policy, now } = input;
  const object = decodeCbor(attestation);
  if (!isMap(object) || object.size !== 3) throw new Error("attest: not an attestation object");
  if (object.get("fmt") !== "apple-appattest") throw new Error("attest: wrong format");
  const statement = object.get("attStmt");
  const authData = object.get("authData");
  if (!isMap(statement) || !isBytes(authData)) throw new Error("attest: missing fields");
  const x5c = statement.get("x5c");
  if (!Array.isArray(x5c) || x5c.length !== 2 || !x5c.every(isBytes)) throw new Error("attest: x5c is not leaf and intermediate");
  if (!isBytes(statement.get("receipt"))) throw new Error("attest: no receipt");

  // 1. The chain: credential certificate, intermediate, Apple's App Attestation root.
  const credCert = parseCertificate(x5c[0] as Uint8Array);
  const intermediate = parseCertificate(x5c[1] as Uint8Array);
  let chained = false;
  for (const rootBytes of roots) {
    const root = parseCertificate(rootBytes);
    if (!equalBytes(intermediate.issuer, root.subject)) continue;
    await verifyChain([credCert, intermediate, root], now);
    chained = true;
    break;
  }
  if (!chained) throw new Error("attest: chain does not reach a trusted root");
  if (credCert.curve !== "P-256") throw new Error("attest: key is not P-256");

  // 2-4. nonce = SHA-256(authData || clientDataHash) must equal the certificate's nonce.
  const nonce = await sha256(concat(authData, clientDataHash));
  const extension = credCert.extensions.get(NONCE_OID);
  if (!extension) throw new Error("attest: no nonce extension");
  if (!equalBytes(nonceFromExtension(extension.value), nonce)) throw new Error("attest: nonce mismatch");

  // 5. The key's hash is the key ID.
  if (!equalBytes(await sha256(credCert.publicPoint), keyId)) throw new Error("attest: key ID does not match the key");

  const parsed = parseAttestationAuthData(authData);
  // 6. RP ID.
  if (!equalBytes(parsed.rpIdHash, await sha256(policy.appId))) throw new Error("attest: wrong App ID");
  // 7. Counter.
  if (parsed.counter !== 0) throw new Error("attest: counter is not 0");
  // 8. AAGUID.
  let environment: AttestEnvironment;
  if (equalBytes(parsed.aaguid, AAGUID_PRODUCTION)) environment = "production";
  else if (equalBytes(parsed.aaguid, AAGUID_DEVELOPMENT)) environment = "development";
  else throw new Error("attest: unknown AAGUID");
  if (!policy.environments.has(environment)) throw new Error("attest: App Attest environment not accepted");
  // 9. Credential ID.
  if (!equalBytes(parsed.credentialId, keyId)) throw new Error("attest: credential ID is not the key ID");
  // The COSE key in authData must be the certificate's key (consistency; not one of Apple's steps).
  if (!equalBytes(concat(new Uint8Array([4]), parsed.coseX, parsed.coseY), credCert.publicPoint)) {
    throw new Error("attest: authData key differs from certificate key");
  }
  // 10-11. Validation category and bundle version.
  checkExtensions(parsed.extensions, policy, ["apple_validation_category_01"], ["apple_bundle_version_01"]);

  return { publicKey: credCert.publicPoint, environment };
}

export async function verifyAssertion(input: {
  assertion: Uint8Array;
  clientData: Uint8Array;
  publicKey: Uint8Array;
  previousCounter: number;
  policy: AttestPolicy;
}): Promise<{ counter: number }> {
  const { assertion, clientData, publicKey, previousCounter, policy } = input;
  const object = decodeCbor(assertion);
  if (!isMap(object) || object.size !== 2) throw new Error("assert: not an assertion object");
  const signature = object.get("signature");
  const authenticatorData = object.get("authenticatorData");
  if (!isBytes(signature) || !isBytes(authenticatorData)) throw new Error("assert: missing fields");
  if (authenticatorData.length < 37) throw new Error("assert: authenticator data too short");

  // 1-3. The signature over nonce = SHA-256(authenticatorData || SHA-256(clientData)).
  const nonce = await sha256(concat(authenticatorData, await sha256(clientData)));
  const key = await crypto.subtle.importKey("raw", publicKey, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  let raw: Uint8Array;
  try {
    raw = derSignatureToRaw(signature, 32);
  } catch {
    throw new Error("assert: malformed signature");
  }
  if (!(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, raw, nonce))) {
    throw new Error("assert: bad signature");
  }
  // 4. RP ID.
  if (!equalBytes(authenticatorData.subarray(0, 32), await sha256(policy.appId))) throw new Error("assert: wrong App ID");
  // 5. Counter strictly increasing.
  const counter = readUint32(authenticatorData, 33);
  if (counter <= previousCounter) throw new Error("assert: counter did not increase");
  // 7-8. Extensions, when present, follow the 37-byte header.
  let extensions: CborMap | undefined;
  if (authenticatorData.length > 37) {
    const value = decodeCbor(authenticatorData.subarray(37));
    if (!isMap(value)) throw new Error("assert: extensions are not a map");
    extensions = value;
  }
  checkExtensions(extensions, policy, ["validationCategory", "apple_validation_category_01"], ["bundleVersion", "apple_bundle_version_01"]);
  return { counter };
}

interface AttestationAuthData {
  rpIdHash: Uint8Array;
  flags: number;
  counter: number;
  aaguid: Uint8Array;
  credentialId: Uint8Array;
  coseX: Uint8Array;
  coseY: Uint8Array;
  extensions: CborMap | undefined;
}

/** WebAuthn authenticator data with attested credential data (and optional extensions). */
export function parseAttestationAuthData(authData: Uint8Array): AttestationAuthData {
  if (authData.length < 55) throw new Error("attest: authData too short");
  const rpIdHash = authData.subarray(0, 32);
  const flags = authData[32]!;
  if (!(flags & 0x40)) throw new Error("attest: no attested credential data");
  const counter = readUint32(authData, 33);
  const aaguid = authData.subarray(37, 53);
  const credentialIdLength = (authData[53]! << 8) | authData[54]!;
  const credentialEnd = 55 + credentialIdLength;
  if (credentialIdLength !== 32 || credentialEnd > authData.length) throw new Error("attest: bad credential ID");
  const credentialId = authData.subarray(55, credentialEnd);
  const { value: cose, next } = decodeCborPrefix(authData, credentialEnd);
  if (!isMap(cose)) throw new Error("attest: credential public key is not a COSE key");
  // EC2 key (kty 2), ES256 (alg -7), P-256 (crv 1).
  if (cose.get(1) !== 2 || cose.get(3) !== -7 || cose.get(-1) !== 1) throw new Error("attest: not an ES256 P-256 key");
  const x = cose.get(-2);
  const y = cose.get(-3);
  if (!isBytes(x) || !isBytes(y) || x.length !== 32 || y.length !== 32) throw new Error("attest: bad COSE coordinates");
  // Apple's sample carries the extensions map here without setting the ED flag, so the flag is
  // not relied on: whatever follows the key must be exactly one CBOR map.
  let extensions: CborMap | undefined;
  if (next < authData.length) {
    const value = decodeCbor(authData.subarray(next));
    if (!isMap(value)) throw new Error("attest: extensions are not a map");
    extensions = value;
  }
  return { rpIdHash, flags, counter, aaguid, credentialId, coseX: x, coseY: y, extensions };
}

function checkExtensions(extensions: CborMap | undefined, policy: AttestPolicy, categoryKeys: string[], versionKeys: string[]): void {
  if (!extensions) return;
  const category = firstOf(extensions, categoryKeys);
  if (category !== undefined) {
    const value = validationCategory(category);
    if (!policy.validationCategories.has(value)) throw new Error(`attest: validation category ${value} not accepted`);
  }
  const version = firstOf(extensions, versionKeys);
  if (version !== undefined && (typeof version !== "string" || version.length === 0 || version.length > 64)) {
    throw new Error("attest: bad bundle version");
  }
}

function firstOf(map: CborMap, keys: string[]): CborValue | undefined {
  for (const key of keys) if (map.has(key)) return map.get(key);
  return undefined;
}

/** A CBOR unsigned integer, or four little-endian bytes (as in Apple's sample). */
function validationCategory(value: CborValue): number {
  if (typeof value === "number" && Number.isInteger(value) && value >= 0 && value <= 0xffffffff) return value;
  if (isBytes(value) && value.length === 4) return (value[0]! | (value[1]! << 8) | (value[2]! << 16)) + value[3]! * 0x1000000;
  throw new Error("attest: unreadable validation category");
}

/** The nonce: the single OCTET STRING inside the extension's SEQUENCE (Apple wraps it in [1]). */
function nonceFromExtension(value: Uint8Array): Uint8Array {
  const sequence = readOne(value);
  if (sequence.tag !== TAG.SEQUENCE) throw new Error("attest: nonce extension is not a sequence");
  const items = children(sequence);
  if (items.length !== 1) throw new Error("attest: nonce extension has more than one item");
  let item = items[0]!;
  if (item.tag === 0xa1) item = readOne(item.value);
  if (item.tag !== TAG.OCTET_STRING) throw new Error("attest: nonce is not an octet string");
  return item.value;
}

function readUint32(bytes: Uint8Array, offset: number): number {
  return bytes[offset]! * 0x1000000 + ((bytes[offset + 1]! << 16) | (bytes[offset + 2]! << 8) | bytes[offset + 3]!);
}
