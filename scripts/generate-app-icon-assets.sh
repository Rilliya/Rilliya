#!/usr/bin/env bash

set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"

compiled_directory="Sources/Rilliya/Resources/GeneratedAppAssets"
rendered_directory="assets/app-icon/rendered"
checksum_file="assets/app-icon/AppIconAssets.sha256"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/rilliya-app-icon.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT

mkdir -p "$temporary_directory/compiled" "$temporary_directory/rendered"

echo "Generating app icon assets with:"
xcodebuild -version

xcrun actool \
  Sources/Rilliya/Resources/Assets.xcassets \
  Sources/Rilliya/Resources/AppIcon.icon \
  --compile "$temporary_directory/compiled" \
  --platform macosx \
  --minimum-deployment-target 14.2 \
  --app-icon AppIcon \
  --output-partial-info-plist "$temporary_directory/partial-info.plist" \
  --warnings \
  --notices \
  --output-format human-readable-text

for appearance in Light Dark Mono; do
  source_svg="assets/app-icon/RilliyaAppIcon-${appearance}.svg"
  output_png="$temporary_directory/rendered/RilliyaAppIcon-${appearance}.png"
  sips -s format png "$source_svg" --out "$output_png" >/dev/null
done

xcrun assetutil --validate-file "$temporary_directory/compiled/Assets.car"

mkdir -p "$compiled_directory" "$rendered_directory"
install -m 0644 "$temporary_directory/compiled/Assets.car" "$compiled_directory/Assets.car"
install -m 0644 "$temporary_directory/compiled/AppIcon.icns" "$compiled_directory/AppIcon.icns"
for appearance in Light Dark Mono; do
  install -m 0644 \
    "$temporary_directory/rendered/RilliyaAppIcon-${appearance}.png" \
    "$rendered_directory/RilliyaAppIcon-${appearance}.png"
done

tracked_assets=(
  Sources/Rilliya/Resources/AppIcon.icon/icon.json
  Sources/Rilliya/Resources/AppIcon.icon/Assets/RilliyaMark.svg
  Sources/Rilliya/Resources/AppIcon.icon/Assets/RilliyaMark-Dark.svg
  Sources/Rilliya/Resources/AppIcon.icon/Assets/RilliyaMark-Mono.svg
  Sources/Rilliya/Resources/Assets.xcassets/Contents.json
  Sources/Rilliya/Resources/Assets.xcassets/RilliyaStatusIcon.imageset/Contents.json
  Sources/Rilliya/Resources/Assets.xcassets/RilliyaStatusIcon.imageset/RilliyaStatusIcon.svg
  assets/app-icon/RilliyaAppIcon-Light.svg
  assets/app-icon/RilliyaAppIcon-Dark.svg
  assets/app-icon/RilliyaAppIcon-Mono.svg
  Sources/Rilliya/Resources/GeneratedAppAssets/Assets.car
  Sources/Rilliya/Resources/GeneratedAppAssets/AppIcon.icns
  assets/app-icon/rendered/RilliyaAppIcon-Light.png
  assets/app-icon/rendered/RilliyaAppIcon-Dark.png
  assets/app-icon/rendered/RilliyaAppIcon-Mono.png
)

shasum -a 256 "${tracked_assets[@]}" > "$checksum_file"
echo "Generated app icon assets and $checksum_file"
