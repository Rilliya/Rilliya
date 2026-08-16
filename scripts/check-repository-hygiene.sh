#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

tracked_paths="$(
  git ls-files | while IFS= read -r path; do
    if [ -e "$path" ]; then
      printf '%s\n' "$path"
    fi
  done
)"

forbidden_paths="$(
  printf '%s\n' "$tracked_paths" | grep -E -i \
    '(^|/)(plans?|design|audits?|benchmarks?|performance|profiles?)(/|$)|(^|/)(PERFORMANCE|AUDIT)([-_][^/]*)?\.md$|\.(cer|key|keychain-db|mobileprovision|p12|pem|pfx|provisionprofile|profdata|profraw|trace|xcresult)$|(^|/)\.rilliya-signing\.local$' \
    || true
)"

if [ -n "$forbidden_paths" ]; then
  echo "Internal or sensitive files must not be tracked:" >&2
  printf '%s\n' "$forbidden_paths" >&2
  exit 1
fi

personal_email_pattern='i@'"uwucocoa.moe"

matches="$(git grep -I -n -F "$personal_email_pattern" -- . ':!scripts/check-repository-hygiene.sh' || true)"
if [ -n "$matches" ]; then
  echo "A personal signing identity is present in tracked content:" >&2
  printf '%s\n' "$matches" >&2
  exit 1
fi
