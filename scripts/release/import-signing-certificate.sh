#!/bin/bash

set -euo pipefail

certificate="$(mktemp "$RUNNER_TEMP/rilliya-certificate.XXXXXX")"
keychain="$RUNNER_TEMP/rilliya-signing.keychain-db"
trap 'rm -f "$certificate"' EXIT

printf '%s' "$CERTIFICATE_BASE64" | base64 --decode > "$certificate"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$keychain"
security import "$certificate" \
  -P "$CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign \
  -t cert \
  -f pkcs12 \
  -k "$keychain"
security set-key-partition-list \
  -S apple-tool:,apple: \
  -s \
  -k "$KEYCHAIN_PASSWORD" \
  "$keychain"
security list-keychains -d user -s "$keychain"

identity="$(
  security find-identity -v -p codesigning "$keychain" \
    | sed -n "s/.*\"\(Developer ID Application:.*($TEAM_ID)\)\".*/\1/p" \
    | head -n 1
)"
if [[ -z "$identity" ]]; then
  echo "No Developer ID Application identity matches TEAM_ID" >&2
  exit 1
fi

{
  printf 'CODE_SIGN_IDENTITY=%s\n' "$identity"
  printf 'DEVELOPMENT_TEAM=%s\n' "$TEAM_ID"
  printf 'SIGNING_KEYCHAIN=%s\n' "$keychain"
} >> "$GITHUB_ENV"
