// Who a user is, to this service.
//
// There are no accounts. A user is their App Store subscription: Apple gives every subscription
// an "original transaction ID" that stays the same through renewals and when the purchase is
// restored on another device signed in to the same Apple Account. The service never stores that
// ID. It stores, and names the user's folder with, a keyed hash of it:
//
//     userKey = hex(HMAC-SHA256(USER_KEY_SECRET, "tactile-backup-user-v1\0" || originalTransactionId))
//
// so a folder name or a database row cannot be worked back to a subscription without the
// Worker's secret, and the same subscription always maps to the same folder.

const DOMAIN = "tactile-backup-user-v1\0";

export async function userKey(secret: string, originalTransactionId: string): Promise<string> {
  if (secret.length < 32) throw new Error("USER_KEY_SECRET must be at least 32 characters");
  // Apple's IDs are decimal digits; refuse anything else so no other string can be hashed in.
  if (!/^[0-9]{1,40}$/.test(originalTransactionId)) throw new Error("not an original transaction ID");
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(DOMAIN + originalTransactionId)));
  return Array.from(mac, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
