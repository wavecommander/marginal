// Proves, against a real R2 development bucket, that the credentials this Worker mints behave
// the way the service depends on: usable inside one user's folder, refused everywhere else,
// limited to the actions of their mode, and dead after expiry.
//
// Nothing here can be checked locally: `wrangler dev`'s S3 endpoint takes fixed keys and does
// not evaluate session tokens. Run it once the development bucket and its parent token exist:
//
//     cp .dev.vars.example .dev.vars     # then fill it in
//     npm run prove
//
// It writes only under two throwaway folders, `users/<random>/`, and deletes what it wrote.
// It prints statuses and R2's error codes, never a key or a token.

import { readFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import { AwsClient } from "aws4fetch";
import { ACTIONS, createTempCredentials, userPrefix, type AccessMode } from "../src/tempCredentials.ts";

function loadVars(path: string): Record<string, string> {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    throw new Error(`${path} not found: copy .dev.vars.example to .dev.vars and fill it in`);
  }
  const vars: Record<string, string> = {};
  for (const line of text.split("\n")) {
    const match = /^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/.exec(line);
    if (match && !line.trimStart().startsWith("#")) vars[match[1]!] = match[2]!.replace(/^"(.*)"$/, "$1");
  }
  return vars;
}

const vars = loadVars(new URL("../.dev.vars", import.meta.url).pathname);
for (const name of ["R2_ACCOUNT_ID", "R2_BUCKET_NAME", "R2_PARENT_ACCESS_KEY_ID", "R2_PARENT_SECRET_ACCESS_KEY"]) {
  if (!vars[name]) throw new Error(`.dev.vars: ${name} is empty`);
}
const accountId = vars.R2_ACCOUNT_ID!;
const bucket = vars.R2_BUCKET_NAME!;
const s3Host = vars.R2_S3_HOST || `${accountId}.r2.cloudflarestorage.com`;
const base = `https://${s3Host}/${bucket}`;

const me = userPrefix(randomBytes(32).toString("hex"));
const someoneElse = userPrefix(randomBytes(32).toString("hex"));

async function client(mode: AccessMode, options: { expired?: boolean } = {}): Promise<AwsClient> {
  const credentials = await createTempCredentials({
    accountId,
    s3Host,
    bucket,
    parentAccessKeyId: vars.R2_PARENT_ACCESS_KEY_ID!,
    parentSecretAccessKey: vars.R2_PARENT_SECRET_ACCESS_KEY!,
    actions: ACTIONS[mode],
    prefixes: [me],
    ttlSeconds: 300,
    // An already-expired credential: issued ten minutes ago with a five-minute life.
    now: options.expired ? new Date(Date.now() - 600_000) : undefined,
  });
  return new AwsClient({ ...credentials, service: "s3", region: "auto" });
}

interface Outcome { status: number; code: string | null; body: string }

async function call(aws: AwsClient, method: string, path: string, body?: BodyInit): Promise<Outcome> {
  const response = await aws.fetch(`${base}${path}`, { method, body });
  const text = method === "HEAD" ? "" : await response.text();
  const code = /<Code>([^<]+)<\/Code>/.exec(text)?.[1] ?? null;
  return { status: response.status, code, body: text };
}

let failures = 0;
function check(what: string, outcome: Outcome, expected: "allowed" | "refused"): void {
  const allowed = outcome.status >= 200 && outcome.status < 300;
  const ok = expected === "allowed" ? allowed : !allowed && (outcome.status === 403 || outcome.status === 401 || outcome.status === 400);
  if (!ok) failures += 1;
  const detail = outcome.code ? `${outcome.status} ${outcome.code}` : `${outcome.status}`;
  console.log(`${ok ? "ok  " : "FAIL"}  ${what.padEnd(58)} expected ${expected.padEnd(7)} got ${detail}`);
}

const key = (prefix: string, name: string) => `/${prefix}${encodeURIComponent(name)}`;
const readWrite = await client("read-write");
const readOnly = await client("read-only");
const readDelete = await client("read-delete");

console.log(`bucket ${bucket}, test folder ${me.slice(0, 14)}…/\n`);

// Inside the user's own folder, read-write.
check("put a small object in my folder", await call(readWrite, "PUT", key(me, "Backups/2026-11-15T12-00-00Z test.ttbackup"), "hello"), "allowed");
check("head it", await call(readWrite, "HEAD", key(me, "Backups/2026-11-15T12-00-00Z test.ttbackup")), "allowed");
check("get it", await call(readWrite, "GET", key(me, "Backups/2026-11-15T12-00-00Z test.ttbackup")), "allowed");
const listed = await call(readWrite, "GET", `?list-type=2&prefix=${encodeURIComponent(me)}`);
check("list my folder", listed, "allowed");
if (!listed.body.includes("test.ttbackup")) { failures += 1; console.log("FAIL  the listing does not show the object just written"); }

// Multipart, as a large PDF goes up: two parts, the first of the 5 MiB minimum.
const pdfKey = key(me, "PDFs/proof.pdf");
const created = await call(readWrite, "POST", `${pdfKey}?uploads`);
check("start a multipart upload", created, "allowed");
const uploadId = /<UploadId>([^<]+)<\/UploadId>/.exec(created.body)?.[1];
if (uploadId) {
  const etags: string[] = [];
  for (const [index, size] of [5 * 1024 * 1024, 1024].entries()) {
    const response = await readWrite.fetch(`${base}${pdfKey}?partNumber=${index + 1}&uploadId=${encodeURIComponent(uploadId)}`,
      { method: "PUT", body: new Uint8Array(size).fill(index + 1) });
    check(`upload part ${index + 1}`, { status: response.status, code: null, body: await response.text() }, "allowed");
    etags.push(response.headers.get("etag") ?? "");
  }
  const completion = `<CompleteMultipartUpload>${etags.map((etag, index) =>
    `<Part><PartNumber>${index + 1}</PartNumber><ETag>${etag}</ETag></Part>`).join("")}</CompleteMultipartUpload>`;
  const completed = await call(readWrite, "POST", `${pdfKey}?uploadId=${encodeURIComponent(uploadId)}`, completion);
  check("complete the multipart upload", completed.body.includes("<Error>") ? { ...completed, status: 500 } : completed, "allowed");
  const ranged = await readWrite.fetch(`${base}${pdfKey}`, { headers: { range: "bytes=5242880-5242889" } });
  check("ranged get of the uploaded file", { status: ranged.status, code: null, body: "" }, "allowed");
}

// Outside the folder: another user's data, and the bucket as a whole.
check("put into someone else's folder", await call(readWrite, "PUT", key(someoneElse, "Backups/x.ttbackup"), "x"), "refused");
check("get from someone else's folder", await call(readWrite, "GET", key(someoneElse, "Backups/x.ttbackup")), "refused");
check("list someone else's folder", await call(readWrite, "GET", `?list-type=2&prefix=${encodeURIComponent(someoneElse)}`), "refused");
check("list the whole bucket", await call(readWrite, "GET", "?list-type=2"), "refused");
check("list every user's folder", await call(readWrite, "GET", "?list-type=2&prefix=users%2F"), "refused");

// Modes.
check("read-only: get", await call(readOnly, "GET", key(me, "Backups/2026-11-15T12-00-00Z test.ttbackup")), "allowed");
check("read-only: put", await call(readOnly, "PUT", key(me, "Backups/y.ttbackup"), "y"), "refused");
check("read-only: delete", await call(readOnly, "DELETE", key(me, "Backups/2026-11-15T12-00-00Z test.ttbackup")), "refused");
check("read-only: start a multipart upload", await call(readOnly, "POST", `${key(me, "PDFs/z.pdf")}?uploads`), "refused");
check("read-delete: put", await call(readDelete, "PUT", key(me, "Backups/y.ttbackup"), "y"), "refused");
check("read-delete: get", await call(readDelete, "GET", key(me, "Backups/2026-11-15T12-00-00Z test.ttbackup")), "allowed");

// Expiry. The exact status and code R2 gives here is what the app's client must recognise.
const expired = await call(await client("read-write", { expired: true }), "GET", key(me, "Backups/2026-11-15T12-00-00Z test.ttbackup"));
check("an expired credential", expired, "refused");
console.log(`      (expired credential: HTTP ${expired.status}, code ${expired.code ?? "none"})`);

// Clean up, using the make-room mode for one object to prove it deletes.
check("read-delete: delete", await call(readDelete, "DELETE", key(me, "Backups/2026-11-15T12-00-00Z test.ttbackup")), "allowed");
check("delete the uploaded file", await call(readWrite, "DELETE", pdfKey), "allowed");
const after = await call(readWrite, "GET", `?list-type=2&prefix=${encodeURIComponent(me)}`);
if (after.body.includes("<Key>")) { failures += 1; console.log("FAIL  objects are left in the test folder"); }

console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check(s) failed.`);
process.exit(failures === 0 ? 0 : 1);
