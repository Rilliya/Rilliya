#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

environment_development_team="${DEVELOPMENT_TEAM:-}"
environment_code_sign_identity="${CODE_SIGN_IDENTITY:-}"
local_signing_config="${RILLIYA_LOCAL_SIGNING_CONFIG:-.rilliya-signing.local}"

if [ -f "$local_signing_config" ]; then
  # shellcheck source=/dev/null
  . "$local_signing_config"
fi

if [ -n "$environment_development_team" ]; then
  DEVELOPMENT_TEAM="$environment_development_team"
fi
if [ -n "$environment_code_sign_identity" ]; then
  CODE_SIGN_IDENTITY="$environment_code_sign_identity"
fi

export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
export CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"

xcodegen generate
