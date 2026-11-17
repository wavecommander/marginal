// Proves that the object store gives sync what it depends on (docs/CLOUD_SYNC_PLAN.md, "How two
// devices write one book safely"): a `PutObject` with `If-None-Match: *` creates a key at most
// once, a `PutObject` with `If-Match: <etag>` replaces an object only if nobody else has, both
// hold under a race, and the ETag a listing reports is the one `If-Match` accepts.
//
// Two targets:
//
//     node scripts/prove-conditional-writes.ts            the real development bucket, with the
//                                                         Worker's own temporary credentials
//                                                         (needs .dev.vars, as `npm run prove`)
//     node scripts/prove-conditional-writes.ts --local 8797
//                                                         `wrangler dev --port 8797`'s local S3
//                                                         endpoint (fixed keys from wrangler.jsonc)
//
// It writes only under one throwaway folder and deletes what it wrote. It prints statuses and
// error codes, never a key or a token.

import { readFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { AwsClient } from "aws4fetch";
import { ACTIONS, createTempCredentials, userPrefix } from "../src/tempCredentials.ts";

const RACERS = 12;

function loadVars(path: string): Record<string, string> {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    throw new Error(`${path} not found: copy .dev.vars.example to .dev.vars and fill it in, or pass --local <port>`);
  }
  const vars: Record<string, string> = {};
  for (const line of text.split("\n")) {
    const match = /^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/.exec(line);
    if (match && !line.trimStart().startsWith("#")) vars[match[1]!] = match[2]!.replace(/^"(.*)"$/, "$1");
  }
  return vars;
}

const folder = userPrefix(randomBytes(32).toString("hex"));
let aws: AwsClient;
let base: string;
let target: string;

const localAt = process.argv.indexOf("--local");
if (localAt >= 0) {
  const port = process.argv[localAt + 1] ?? "8787";
  const bucket = "tactile-texts-backups-dev";
  aws = new AwsClient({ accessKeyId: "local-access-key-id", secretAccessKey: "local-secret-access-key", service: "s3", region: "auto" });
  base = `http://127.0.0.1:${port}/cdn-cgi/local/r2/s3/${bucket}`;
  target = `wrangler dev on port ${port}`;
} else {
  const vars = loadVars(new URL("../.dev.vars", import.meta.url).pathname);
  for (const name of ["R2_ACCOUNT_ID", "R2_BUCKET_NAME", "R2_PARENT_ACCESS_KEY_ID", "R2_PARENT_SECRET_ACCESS_KEY"]) {
    if (!vars[name]) throw new Error(`.dev.vars: ${name} is empty`);
  }
  const s3Host = vars.R2_S3_HOST || `${vars.R2_ACCOUNT_ID}.r2.cloudflarestorage.com`;
  const credentials = await createTempCredentials({
    accountId: vars.R2_ACCOUNT_ID!,
    s3Host,
    bucket: vars.R2_BUCKET_NAME!,
    parentAccessKeyId: vars.R2_PARENT_ACCESS_KEY_ID!,
    parentSecretAccessKey: vars.R2_PARENT_SECRET_ACCESS_KEY!,
    actions: ACTIONS["read-write"],
    prefixes: [folder],
    ttlSeconds: 300,
  });
  aws = new AwsClient({ ...credentials, service: "s3", region: "auto" });
  base = `https://${s3Host}/${vars.R2_BUCKET_NAME}`;
  target = `bucket ${vars.R2_BUCKET_NAME}, temporary read-write credentials`;
}

interface Outcome { status: number; code: string | null; etag: string | null; body: string }

async function call(method: string, path: string, body?: string, headers: Record<string, string> = {}): Promise<Outcome> {
  const response = await aws.fetch(`${base}${path}`, { method, body, headers });
  const text = method === "HEAD" ? "" : await response.text();
  return { status: response.status, code: /<Code>([^<]+)<\/Code>/.exec(text)?.[1] ?? null, etag: response.headers.get("etag"), body: text };
}

let failures = 0;
function report(ok: boolean, what: string, detail: string): void {
  if (!ok) failures += 1;
  console.log(`${ok ? "ok  " : "FAIL"}  ${what.padEnd(62)} ${detail}`);
}
const show = (o: Outcome) => (o.code ? `${o.status} ${o.code}` : `${o.status}`);
const tally = (outcomes: Outcome[]) => {
  const counts = new Map<string, number>();
  for (const o of outcomes) counts.set(show(o), (counts.get(show(o)) ?? 0) + 1);
  return [...counts].map(([k, n]) => `${n}× ${k}`).join(", ");
};
const succeeded = (o: Outcome) => o.status >= 200 && o.status < 300;

// Each path segment is encoded on its own: an encoded slash signs differently between servers.
const key = (name: string) => `/${folder}${name.split("/").map(encodeURIComponent).join("/")}`;
const head = key("Sync/v1/books/proof");

console.log(`${target}\ntest folder ${folder.slice(0, 14)}…/\n`);

// Create once.
const first = await call("PUT", head, "v1", { "If-None-Match": "*" });
report(succeeded(first) && !!first.etag, "create with If-None-Match: * on an absent key", `${show(first)}, ETag ${first.etag ? "returned" : "MISSING"}`);
const again = await call("PUT", head, "v1-again", { "If-None-Match": "*" });
report(again.status === 412, "create again with If-None-Match: *", show(again));

// The same ETag everywhere.
const headed = await call("HEAD", head);
const got = await call("GET", head);
const listed = await call("GET", `?list-type=2&prefix=${encodeURIComponent(folder)}`);
const listedTag = /<ETag>([^<]+)<\/ETag>/.exec(listed.body)?.[1]?.replaceAll("&quot;", '"') ?? null;
report(headed.etag === first.etag && got.etag === first.etag && listedTag === first.etag,
  "put, head, get and list report the same ETag", `put ${first.etag} head ${headed.etag} get ${got.etag} list ${listedTag}`);
report(got.body === "v1", "the refused create changed nothing", `body ${JSON.stringify(got.body)}`);

// Replace only if unchanged.
const second = await call("PUT", head, "v2", { "If-Match": first.etag ?? "" });
report(succeeded(second) && second.etag !== first.etag, "replace with If-Match: <current ETag>", show(second));
const stale = await call("PUT", head, "v2-stale", { "If-Match": first.etag ?? "" });
report(stale.status === 412, "replace with If-Match: <stale ETag>", show(stale));
const absent = await call("PUT", key("Sync/v1/books/absent"), "x", { "If-Match": first.etag ?? "" });
report(!succeeded(absent), "If-Match on a key that does not exist", show(absent));
const unconditional = await call("PUT", key("Sync/v1/blobs/blob"), "blob");
const blobAgain = await call("PUT", key("Sync/v1/blobs/blob"), "blob");
report(succeeded(unconditional) && succeeded(blobAgain) && unconditional.etag === blobAgain.etag,
  "an unconditional put of the same bytes twice keeps the ETag", `${show(unconditional)}, ${show(blobAgain)}`);

// Races: many writers, one winner.
const createRace = await Promise.all(Array.from({ length: RACERS }, (_, i) =>
  call("PUT", key("Sync/v1/books/race-create"), `writer ${i}`, { "If-None-Match": "*" })));
report(createRace.filter(succeeded).length === 1 && createRace.filter((o) => o.status === 412).length === RACERS - 1,
  `${RACERS} concurrent creates of one key: exactly one wins`, tally(createRace));

const replaceRace = await Promise.all(Array.from({ length: RACERS }, (_, i) =>
  call("PUT", head, `racer ${i}`, { "If-Match": second.etag ?? "" })));
const winners = replaceRace.filter(succeeded);
report(winners.length === 1 && replaceRace.filter((o) => o.status === 412).length === RACERS - 1,
  `${RACERS} concurrent replaces from one ETag: exactly one wins`, tally(replaceRace));
const final = await call("GET", head);
report(winners.length === 1 && final.etag === winners[0]!.etag, "the stored object is the winner's", `ETag ${final.etag}`);

// Clean up.
for (const name of ["Sync/v1/books/proof", "Sync/v1/books/race-create", "Sync/v1/books/absent", "Sync/v1/blobs/blob"]) await call("DELETE", key(name));
const after = await call("GET", `?list-type=2&prefix=${encodeURIComponent(folder)}`);
report(!after.body.includes("<Key>"), "the test folder is empty again", show(after));

console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check(s) failed.`);
process.exit(failures === 0 ? 0 : 1);
