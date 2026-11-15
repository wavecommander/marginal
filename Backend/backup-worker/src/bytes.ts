// Small, strict byte helpers. Every decoder here refuses rather than guesses.

export function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    out.set(part, offset);
    offset += part.length;
  }
  return out;
}

/** Byte equality that does not stop at the first difference. */
export function equalBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let difference = 0;
  for (let i = 0; i < a.length; i++) difference |= a[i]! ^ b[i]!;
  return difference === 0;
}

/** String equality that does not stop at the first difference (for secrets). */
export function equalStrings(a: string, b: string): boolean {
  const encoder = new TextEncoder();
  return equalBytes(encoder.encode(a), encoder.encode(b));
}

export async function sha256(data: Uint8Array | string): Promise<Uint8Array> {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  return new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
}

export function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

/** Standard base64 with padding, as Apple's APIs and the app use it. Throws on anything else. */
export function fromBase64(text: string): Uint8Array {
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(text)) {
    throw new Error("not base64");
  }
  const binary = atob(text);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

export function toBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

/** Unpadded base64url, as JWS uses it. Throws on anything else. */
export function fromBase64Url(text: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]*$/.test(text) || text.length % 4 === 1) throw new Error("not base64url");
  const padded = text.replace(/-/g, "+").replace(/_/g, "/") + "=".repeat((4 - (text.length % 4)) % 4);
  return fromBase64(padded);
}

export function toBase64Url(bytes: Uint8Array): string {
  return toBase64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function randomBytes(length: number): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(length));
}

/**
 * An ECDSA signature in DER (`SEQUENCE { INTEGER r, INTEGER s }`, as X.509 and App Attest use)
 * converted to the fixed-width `r || s` form WebCrypto verifies. Strict: refuses non-minimal
 * integers, negative values, values wider than the curve and trailing bytes.
 */
export function derSignatureToRaw(der: Uint8Array, size: number): Uint8Array {
  let offset = 0;
  const byte = (): number => {
    if (offset >= der.length) throw new Error("signature: truncated");
    return der[offset++]!;
  };
  const length = (): number => {
    const first = byte();
    if (first < 0x80) return first;
    if (first !== 0x81) throw new Error("signature: bad length");
    const value = byte();
    if (value < 0x80) throw new Error("signature: non-minimal length");
    return value;
  };
  if (byte() !== 0x30) throw new Error("signature: not a sequence");
  const total = length();
  if (offset + total !== der.length) throw new Error("signature: wrong length");
  const out = new Uint8Array(size * 2);
  for (let index = 0; index < 2; index++) {
    if (byte() !== 0x02) throw new Error("signature: not an integer");
    const intLength = length();
    if (intLength === 0 || offset + intLength > der.length) throw new Error("signature: bad integer");
    let value = der.subarray(offset, offset + intLength);
    offset += intLength;
    if (value[0]! & 0x80) throw new Error("signature: negative integer");
    if (value.length > 1 && value[0] === 0 && !(value[1]! & 0x80)) throw new Error("signature: non-minimal integer");
    if (value[0] === 0 && value.length > 1) value = value.subarray(1);
    if (value.length > size) throw new Error("signature: integer too large");
    out.set(value, index * size + (size - value.length));
  }
  if (offset !== der.length) throw new Error("signature: trailing bytes");
  return out;
}
