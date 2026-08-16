#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"

compiled_directory="Sources/Rilliya/Resources/GeneratedAppAssets"
checksum_file="assets/app-icon/AppIconAssets.sha256"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/rilliya-app-icon-check.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT

shasum -a 256 --check "$checksum_file"
iconutil -c iconset \
  -o "$temporary_directory/AppIcon.iconset" \
  "$compiled_directory/AppIcon.icns"

host_major_version="$(sw_vers -productVersion | cut -d . -f 1)"
if ((host_major_version >= 26)); then
  xcrun assetutil --validate-file "$compiled_directory/Assets.car"

  asset_information="$temporary_directory/asset-information.json"
  xcrun assetutil --info "$compiled_directory/Assets.car" > "$asset_information"
  for required_value in \
    '"Appearance" : "NSAppearanceNameAqua"' \
    '"Appearance" : "NSAppearanceNameDarkAqua"' \
    '"Appearance" : "ISAppearanceTintable"' \
    '"Name" : "RilliyaStatusIcon"'; do
    if ! grep -Fq "$required_value" "$asset_information"; then
      echo "Compiled app assets are missing: $required_value" >&2
      exit 1
    fi
  done
else
  echo "Skipping modern Assets.car inspection on macOS $host_major_version"
fi

for appearance in Light Dark Mono; do
  png="assets/app-icon/rendered/RilliyaAppIcon-${appearance}.png"
  width="$(sips -g pixelWidth "$png" | awk '/pixelWidth:/ { print $2 }')"
  height="$(sips -g pixelHeight "$png" | awk '/pixelHeight:/ { print $2 }')"
  if [[ "$width" != 1024 || "$height" != 1024 ]]; then
    echo "$png must be exactly 1024 by 1024 pixels" >&2
    exit 1
  fi
done
