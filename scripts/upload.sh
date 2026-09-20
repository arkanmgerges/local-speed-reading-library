#!/usr/bin/env bash
# Uploads the built library to Cloudflare R2 through the S3-compatible API.
#
#   books/**  -> immutable, never overwritten (HEAD first; an existing object is left alone)
#   catalog/** -> short cache, overwritten on every run
#
# Requires: aws CLI v2, and the environment variables
#   R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET
# Run `lsr validate` first; run `lsr publish-check` afterwards.
set -euo pipefail

: "${R2_ACCOUNT_ID:?}" "${R2_ACCESS_KEY_ID:?}" "${R2_SECRET_ACCESS_KEY:?}" "${R2_BUCKET:?}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" AWS_DEFAULT_REGION=auto AWS_EC2_METADATA_DISABLED=true

s3() { aws --endpoint-url "$ENDPOINT" s3api "$@"; }

uploaded=0 skipped=0
while IFS= read -r -d '' file; do
  key="${file#"$ROOT/build/"}"
  if s3 head-object --bucket "$R2_BUCKET" --key "$key" >/dev/null 2>&1; then
    skipped=$((skipped + 1))
    continue
  fi
  s3 put-object --bucket "$R2_BUCKET" --key "$key" --body "$file" \
    --content-type "application/gzip" \
    --cache-control "public, max-age=31536000, immutable" >/dev/null
  echo "uploaded $key"
  uploaded=$((uploaded + 1))
done < <(find "$ROOT/build/books" -type f -name 'book.json.gz' -print0 | sort -z)
echo "books: $uploaded uploaded, $skipped already present"

for file in "$ROOT"/catalog/languages/*.json; do
  key="catalog/languages/$(basename "$file")"
  s3 put-object --bucket "$R2_BUCKET" --key "$key" --body "$file" \
    --content-type "application/json; charset=utf-8" \
    --cache-control "public, max-age=900, must-revalidate" >/dev/null
  echo "published $key"
done
s3 put-object --bucket "$R2_BUCKET" --key "catalog/catalog.json" --body "$ROOT/catalog/catalog.json" \
  --content-type "application/json; charset=utf-8" \
  --cache-control "public, max-age=300, must-revalidate" >/dev/null
echo "published catalog/catalog.json"
