#!/usr/bin/env bash
# Tactile Texts Cloud in development, without Apple, Google or the App Store: sets up the `dev`
# backup Worker's development switches and points debug builds at it. See
# Backend/backup-worker/README.md, "Testing sync in development without Apple, Google or the App Store".
#
# Usage:
#   scripts/dev-cloud.sh [--user NAME] [--port N]   local: set up, then run `wrangler dev` (foreground)
#   scripts/dev-cloud.sh --setup-only [...]         local: set up, do not start wrangler
#   scripts/dev-cloud.sh --e2e-test [--port N]      with the local Worker running: the end-to-end test
#   scripts/dev-cloud.sh --delete-dev-user NAME     with the local Worker running: remove a dev user and its objects
#   scripts/dev-cloud.sh --host HOST [--user NAME]  a deployed `dev` Worker (HTTPS), for real devices
#   scripts/dev-cloud.sh --remove                   take this script's lines out of Config/Local.xcconfig
#   scripts/dev-cloud.sh --deploy-settings          names (never values) the deployed `dev` Worker needs
#   scripts/dev-cloud.sh --push-secrets [--dry-run] copy the dev secrets from .dev.vars to the deployed `dev` Worker
#   scripts/dev-cloud.sh --help
#
# Never prints a secret. Safe to run again: values already set are left as they are.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER="$REPO/Backend/backup-worker"
DEV_VARS="$WORKER/.dev.vars"
DEV_VARS_EXAMPLE="$WORKER/.dev.vars.example"
LOCAL_XCCONFIG="$REPO/Config/Local.xcconfig"
BEGIN_MARK="// BEGIN scripts/dev-cloud.sh: development only, Debug builds only. Remove with scripts/dev-cloud.sh --remove."
END_MARK="// END scripts/dev-cloud.sh"
DEFAULT_PORT=8797
DEFAULT_USER=dev
FALLBACK_PRODUCT="software.tactile.texts.backup.standard"

# Secrets the deployed `dev` Worker takes with `wrangler secret put` (not vars in wrangler.jsonc).
PUSHED_SECRETS=(R2_PARENT_ACCESS_KEY_ID R2_PARENT_SECRET_ACCESS_KEY IDENTITY_KEY_SECRET APP_ATTEST_BYPASS_SECRET
  DEV_TEST_SIGNIN_SECRET DEV_TEST_ENTITLEMENT)
# Pushed too when set (both or neither).
OPTIONAL_SECRETS=(APPLE_SIWA_KEY_ID APPLE_SIWA_PRIVATE_KEY)
# Vars of the top-level (`dev`) deployment in wrangler.jsonc that must be filled in there.
REQUIRED_VARS=(R2_ACCOUNT_ID R2_S3_HOST APPLE_TEAM_ID)

usage() {
  cat <<EOF
scripts/dev-cloud.sh: test Tactile Texts Cloud backup and sync in development, without Sign in with
Apple, Sign in with Google or an App Store subscription.

  Local (simulators):
    scripts/dev-cloud.sh [--user NAME] [--port N]
      1. Creates Backend/backup-worker/.dev.vars from .dev.vars.example if it is missing, and fills
         in only the development values that are missing, with fresh random ones:
         IDENTITY_KEY_SECRET, APP_ATTEST_BYPASS_SECRET, DEV_TEST_SIGNIN_SECRET, DEV_TEST_ENTITLEMENT
         (the backup product ID) and a placeholder APPLE_TEAM_ID. Values already set are never
         changed, and no value is ever printed.
      2. Checks the R2 values (R2_PARENT_ACCESS_KEY_ID, R2_PARENT_SECRET_ACCESS_KEY, R2_ACCOUNT_ID,
         R2_S3_HOST: a development bucket and a token limited to it) and stops if any is missing.
      3. Runs npm ci (if node_modules is missing) and npm run migrate:local.
      4. Writes these lines into the git-ignored Config/Local.xcconfig, Debug builds only, between
         marked begin and end lines (the rest of the file is left alone):
           BACKUP_SERVICE_HOST = 127.0.0.1:<port>      BACKUP_PRODUCT_IDS = <product>
           BACKUP_SERVICE_ATTEST_BYPASS, BACKUP_SERVICE_DEV_SIGNIN (from .dev.vars)
           BACKUP_SERVICE_DEV_USER = <name>
      5. Starts npx wrangler dev on 127.0.0.1:<port> in the foreground (Ctrl-C stops it).
    Then build and run the app on a simulator (scripts/build.sh, or Xcode). On Tactile Texts Cloud,
    either sign-in button signs in as the dev user. A second simulator signed in as the same dev
    user is the same account and syncs with the first; it asks for the recovery key, which the
    first one shows after its first backup or sync (iCloud Keychain does not sync between
    simulators).

    --user NAME   the dev user the build signs in as (default: $DEFAULT_USER). The signed-out page can
                  change it on a device without rebuilding.
    --port N      the local port (default: $DEFAULT_PORT).
    --setup-only  steps 1 to 4, without starting wrangler.
    --e2e-test [--port N] [--user PREFIX]
                  with the Worker running (another terminal): the app's own client end to end,
                  two simulated devices as one fresh dev user (PREFIX-<random>), no purchase, a
                  backup, the recovery key, a sync round each way, against the real development
                  bucket; it removes what it wrote and deletes the account. TACTILE_SIM picks the
                  simulator, as for scripts/test.sh.
    --delete-dev-user NAME [--port N]
                  with the Worker running: deletes that dev user's accounts (its Apple and Google
                  stand-ins) and every object they hold in the development bucket. Use it after
                  testing: a local wrangler dev's own Delete Account and Delete My Cloud Backups
                  only empty its LOCAL bucket, so the real objects would otherwise stay.

  A deployed dev Worker (real iPads and iPhones):
    scripts/dev-cloud.sh --host <name>.workers.dev [--user NAME]
      Steps 1 and 4 only, with BACKUP_SERVICE_HOST = that host (reached over HTTPS). The deployed
      Worker must hold the same secrets: see --push-secrets. Build for a device in Debug:
      TACTILE_CONFIG=Debug scripts/device.sh.
    scripts/dev-cloud.sh --deploy-settings
      Lists the names (never the values) the deployed dev Worker needs, and which of them are set
      in .dev.vars.
    scripts/dev-cloud.sh --push-secrets [--dry-run]
      Copies the secrets from .dev.vars to the deployed top-level (dev) Worker with
      wrangler secret put, the value on standard input, never on the command line or the screen.
      --dry-run prints the names it would set and sends nothing. Never touches env.production.

  --remove   takes this script's lines out of Config/Local.xcconfig (the rest stays). .dev.vars and
             the local D1 database are left as they are.

Every value this writes into Config/Local.xcconfig ends up readable in the built app: such a
build is for your own simulators and devices only, never for anyone else.
EOF
}

say() { printf 'dev-cloud: %s\n' "$*"; }
die() { printf 'dev-cloud: %s\n' "$*" >&2; exit 1; }

# MARK: .dev.vars (KEY=value lines; values never printed)

# The value of KEY in FILE, without surrounding double quotes; empty when absent. Callers keep it in
# a variable and never echo it.
dotenv_get() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  KEY="$key" awk '
    index($0, ENVIRON["KEY"] "=") == 1 { v = substr($0, length(ENVIRON["KEY"]) + 2) }
    END { sub(/^"/, "", v); sub(/"$/, "", v); printf "%s", v }
  ' "$file"
}

# Sets KEY to VALUE in FILE: replaces its line, or appends one. The value goes through the
# environment, not the command line.
dotenv_set() {
  local file="$1" key="$2" value="$3" tmp
  tmp="$(mktemp "$file.XXXXXX")"
  chmod 600 "$tmp"
  KEY="$key" VALUE="$value" awk '
    index($0, ENVIRON["KEY"] "=") == 1 { if (!done) print ENVIRON["KEY"] "=" ENVIRON["VALUE"]; done = 1; next }
    { print }
    END { if (!done) print ENVIRON["KEY"] "=" ENVIRON["VALUE"] }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

random_hex() { openssl rand -hex "$1"; }

# The first product ID in the top-level PRODUCT_ALLOWANCES of wrangler.jsonc.
default_product() {
  local line id
  line="$(grep -m 1 '"PRODUCT_ALLOWANCES"' "$WORKER/wrangler.jsonc" || true)"
  id="$(printf '%s' "$line" | sed -nE 's/.*\{\\"([A-Za-z0-9._-]+)\\".*/\1/p')"
  printf '%s' "${id:-$FALLBACK_PRODUCT}"
}

# Creates .dev.vars if needed and fills in only the missing development values.
prepare_dev_vars() {
  if [[ ! -f "$DEV_VARS" ]]; then
    cp "$DEV_VARS_EXAMPLE" "$DEV_VARS"
    chmod 600 "$DEV_VARS"
    say "created Backend/backup-worker/.dev.vars from .dev.vars.example"
  fi
  local filled=()
  if [[ -z "$(dotenv_get "$DEV_VARS" IDENTITY_KEY_SECRET)" ]]; then
    dotenv_set "$DEV_VARS" IDENTITY_KEY_SECRET "$(random_hex 32)"; filled+=(IDENTITY_KEY_SECRET)
  fi
  if [[ -z "$(dotenv_get "$DEV_VARS" APP_ATTEST_BYPASS_SECRET)" ]]; then
    dotenv_set "$DEV_VARS" APP_ATTEST_BYPASS_SECRET "$(random_hex 24)"; filled+=(APP_ATTEST_BYPASS_SECRET)
  fi
  if [[ -z "$(dotenv_get "$DEV_VARS" DEV_TEST_SIGNIN_SECRET)" ]]; then
    dotenv_set "$DEV_VARS" DEV_TEST_SIGNIN_SECRET "$(random_hex 24)"; filled+=(DEV_TEST_SIGNIN_SECRET)
  fi
  if [[ -z "$(dotenv_get "$DEV_VARS" DEV_TEST_ENTITLEMENT)" ]]; then
    dotenv_set "$DEV_VARS" DEV_TEST_ENTITLEMENT "$(default_product)"; filled+=(DEV_TEST_ENTITLEMENT)
  fi
  if [[ -z "$(dotenv_get "$DEV_VARS" APPLE_TEAM_ID)" ]]; then
    # Any 10 uppercase letters or digits pass the settings check; App Attest is bypassed.
    dotenv_set "$DEV_VARS" APPLE_TEAM_ID "DEVTEAM000"; filled+=(APPLE_TEAM_ID)
  fi
  if ((${#filled[@]})); then
    say "filled in .dev.vars (values not shown): ${filled[*]}"
  else
    say ".dev.vars already has every development value; nothing changed"
  fi
}

# Says plainly which R2 values are missing; returns 1 if any is.
check_r2() {
  local missing=() key
  for key in R2_PARENT_ACCESS_KEY_ID R2_PARENT_SECRET_ACCESS_KEY R2_ACCOUNT_ID R2_S3_HOST; do
    [[ -n "$(dotenv_get "$DEV_VARS" "$key")" ]] || missing+=("$key")
  done
  if ((${#missing[@]})); then
    cat >&2 <<EOF
dev-cloud: Backend/backup-worker/.dev.vars is missing: ${missing[*]}
  The Worker mints credentials for a real R2 bucket. Put in a DEVELOPMENT bucket
  (tactile-texts-backups-dev) and an R2 API token limited to Object Read & Write on it:
    R2_PARENT_ACCESS_KEY_ID, R2_PARENT_SECRET_ACCESS_KEY  (R2 > Manage API Tokens)
    R2_ACCOUNT_ID  (32 hex digits)   R2_S3_HOST  (<account id>.r2.cloudflarestorage.com)
  Never the production bucket or its token. Then run this again.
EOF
    return 1
  fi
}

# MARK: Config/Local.xcconfig

remove_block() {
  [[ -f "$LOCAL_XCCONFIG" ]] || return 0
  local tmp
  tmp="$(mktemp "$LOCAL_XCCONFIG.XXXXXX")"
  BEGIN_MARK="$BEGIN_MARK" END_MARK="$END_MARK" awk '
    index($0, "// BEGIN scripts/dev-cloud.sh") == 1 { skip = 1; next }
    skip && index($0, ENVIRON["END_MARK"]) == 1 { skip = 0; next }
    !skip { print }
  ' "$LOCAL_XCCONFIG" >"$tmp"
  # Keep the file's permissions.
  chmod "$(stat -f '%Lp' "$LOCAL_XCCONFIG")" "$tmp"
  mv "$tmp" "$LOCAL_XCCONFIG"
}

# Writes the block for HOST (no scheme) and USER, replacing an earlier one. Debug builds only
# (`[config=Debug]`), so a Release or archive build never carries these values.
write_block() {
  local host="$1" user="$2" bypass signin product
  bypass="$(dotenv_get "$DEV_VARS" APP_ATTEST_BYPASS_SECRET)"
  signin="$(dotenv_get "$DEV_VARS" DEV_TEST_SIGNIN_SECRET)"
  product="$(dotenv_get "$DEV_VARS" DEV_TEST_ENTITLEMENT)"
  [[ -n "$bypass" && -n "$signin" && -n "$product" ]] || die ".dev.vars lacks a development value; run without --remove first"
  # In an xcconfig, `//` starts a comment: a value holding one would be cut short.
  [[ "$bypass$signin$product$host$user" != *"//"* ]] || die "a value contains //, which an xcconfig cannot hold"
  remove_block
  if [[ ! -f "$LOCAL_XCCONFIG" ]]; then
    : >"$LOCAL_XCCONFIG"
    chmod 600 "$LOCAL_XCCONFIG"
    say "created Config/Local.xcconfig (git-ignored)"
  fi
  # Make sure the block starts on its own line.
  if [[ -s "$LOCAL_XCCONFIG" && -n "$(tail -c 1 "$LOCAL_XCCONFIG")" ]]; then printf '\n' >>"$LOCAL_XCCONFIG"; fi
  {
    printf '%s\n' "$BEGIN_MARK"
    printf '// The app talks to the dev backup Worker at %s, signing in as the dev user below. These\n' "$host"
    printf '// values are readable in the built app: keep such builds on your own simulators and devices.\n'
    printf 'BACKUP_SERVICE_HOST[config=Debug] = %s\n' "$host"
    printf 'BACKUP_PRODUCT_IDS[config=Debug] = %s\n' "$product"
    printf 'BACKUP_SERVICE_ATTEST_BYPASS[config=Debug] = %s\n' "$bypass"
    printf 'BACKUP_SERVICE_DEV_SIGNIN[config=Debug] = %s\n' "$signin"
    printf 'BACKUP_SERVICE_DEV_USER[config=Debug] = %s\n' "$user"
    printf '// Simulator builds are signed to run locally, so the Keychain (the session, the backup key)\n'
    printf '// works there; an unsigned app gets errSecMissingEntitlement (-34018) and cannot sign in.\n'
    printf 'CODE_SIGNING_ALLOWED[config=Debug][sdk=iphonesimulator*] = YES\n'
    printf '%s\n' "$END_MARK"
  } >>"$LOCAL_XCCONFIG"
  say "wrote the dev-cloud lines in Config/Local.xcconfig (host $host, dev user $user; secrets not shown)"
}

# MARK: The deployed dev Worker

deploy_settings() {
  local key state
  echo "The deployed dev Worker (top level of Backend/backup-worker/wrangler.jsonc) needs:"
  echo
  echo "  Vars, filled in in wrangler.jsonc (top-level \"vars\"; not secrets):"
  for key in "${REQUIRED_VARS[@]}"; do echo "    $key"; done
  echo "    (also there already: ENVIRONMENT=dev, R2_BUCKET_NAME=tactile-texts-backups-dev, PRODUCT_ALLOWANCES, ...)"
  echo "  and the D1 database_id of tactile-backup-dev in d1_databases (a placeholder until then)."
  echo
  echo "  Secrets (scripts/dev-cloud.sh --push-secrets), in .dev.vars:"
  for key in "${PUSHED_SECRETS[@]}" "${OPTIONAL_SECRETS[@]}"; do
    state="missing"
    [[ -n "$(dotenv_get "$DEV_VARS" "$key")" ]] && state="set in .dev.vars"
    case " ${OPTIONAL_SECRETS[*]} " in *" $key "*) state="$state, optional";; esac
    printf '    %-30s %s\n' "$key" "$state"
  done
  echo
  echo "  Never on env.production: the production Worker refuses to serve if APP_ATTEST_BYPASS_SECRET,"
  echo "  DEV_TEST_SIGNIN_SECRET or DEV_TEST_ENTITLEMENT exists there at all."
}

push_secrets() {
  local dry_run="$1" key value names=() missing=()
  [[ -f "$DEV_VARS" ]] || die "no Backend/backup-worker/.dev.vars; run scripts/dev-cloud.sh --setup-only first"
  for key in "${PUSHED_SECRETS[@]}"; do
    if [[ -n "$(dotenv_get "$DEV_VARS" "$key")" ]]; then names+=("$key"); else missing+=("$key"); fi
  done
  ((${#missing[@]} == 0)) || die "missing in .dev.vars: ${missing[*]} (run scripts/dev-cloud.sh --setup-only and fill in R2)"
  local siwa_id siwa_key
  siwa_id="$(dotenv_get "$DEV_VARS" APPLE_SIWA_KEY_ID)"
  siwa_key="$(dotenv_get "$DEV_VARS" APPLE_SIWA_PRIVATE_KEY)"
  if [[ -n "$siwa_id" && -n "$siwa_key" ]]; then
    names+=(APPLE_SIWA_KEY_ID APPLE_SIWA_PRIVATE_KEY)
  elif [[ -n "$siwa_id$siwa_key" ]]; then
    die "APPLE_SIWA_KEY_ID and APPLE_SIWA_PRIVATE_KEY must be set together"
  fi
  if [[ "$dry_run" == 1 ]]; then
    say "dry run: would set these secrets on the top-level (dev) Worker of wrangler.jsonc, values from .dev.vars:"
    for key in "${names[@]}"; do echo "    $key"; done
    return 0
  fi
  cd "$WORKER"
  [[ -d node_modules ]] || npm ci
  for key in "${names[@]}"; do
    value="$(dotenv_get "$DEV_VARS" "$key")"
    # The value reaches wrangler on standard input only. No --env: the top level is `dev`.
    printf '%s' "$value" | npx wrangler secret put "$key" >/dev/null
    say "set $key on the dev Worker"
  done
  value=""
}

# MARK: Main

MODE=local
HOST=""
PORT="$DEFAULT_PORT"
DEV_USER="$DEFAULT_USER"
DRY_RUN=0
while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --setup-only) MODE=setup ;;
    --host) [[ $# -ge 2 ]] || die "--host needs a host"; MODE=remote; HOST="$2"; shift ;;
    --remove) MODE=remove ;;
    --e2e-test) MODE=e2e ;;
    --delete-dev-user) [[ $# -ge 2 ]] || die "--delete-dev-user needs a name"; MODE=delete-user; DEV_USER="$2"; shift ;;
    --deploy-settings) MODE=deploy-settings ;;
    --push-secrets) MODE=push ;;
    --dry-run) DRY_RUN=1 ;;
    --user) [[ $# -ge 2 ]] || die "--user needs a name"; DEV_USER="$2"; shift ;;
    --port) [[ $# -ge 2 ]] || die "--port needs a number"; PORT="$2"; shift ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
  shift
done

[[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || die "--port must be 1 to 65535"
# The app normalizes the name the same way (DevTestUser.normalized); keep it simple here.
[[ "$DEV_USER" =~ ^[a-z0-9._@-]{1,64}$ ]] || die "--user: 1 to 64 lower-case letters, digits or . _ - @"

case "$MODE" in
  remove)
    remove_block
    say "removed the dev-cloud lines from Config/Local.xcconfig (if there were any); .dev.vars is unchanged"
    exit 0 ;;
  deploy-settings)
    deploy_settings
    exit 0 ;;
  push)
    push_secrets "$DRY_RUN"
    exit 0 ;;
  e2e)
    # The app's own client against the local Worker started by this script (another terminal),
    # two devices as one dev user, a backup and a sync round against the real development bucket.
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || die "nothing listens on 127.0.0.1:$PORT; start scripts/dev-cloud.sh first"
    TEST_RUNNER_TACTILE_BACKUP_SERVICE="127.0.0.1:$PORT" \
    TEST_RUNNER_TACTILE_BACKUP_SERVICE_BYPASS="$(dotenv_get "$DEV_VARS" APP_ATTEST_BYPASS_SECRET)" \
    TEST_RUNNER_TACTILE_BACKUP_SERVICE_DEV_SIGNIN="$(dotenv_get "$DEV_VARS" DEV_TEST_SIGNIN_SECRET)" \
    TEST_RUNNER_TACTILE_BACKUP_SERVICE_DEV_USER="$DEV_USER" \
      exec "$REPO/scripts/test.sh" --skip-packages \
      "-only-testing:TactileTextsTests/BackupCloudServiceEndToEndTests/aNamedDevUserBacksUpAndSyncsTwoDevicesWithNoPurchase()" ;;
  delete-user)
    lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1 || die "nothing listens on 127.0.0.1:$PORT; start scripts/dev-cloud.sh first"
    TEST_RUNNER_TACTILE_BACKUP_SERVICE="127.0.0.1:$PORT" \
    TEST_RUNNER_TACTILE_BACKUP_SERVICE_BYPASS="$(dotenv_get "$DEV_VARS" APP_ATTEST_BYPASS_SECRET)" \
    TEST_RUNNER_TACTILE_BACKUP_SERVICE_DEV_SIGNIN="$(dotenv_get "$DEV_VARS" DEV_TEST_SIGNIN_SECRET)" \
    TEST_RUNNER_TACTILE_BACKUP_SERVICE_DELETE_DEV_USER="$DEV_USER" \
      exec "$REPO/scripts/test.sh" --skip-packages \
      "-only-testing:TactileTextsTests/BackupCloudServiceEndToEndTests/deleteADevUserAndItsObjects()" ;;
  remote)
    HOST="${HOST#https://}"
    HOST="${HOST%/}"
    [[ "$HOST" =~ ^[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || die "--host: a host name such as tactile-backup-dev.<subdomain>.workers.dev, no path"
    case "$HOST" in localhost*|127.*|\[::1\]*) die "--host is for a deployed Worker; run without --host for a local wrangler dev" ;; esac
    prepare_dev_vars
    write_block "$HOST" "$DEV_USER"
    cat <<EOF

Next:
  - The deployed dev Worker must hold the same secrets as .dev.vars: scripts/dev-cloud.sh --push-secrets
    (scripts/dev-cloud.sh --deploy-settings lists what it needs).
  - Check it answers: curl -s https://$HOST/v1/health   (expect {"ok":true,"environment":"dev"})
  - Build a Debug build for your device: TACTILE_CONFIG=Debug scripts/device.sh ["device name"]
    Sign in on Tactile Texts Cloud with either button: it signs in as the dev user "$DEV_USER".
  - This build holds the dev secrets: keep it on your own devices.
EOF
    exit 0 ;;
esac

# Local (and setup-only).
prepare_dev_vars
check_r2 || exit 1
cd "$WORKER"
if [[ ! -d node_modules ]]; then
  say "installing the Worker's dependencies (npm ci)"
  npm ci
fi
say "applying the D1 migrations to the local database"
npm run --silent migrate:local >/dev/null
write_block "127.0.0.1:$PORT" "$DEV_USER"

if [[ "$MODE" == setup ]]; then
  say "set up; start the Worker with: (cd Backend/backup-worker && npx wrangler dev --ip 127.0.0.1 --port $PORT)"
  exit 0
fi

if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  die "something is already listening on port $PORT (another wrangler dev?); stop it or pass --port"
fi

cat <<EOF

The dev backup Worker starts on http://127.0.0.1:$PORT (Ctrl-C stops it). Then:
  1. Build and run the app on a simulator: TACTILE_SIM=<simulator> scripts/build.sh, or Run in Xcode.
  2. Backup > Tactile Texts Cloud: either sign-in button signs in as the dev user "$DEV_USER"
     (the page says "Development sign-in"; change the name there for another account). No purchase
     is needed: the dev Worker counts dev users as subscribed (sandbox folder, 100 MB).
  3. Back up once, or turn Sync on: the page then offers the recovery key. Note it.
  4. A second simulator, same build, same dev user: the same account. It asks for the recovery key
     (iCloud Keychain does not sync between simulators); enter it, then turn Sync on.
  Afterwards: scripts/dev-cloud.sh --remove takes the lines out of Config/Local.xcconfig.

EOF
exec npx wrangler dev --ip 127.0.0.1 --port "$PORT"
