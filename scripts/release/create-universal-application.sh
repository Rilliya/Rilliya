#!/bin/bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <arm64-application> <intel-application> <output-application>" >&2
  exit 64
fi

arm64_application=$1
intel_application=$2
output_application=$3
executable_path=Contents/MacOS/Rilliya

for application in "$arm64_application" "$intel_application"; do
  if [[ ! -d "$application" ]]; then
    echo "Application does not exist: $application" >&2
    exit 66
  fi
done

if [[ -e "$output_application" ]]; then
  echo "Output already exists: $output_application" >&2
  exit 73
fi

mach_o_paths() {
  local application=$1
  find "$application" -type f -print0 | while IFS= read -r -d '' file_path; do
    if file -b "$file_path" | grep -q 'Mach-O'; then
      printf '%s\n' "${file_path#"$application"/}"
    fi
  done | LC_ALL=C sort
}

arm64_mach_o_paths="$(mach_o_paths "$arm64_application")"
intel_mach_o_paths="$(mach_o_paths "$intel_application")"

if [[ "$arm64_mach_o_paths" != "$executable_path" || "$intel_mach_o_paths" != "$executable_path" ]]; then
  echo "Unexpected Mach-O layout; update Universal assembly before shipping new executables" >&2
  exit 65
fi

if [[ "$(lipo -archs "$arm64_application/$executable_path")" != "arm64" ]]; then
  echo "Apple Silicon application is not arm64-only" >&2
  exit 65
fi

if [[ "$(lipo -archs "$intel_application/$executable_path")" != "x86_64" ]]; then
  echo "Intel application is not x86_64-only" >&2
  exit 65
fi

if ! diff -qr \
  -x Rilliya \
  -x _CodeSignature \
  "$arm64_application" \
  "$intel_application" >/dev/null; then
  echo "Architecture-specific application resources differ" >&2
  exit 65
fi

ditto "$arm64_application" "$output_application"
rm -rf "$output_application/Contents/_CodeSignature"
lipo -create \
  "$arm64_application/$executable_path" \
  "$intel_application/$executable_path" \
  -output "$output_application/$executable_path"
