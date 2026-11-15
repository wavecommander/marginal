#!/usr/bin/env bash
# Generates Fixtures/out/{small,links,link-forms,large,no-outline}.pdf and the files converted at
# import ({small,protected}.epub, small.cbz, small.md, small.docx, small.pptx) if any is missing
# or older than the generator.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="$REPO/Fixtures/make-fixtures.swift"
OUT="$REPO/Fixtures/out"
stale=0
for f in small.pdf links.pdf link-forms.pdf large.pdf no-outline.pdf \
         small.epub protected.epub small.cbz small.md small.docx small.pptx; do
  if [[ ! -s "$OUT/$f" || "$GEN" -nt "$OUT/$f" ]]; then stale=1; fi
done
if [[ $stale -eq 0 ]]; then exit 0; fi
mkdir -p "$OUT" "$REPO/build"
BIN="$REPO/build/make-fixtures"
swiftc -O -o "$BIN" "$GEN"
"$BIN" "$OUT"
