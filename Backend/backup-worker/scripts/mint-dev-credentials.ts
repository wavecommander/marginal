// Mints one scoped credential for the DEVELOPMENT bucket and prints it as JSON, exactly as the
// Worker would hand it to the app. For local testing of the app's S3 client against real R2:
//
//     node scripts/mint-dev-credentials.ts --user <64 hex digits> [--mode read-write|read-only|read-delete]
//                                          [--ttl <seconds>] [--expired]
//
// Reads the parent token from .dev.vars. The output is a live bearer credential for one test
// folder: do not paste it anywhere or commit it.

import { readFileSync } from "node:fs";
import { ACTIONS, createTempCredentials, userPrefix, type AccessMode } from "../src/tempCredentials.ts";

function argument(name: string): string | undefined {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

const vars: Record<string, string> = {};
for (const line of readFileSync(new URL("../.dev.vars", import.meta.url).pathname, "utf8").split("\n")) {
  const match = /^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/.exec(line);
  if (match && !line.trimStart().startsWith("#")) vars[match[1]!] = match[2]!;
}
for (const name of ["R2_ACCOUNT_ID", "R2_BUCKET_NAME", "R2_PARENT_ACCESS_KEY_ID", "R2_PARENT_SECRET_ACCESS_KEY"]) {
  if (!vars[name]) throw new Error(`.dev.vars: ${name} is empty`);
}

const user = argument("user");
if (!user) throw new Error("--user <64 hex digits> is required");
const mode = (argument("mode") ?? "read-write") as AccessMode;
if (!(mode in ACTIONS)) throw new Error(`--mode must be one of ${Object.keys(ACTIONS).join(", ")}`);
const ttlSeconds = Number(argument("ttl") ?? "300");
const expired = process.argv.includes("--expired");
const s3Host = vars.R2_S3_HOST || `${vars.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`;
const prefix = userPrefix(user);

const credentials = await createTempCredentials({
  accountId: vars.R2_ACCOUNT_ID!,
  s3Host,
  bucket: vars.R2_BUCKET_NAME!,
  parentAccessKeyId: vars.R2_PARENT_ACCESS_KEY_ID!,
  parentSecretAccessKey: vars.R2_PARENT_SECRET_ACCESS_KEY!,
  actions: ACTIONS[mode],
  prefixes: [prefix],
  ttlSeconds,
  // Already expired: issued long enough ago that its whole life is in the past.
  now: expired ? new Date(Date.now() - (ttlSeconds + 300) * 1000) : undefined,
});

process.stdout.write(JSON.stringify({
  host: s3Host,
  region: "auto",
  bucket: vars.R2_BUCKET_NAME,
  // Without the trailing slash, as the app's client takes it.
  prefix: prefix.replace(/\/$/, ""),
  mode,
  ...credentials,
}) + "\n");
