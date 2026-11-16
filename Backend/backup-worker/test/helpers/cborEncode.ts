// A tiny CBOR encoder for building App Attest objects in tests (independent of src/cbor.ts).

export type Encodable = number | string | Uint8Array | Encodable[] | Map<number | string, Encodable>;

export function encodeCbor(value: Encodable): Uint8Array {
  const out: number[] = [];
  write(value, out);
  return new Uint8Array(out);
}

function head(major: number, length: number, out: number[]): void {
  if (length < 24) out.push((major << 5) | length);
  else if (length < 0x100) out.push((major << 5) | 24, length);
  else if (length < 0x10000) out.push((major << 5) | 25, length >> 8, length & 0xff);
  else out.push((major << 5) | 26, (length >>> 24) & 0xff, (length >> 16) & 0xff, (length >> 8) & 0xff, length & 0xff);
}

function write(value: Encodable, out: number[]): void {
  if (typeof value === "number") {
    if (value >= 0) head(0, value, out);
    else head(1, -1 - value, out);
  } else if (typeof value === "string") {
    const bytes = new TextEncoder().encode(value);
    head(3, bytes.length, out);
    out.push(...bytes);
  } else if (value instanceof Uint8Array) {
    head(2, value.length, out);
    for (const byte of value) out.push(byte);
  } else if (Array.isArray(value)) {
    head(4, value.length, out);
    for (const item of value) write(item, out);
  } else {
    head(5, value.size, out);
    for (const [key, item] of value) {
      write(key, out);
      write(item, out);
    }
  }
}
