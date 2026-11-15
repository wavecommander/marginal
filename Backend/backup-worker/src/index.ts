// The Tactile Texts cloud backup service.
//
// The iPad never holds a long-lived storage key. It asks this Worker for a session; the Worker
// checks the subscription and that the request comes from the real app, then returns R2
// credentials that last minutes and reach only that user's folder. Backups then travel directly
// between the iPad and R2: no file data passes through here.
//
//   GET  /v1/health
//   POST /v1/challenge            a one-time value for App Attest
//   POST /v1/attest               register this app install's attested key
//   POST /v1/session              subscription + assertion -> scoped, short-lived credentials
//   POST /v1/delete-my-data       remove everything stored for the caller
//   POST /v1/apple/notifications  App Store Server Notifications (renewals, expiry, refunds)
//
// A daily cron deletes the data of subscriptions that ended DELETE_AFTER_DAYS ago, and expired
// challenges. The HTTP contract is in README.md and src/contract.ts.

import { reason } from "./appleJws";
import type { Env } from "./env";
import { logError } from "./log";
import { defaultDeps, handle, runScheduled } from "./service";

export type * from "./contract";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return handle(request, env, defaultDeps());
  },

  async scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(
      runScheduled(env, defaultDeps()).then(
        () => undefined,
        (error: unknown) => logError("cron-failed", { reason: reason(error) }),
      ),
    );
  },
} satisfies ExportedHandler<Env>;
