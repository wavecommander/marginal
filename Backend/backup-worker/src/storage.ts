// The user's folder in R2, through the Worker's bucket binding: where it is, how much it holds,
// and emptying it in bounded steps.

import type { Namespace } from "./subscription";
import { userPrefix } from "./tempCredentials";

/**
 * An account's folder. Customers' data is under `users/`; sandbox and Xcode purchases (App
 * Review, TestFlight, development) under `sandbox/`, so test data never mixes with theirs.
 */
export function folderFor(folderKey: string, namespace: Namespace): string {
  const prefix = userPrefix(folderKey); // validates the key: 64 lower-case hex digits
  return namespace === "users" ? prefix : `sandbox/${prefix.slice("users/".length)}`;
}

/** Both of an account's folders. */
export function foldersOf(folderKey: string): string[] {
  return [folderFor(folderKey, "users"), folderFor(folderKey, "sandbox")];
}

/** Most list pages one usage count may read (1,000 objects each). */
export const MAX_USAGE_PAGES = 100;

export interface Usage {
  bytes: number;
  /** False when the folder holds more objects than one count may read; `bytes` is then a lower bound. */
  complete: boolean;
}

/** Sums the sizes of every object under `prefix`. */
export async function countUsage(bucket: R2Bucket, prefix: string, maxPages = MAX_USAGE_PAGES): Promise<Usage> {
  let bytes = 0;
  let cursor: string | undefined;
  for (let page = 0; page < maxPages; page++) {
    const listed = await bucket.list({ prefix, cursor, limit: 1000 });
    for (const object of listed.objects) bytes += object.size;
    if (!listed.truncated) return { bytes, complete: true };
    cursor = listed.cursor;
  }
  return { bytes, complete: false };
}

/** A shared allowance of R2 operations, so one invocation stays within the Workers limits. */
export interface Budget {
  operations: number;
}

/**
 * Deletes objects under `prefix` in batches of up to 1,000 (one list and one delete each) until
 * the folder is empty or the budget runs out. Safe to call again: it starts from whatever is
 * left. Returns whether the folder is now empty.
 */
export async function deleteFolder(bucket: R2Bucket, prefix: string, budget: Budget): Promise<{ done: boolean; deleted: number }> {
  if (!prefix.endsWith("/") || prefix.length < 10) throw new Error("deleteFolder: not a user folder");
  let deleted = 0;
  // One operation is enough to find a folder already empty.
  while (budget.operations >= 1) {
    budget.operations -= 1;
    const listed = await bucket.list({ prefix, limit: 1000 });
    const keys = listed.objects.map((object) => object.key);
    if (keys.length === 0) return { done: true, deleted };
    if (budget.operations < 1) break;
    // The listing is by prefix, but check every key anyway before deleting it.
    if (keys.some((key) => !key.startsWith(prefix))) throw new Error("deleteFolder: listing escaped the folder");
    budget.operations -= 1;
    await bucket.delete(keys);
    deleted += keys.length;
    // R2 deletes are strongly consistent: once the last page is gone, the folder is empty.
    if (!listed.truncated) return { done: true, deleted };
  }
  return { done: false, deleted };
}

/**
 * Empties both of an account's folders, `users/` first, within `budget`. With a budget of at
 * least 3, every call makes progress: finding the first folder empty costs one operation.
 */
export async function emptyAccountFolders(bucket: R2Bucket, folderKey: string, budget: Budget): Promise<{ done: boolean; deleted: number }> {
  let deleted = 0;
  for (const folder of foldersOf(folderKey)) {
    const result = await deleteFolder(bucket, folder, budget);
    deleted += result.deleted;
    if (!result.done) return { done: false, deleted };
  }
  return { done: true, deleted };
}
