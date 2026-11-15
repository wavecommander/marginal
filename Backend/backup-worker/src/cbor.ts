// A minimal, strict CBOR decoder (RFC 8949) for App Attest's attestation and assertion objects.
// It reads unsigned and negative integers, byte and text strings, arrays and maps of definite
// length, and nothing else: no tags, floats, simple values or indefinite lengths. Duplicate map
// keys, truncation and excessive nesting are refused.

export type CborValue = number | Uint8Array | string | CborValue[] | CborMap;
export type CborMap = Map<number | string, CborValue>;

const MAX_DEPTH = 8;
const MAX_ITEMS = 1024;

/** Decodes one item at `offset`; returns it and the offset after it. */
export function decodeCborPrefix(bytes: Uint8Array, offset = 0): { value: CborValue; next: number } {
  const state = { bytes, offset };
  const value = item(state, 0);
  return { value, next: state.offset };
}

/** Decodes exactly one item filling `bytes`. */
export function decodeCbor(bytes: Uint8Array): CborValue {
  const { value, next } = decodeCborPrefix(bytes, 0);
  if (next !== bytes.length) throw new Error("cbor: trailing data");
  return value;
}

interface State {
  bytes: Uint8Array;
  offset: number;
}

function take(state: State, count: number): Uint8Array {
  if (state.offset + count > state.bytes.length) throw new Error("cbor: truncated");
  const out = state.bytes.subarray(state.offset, state.offset + count);
  state.offset += count;
  return out;
}

function argument(state: State, info: number): number {
  if (info < 24) return info;
  const width = info === 24 ? 1 : info === 25 ? 2 : info === 26 ? 4 : info === 27 ? 8 : 0;
  if (width === 0) throw new Error("cbor: unsupported length encoding");
  const raw = take(state, width);
  let value = 0;
  for (const byte of raw) value = value * 256 + byte;
  if (!Number.isSafeInteger(value)) throw new Error("cbor: integer too large");
  return value;
}

function item(state: State, depth: number): CborValue {
  if (depth > MAX_DEPTH) throw new Error("cbor: nested too deeply");
  const initial = take(state, 1)[0]!;
  const major = initial >> 5;
  const info = initial & 0x1f;
  switch (major) {
    case 0:
      return argument(state, info);
    case 1:
      return -1 - argument(state, info);
    case 2:
      return take(state, argument(state, info));
    case 3:
      return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(take(state, argument(state, info)));
    case 4: {
      const count = argument(state, info);
      if (count > MAX_ITEMS) throw new Error("cbor: too many items");
      const out: CborValue[] = [];
      for (let i = 0; i < count; i++) out.push(item(state, depth + 1));
      return out;
    }
    case 5: {
      const count = argument(state, info);
      if (count > MAX_ITEMS) throw new Error("cbor: too many items");
      const out: CborMap = new Map();
      for (let i = 0; i < count; i++) {
        const key = item(state, depth + 1);
        if (typeof key !== "number" && typeof key !== "string") throw new Error("cbor: unsupported map key");
        if (out.has(key)) throw new Error("cbor: duplicate map key");
        out.set(key, item(state, depth + 1));
      }
      return out;
    }
    default:
      throw new Error("cbor: unsupported type");
  }
}

export function isMap(value: CborValue | undefined): value is CborMap {
  return value instanceof Map;
}

export function isBytes(value: CborValue | undefined): value is Uint8Array {
  return value instanceof Uint8Array;
}
