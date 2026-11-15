// Responses, errors and request bodies.

import { ERRORS, type ErrorCode, type ErrorResponse, type SubscriptionInfo } from "./contract";

/** Largest request body accepted, in bytes. A notification with its nested JWS is about 15 KB. */
export const MAX_BODY_BYTES = 64 * 1024;

/**
 * A refusal the client may hear about. `detail` is for the log only and never leaves the Worker;
 * the client gets the code and its fixed message.
 */
export class Refusal extends Error {
  constructor(
    readonly code: ErrorCode,
    readonly detail: string,
    readonly subscription?: SubscriptionInfo,
  ) {
    super(`${code}: ${detail}`);
  }
}

export function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      ...headers,
    },
  });
}

export function problem(code: ErrorCode, subscription?: SubscriptionInfo, headers: Record<string, string> = {}): Response {
  const { status, message } = ERRORS[code];
  const body: ErrorResponse = { error: { code, message } };
  if (subscription) body.subscription = subscription;
  return json(status, body, headers);
}

/**
 * Reads a JSON object body: checks the content type, refuses anything over `MAX_BODY_BYTES`
 * (whatever Content-Length claims), and returns the exact bytes too (App Attest signs them).
 * An empty body is allowed only when `allowEmpty`.
 */
export async function readJsonBody(request: Request, allowEmpty = false): Promise<{ bytes: Uint8Array; value: Record<string, unknown> }> {
  const declared = request.headers.get("content-length");
  if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > MAX_BODY_BYTES)) {
    throw new Refusal("body-too-large", "declared length");
  }
  const bytes = await readCapped(request);
  if (bytes.length === 0 && allowEmpty) return { bytes, value: {} };
  const type = request.headers.get("content-type") ?? "";
  if (!/^application\/json\s*(;\s*charset=utf-8\s*)?$/i.test(type.trim())) {
    throw new Refusal("unsupported-media-type", "content type");
  }
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes));
  } catch {
    throw new Refusal("bad-request", "malformed JSON");
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Refusal("bad-request", "body is not an object");
  }
  return { bytes, value: value as Record<string, unknown> };
}

async function readCapped(request: Request): Promise<Uint8Array> {
  if (!request.body) return new Uint8Array();
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_BODY_BYTES) {
      await reader.cancel();
      throw new Refusal("body-too-large", "streamed length");
    }
    chunks.push(value);
  }
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}

/** A required string field of bounded length. */
export function stringField(body: Record<string, unknown>, name: string, maxLength: number): string {
  const value = body[name];
  if (typeof value !== "string" || value.length === 0 || value.length > maxLength) {
    throw new Refusal("bad-request", `field ${name}`);
  }
  return value;
}

/** An optional string field of bounded length. */
export function optionalStringField(body: Record<string, unknown>, name: string, maxLength: number): string | undefined {
  if (body[name] === undefined) return undefined;
  return stringField(body, name, maxLength);
}
