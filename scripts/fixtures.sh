#!/usr/bin/env bash
# Generates Fixtures/out/{small,large,no-outline}.pdf if missing or older than the generator.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="$REPO/Fixtures/make-fixtures.swift"
OUT="$REPO/Fixtures/out"
stale=0
for f in small large no-outline; do
  if [[ ! -s "$OUT/$f.pdf" || "$GEN" -nt "$OUT/$f.pdf" ]]; then stale=1; fi
done
if [[ $stale -eq 0 ]]; then exit 0; fi
mkdir -p "$OUT" "$REPO/build"
BIN="$REPO/build/make-fixtures"
swiftc -O -o "$BIN" "$GEN"
"$BIN" "$OUT"
