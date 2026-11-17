// How much an account's folder holds, counted through the bucket binding and cached on its
// entitlement for USAGE_CACHE_SECONDS.

import * as db from "./db";
import type { Env, Settings } from "./env";
import { logEvent, shortKey } from "./log";
import { countUsage } from "./storage";
import type { Subscriber } from "./subscription";

export interface CurrentUsage {
  bytes: number;
  /** False when the folder holds too many objects to count in one go (treated as over the allowance). */
  complete: boolean;
  countedAt: number;
}

export async function currentUsage(env: Env, subscriber: Subscriber, folder: string, now: number, settings: Settings): Promise<CurrentUsage> {
  if (subscriber.usageCheckedAt !== null && now - subscriber.usageCheckedAt < settings.usageCacheSeconds * 1000) {
    return { bytes: subscriber.usageBytes, complete: true, countedAt: subscriber.usageCheckedAt };
  }
  const usage = await countUsage(env.BUCKET, folder);
  if (usage.complete) {
    await db.saveUsage(env.DB, subscriber.accountId, subscriber.namespace, usage.bytes, now);
  } else {
    // Too many objects to count in one go: treated as over the allowance, and not cached.
    logEvent("usage-count-incomplete", { account: shortKey(subscriber.accountId) });
  }
  return { bytes: usage.bytes, complete: usage.complete, countedAt: now };
}
