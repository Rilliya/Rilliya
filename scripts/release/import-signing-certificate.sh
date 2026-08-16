#!/bin/bash

set -euo pipefail

application_certificate="$(mktemp "$RUNNER_TEMP/rilliya-application-certificate.XXXXXX")"
installer_certificate="$(mktemp "$RUNNER_TEMP/rilliya-installer-certificate.XXXXXX")"
keychain="$RUNNER_TEMP/rilliya-signing.keychain-db"
trap 'rm -f "$application_certificate" "$installer_certificate"' EXIT

printf '%s' "$CERTIFICATE_BASE64" | base64 --decode > "$application_certificate"
printf '%s' "$INSTALLER_CERTIFICATE_BASE64" | base64 --decode > "$installer_certificate"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$keychain"
security import "$application_certificate" \
  -P "$CERTIFICATE_PASSWORD" \
  -T /usr/bin/codesign \
  -t cert \
  -f pkcs12 \
  -k "$keychain"
security import "$installer_certificate" \
  -P "$INSTALLER_CERTIFICATE_PASSWORD" \
  -T /usr/bin/pkgbuild \
  -T /usr/bin/productbuild \
  -T /usr/bin/productsign \
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

installer_identity="$(
  security find-identity -v "$keychain" \
    | sed -n "s/.*\"\(Developer ID Installer:.*($TEAM_ID)\)\".*/\1/p" \
    | head -n 1
)"
if [[ -z "$installer_identity" ]]; then
  echo "No Developer ID Installer identity matches TEAM_ID" >&2
  exit 1
fi

{
  printf 'CODE_SIGN_IDENTITY=%s\n' "$identity"
  printf 'DEVELOPMENT_TEAM=%s\n' "$TEAM_ID"
  printf 'INSTALLER_SIGN_IDENTITY=%s\n' "$installer_identity"
  printf 'SIGNING_KEYCHAIN=%s\n' "$keychain"
} >> "$GITHUB_ENV"
