#!/bin/bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <application> <output-dmg>" >&2
  exit 64
fi

application=$1
output=$2
temporary_root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
staging="$(mktemp -d "$temporary_root/rilliya-dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

if [[ ! -d "$application" ]]; then
  echo "Application does not exist: $application" >&2
  exit 66
fi

mkdir -p "$(dirname "$output")"
ditto "$application" "$staging/Rilliya.app"
ln -s /Applications "$staging/Applications"

if [[ -e "$output" ]]; then
  rm "$output"
fi

diskutil image create from \
  --volumeName Rilliya \
  --format UDZO \
  "$staging" \
  "$output"
