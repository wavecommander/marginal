// The Tactile Texts cloud backup service.
//
// The reader signs in with Apple or Google to an account; the App Store subscription pays for
// it. The iPad never holds a long-lived storage key. It asks this Worker for a session; the
// Worker checks the device session, the subscription and that the request comes from the real
// app, then returns R2 credentials that last minutes and reach only that account's folder.
// Backups then travel directly between the iPad and R2: no file data passes through here.
//
//   GET  /v1/health
//   POST /v1/challenge                    a one-time value for App Attest and sign-in
//   POST /v1/attest                       register this app install's attested key
//   POST /v1/auth/apple, /v1/auth/google  sign in (creates the account the first time)
//   POST /v1/auth/change                  change the account's sign-in to the other provider
//   POST /v1/auth/signout, -all           end this device's session, or every one
//   POST /v1/account                      the account screen: sign-in, devices, subscription
//   POST /v1/account/delete               delete the account and everything stored for it
//   POST /v1/session                      device session + assertion -> scoped, short-lived credentials
//   POST /v1/delete-my-data               remove every backup stored for the account
//   POST /v1/apple/notifications          App Store Server Notifications (renewals, expiry, refunds)
//   POST /v1/apple/signin-notifications   Sign in with Apple notifications (consent revoked, ...)
//
// A daily cron deletes the data of subscriptions that ended DELETE_AFTER_DAYS ago, finishes
// account deletions the app left unfinished, and removes expired challenges. The HTTP contract is
// in README.md and src/contract.ts.

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
