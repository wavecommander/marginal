// The Tactile Texts cloud backup service.
//
// The iPad never holds a long-lived storage key. It asks this Worker for a session; the Worker
// checks the subscription and that the request comes from the real app, then returns R2
// credentials that last minutes and reach only that user's folder. Backups then travel directly
// between the iPad and R2: no file data passes through here.
//
//   POST /v1/challenge            a one-time value for App Attest
//   POST /v1/attest               register this app install's attested key
//   POST /v1/session              subscription + assertion -> scoped, short-lived credentials
//   POST /v1/delete-my-data       remove everything stored for the caller
//   POST /v1/apple/notifications  App Store Server Notifications (renewals, expiry, refunds)
//   GET  /v1/health
//
// A daily cron makes ended subscriptions read-only and, later, deletes their data.

import { readSettings, type Env } from "./env";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    try {
      if (request.method === "GET" && url.pathname === "/v1/health") {
        // Also proves the settings parse: a deployment with bad settings fails here, loudly.
        const settings = readSettings(env);
        return json(200, { ok: true, environment: settings.environment });
      }
      const route = `${request.method} ${url.pathname}`;
      switch (route) {
        case "POST /v1/challenge":
        case "POST /v1/attest":
        case "POST /v1/session":
        case "POST /v1/delete-my-data":
        case "POST /v1/apple/notifications":
          return problem(501, "not-implemented", "This endpoint is not built yet.");
        default:
          return problem(404, "not-found", "No such endpoint.");
      }
    } catch (error) {
      // Never echo an internal error to a client: it could carry a secret or a stack.
      console.error("unhandled", error instanceof Error ? error.message : String(error));
      return problem(500, "internal", "Something went wrong.");
    }
  },

  async scheduled(_controller: ScheduledController, _env: Env): Promise<void> {
    // The lapse policy (read-only, then deletion) runs here.
  },
} satisfies ExportedHandler<Env>;

export function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" },
  });
}

/** An error the app can act on: a stable `code` plus a sentence a person can read. */
export function problem(status: number, code: string, message: string): Response {
  return json(status, { error: { code, message } });
}
