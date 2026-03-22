#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TARGET_NAME="${DOCC_TARGET:-SequentialExecutor}"
OUTPUT_DIR="${DOCC_OUTPUT_DIR:-$ROOT_DIR/docs}"
HOSTING_BASE_PATH="${DOCC_HOSTING_BASE_PATH:-$(basename "$ROOT_DIR")}"

HOSTING_BASE_PATH="${HOSTING_BASE_PATH#/}"
HOSTING_BASE_PATH="${HOSTING_BASE_PATH%/}"

rm -rf "$OUTPUT_DIR"

docc_args=(
  --target "$TARGET_NAME"
  --transform-for-static-hosting
  --output-path "$OUTPUT_DIR"
)

if [[ -n "$HOSTING_BASE_PATH" ]]; then
  docc_args+=(--hosting-base-path "$HOSTING_BASE_PATH")
fi

swift package \
  --allow-writing-to-directory "$OUTPUT_DIR" \
  generate-documentation \
  "${docc_args[@]}"

touch "$OUTPUT_DIR/.nojekyll"

if [[ -n "$HOSTING_BASE_PATH" ]]; then
  printf 'Generated DocC to %s with hosting base path /%s/.\n' "$OUTPUT_DIR" "$HOSTING_BASE_PATH"
else
  printf 'Generated DocC to %s with root hosting path /.\n' "$OUTPUT_DIR"
fi
