#!/bin/bash
# Export the public tree from the private repo: every tracked file except personal/, then
# refuse if anything personal is left.
#   tools/make-public.sh <out-dir>
# Patterns to refuse are read from personal/secret-patterns.txt (one fixed string per line;
# kept in the private repo only, since the list itself is personal).
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:?usage: make-public.sh <out-dir>}
PAT=personal/secret-patterns.txt
[ -f "$PAT" ] || { echo "missing $PAT" >&2; exit 1; }
[ -e "$OUT" ] && [ -n "$(ls -A "$OUT" 2>/dev/null | grep -v '^\.git$')" ] && { echo "$OUT is not empty" >&2; exit 1; }
mkdir -p "$OUT"

git ls-files -z | grep -zv '^personal/' | while IFS= read -r -d '' f; do
	mkdir -p "$OUT/$(dirname "$f")"
	cp "$f" "$OUT/$f"
done

hits=$(grep -rnIF -f <(grep -v '^\s*$' "$PAT") "$OUT" --exclude-dir=.git || true)
if [ -n "$hits" ]; then
	echo "REFUSING: personal data in the public tree:" >&2
	echo "$hits" >&2
	exit 1
fi
# no private keys, ever
if grep -rlI -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$OUT" --exclude-dir=.git; then echo "REFUSING: private key material" >&2; exit 1; fi
echo "public tree OK: $(find "$OUT" -type f -not -path '*/.git/*' | wc -l) files in $OUT"
