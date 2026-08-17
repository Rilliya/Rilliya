#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

# A view that answers an edit by rebuilding a node configuration drops every field it does not
# name. That is how editing a port silently removed a network node's shared key and returned the
# stream to plaintext. Editing a copy cannot lose a field, so views must not call these
# initializers at all.
offenders=""
for file in $(grep -rl ': View {' Sources --include='*.swift'); do
  matches="$(grep -n 'Routing[A-Za-z]*Configuration(' "$file" || true)"
  if [ -n "$matches" ]; then
    offenders="$offenders$(printf '%s\n' "$matches" | sed "s|^|$file:|")
"
  fi
done

if [ -n "$offenders" ]; then
  echo "A view must edit a copy of a node configuration, not rebuild one:" >&2
  printf '%s' "$offenders" >&2
  echo "Replace the initializer call with 'var updated = configuration; updated.field = value'." >&2
  exit 1
fi
