// Logging that cannot leak. Every line is one JSON object of an event name and a few plain fields
// chosen at the call site. Never pass a request body, a JWS or JWT (ID tokens included), a
// credential, a session token, a secret, a provider's user ID, an email address, or a full
// account ID, folder key or identity hash: use `shortKey` for the last three.

type Field = string | number | boolean | null | undefined;

export function logEvent(event: string, fields: Record<string, Field> = {}): void {
  console.log(JSON.stringify({ event, ...fields }));
}

export function logError(event: string, fields: Record<string, Field> = {}): void {
  console.error(JSON.stringify({ event, ...fields }));
}

/** Enough of an account ID to follow one account through the logs, too little to name it. */
export function shortKey(key: string): string {
  return key.slice(0, 8);
}
