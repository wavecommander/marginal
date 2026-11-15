// Logging that cannot leak. Every line is one JSON object of an event name and a few plain fields
// chosen at the call site. Never pass a request body, a JWS, a credential, a secret or a full
// user key: use `shortKey` for the last.

type Field = string | number | boolean | null | undefined;

export function logEvent(event: string, fields: Record<string, Field> = {}): void {
  console.log(JSON.stringify({ event, ...fields }));
}

export function logError(event: string, fields: Record<string, Field> = {}): void {
  console.error(JSON.stringify({ event, ...fields }));
}

/** Enough of a user key to follow one user through the logs, too little to name their folder. */
export function shortKey(userKey: string): string {
  return userKey.slice(0, 8);
}
