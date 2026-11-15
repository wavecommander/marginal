// A minimal, strict DER reader: just enough to walk X.509 certificates (RFC 5280) and the App
// Attest nonce extension. It gives back each element's exact bytes, so signatures are checked
// over what was received, never over a re-encoding. It refuses indefinite lengths, non-minimal
// lengths, multi-byte tags, truncation and trailing data.

export interface DerElement {
  /** The identifier octet (class, constructed bit and tag number below 31). */
  tag: number;
  /** The whole element: identifier, length and contents. */
  raw: Uint8Array;
  /** The contents only. */
  value: Uint8Array;
}

export const TAG = {
  BOOLEAN: 0x01,
  INTEGER: 0x02,
  BIT_STRING: 0x03,
  OCTET_STRING: 0x04,
  NULL: 0x05,
  OID: 0x06,
  UTF8_STRING: 0x0c,
  SEQUENCE: 0x30,
  SET: 0x31,
  UTC_TIME: 0x17,
  GENERALIZED_TIME: 0x18,
} as const;

/** Reads one element at `offset`; returns it and the offset after it. */
export function readElement(bytes: Uint8Array, offset = 0): { element: DerElement; next: number } {
  if (offset + 2 > bytes.length) throw new Error("der: truncated");
  const tag = bytes[offset]!;
  if ((tag & 0x1f) === 0x1f) throw new Error("der: multi-byte tag");
  let cursor = offset + 1;
  const first = bytes[cursor++]!;
  let length: number;
  if (first < 0x80) {
    length = first;
  } else {
    const count = first & 0x7f;
    if (count === 0) throw new Error("der: indefinite length");
    if (count > 4) throw new Error("der: length too large");
    if (cursor + count > bytes.length) throw new Error("der: truncated");
    if (bytes[cursor] === 0) throw new Error("der: non-minimal length");
    length = 0;
    for (let i = 0; i < count; i++) length = length * 256 + bytes[cursor++]!;
    if (length < 0x80) throw new Error("der: non-minimal length");
  }
  const end = cursor + length;
  if (end > bytes.length) throw new Error("der: truncated");
  return {
    element: { tag, raw: bytes.subarray(offset, end), value: bytes.subarray(cursor, end) },
    next: end,
  };
}

/** Exactly one element filling `bytes`. */
export function readOne(bytes: Uint8Array): DerElement {
  const { element, next } = readElement(bytes, 0);
  if (next !== bytes.length) throw new Error("der: trailing data");
  return element;
}

/** The children of a constructed element. */
export function children(element: DerElement): DerElement[] {
  if (!(element.tag & 0x20)) throw new Error("der: not constructed");
  const out: DerElement[] = [];
  let offset = 0;
  while (offset < element.value.length) {
    const { element: child, next } = readElement(element.value, offset);
    out.push(child);
    offset = next;
  }
  return out;
}

export function expectTag(element: DerElement | undefined, tag: number, what: string): DerElement {
  if (!element || element.tag !== tag) throw new Error(`der: expected ${what}`);
  return element;
}

/** Dotted-decimal text of an OBJECT IDENTIFIER's contents. */
export function oidToString(value: Uint8Array): string {
  if (value.length === 0) throw new Error("der: empty OID");
  const arcs: number[] = [];
  let current = 0;
  for (let i = 0; i < value.length; i++) {
    const byte = value[i]!;
    if (current === 0 && byte === 0x80) throw new Error("der: non-minimal OID");
    current = current * 128 + (byte & 0x7f);
    if (current > Number.MAX_SAFE_INTEGER / 128) throw new Error("der: OID arc too large");
    if (!(byte & 0x80)) {
      arcs.push(current);
      current = 0;
    } else if (i === value.length - 1) {
      throw new Error("der: truncated OID");
    }
  }
  const first = arcs.shift()!;
  const head = first < 40 ? [0, first] : first < 80 ? [1, first - 40] : [2, first - 80];
  return [...head, ...arcs].join(".");
}

/** UTCTime or GeneralizedTime in the forms RFC 5280 requires (UTC, seconds, `Z`). */
export function readTime(element: DerElement): Date {
  const text = new TextDecoder().decode(element.value);
  let match: RegExpMatchArray | null;
  let year: number;
  if (element.tag === TAG.UTC_TIME) {
    match = text.match(/^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/);
    if (!match) throw new Error("der: bad UTCTime");
    const yy = Number(match[1]);
    year = yy >= 50 ? 1900 + yy : 2000 + yy;
  } else if (element.tag === TAG.GENERALIZED_TIME) {
    match = text.match(/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/);
    if (!match) throw new Error("der: bad GeneralizedTime");
    year = Number(match[1]);
  } else {
    throw new Error("der: expected a time");
  }
  const [month, day, hour, minute, second] = match.slice(2).map(Number) as [number, number, number, number, number];
  const date = new Date(Date.UTC(year, month - 1, day, hour, minute, second));
  if (date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day || hour > 23 || minute > 59 || second > 59) {
    throw new Error("der: impossible date");
  }
  return date;
}
