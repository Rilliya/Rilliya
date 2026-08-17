#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

./scripts/check-repository-hygiene.sh
./scripts/check-configuration-edits.sh

xcrun swift-format lint \
  --configuration .swift-format \
  --strict \
  --parallel \
  --recursive \
  Sources \
  Tests

plutil -lint Sources/Rilliya/Resources/Info.plist
plutil -lint Sources/Rilliya/Resources/Rilliya.entitlements
plutil -lint scripts/release/driver-components.plist

./scripts/check-app-icon-assets.sh
./scripts/check-disk-image-assets.sh
bash -n \
  scripts/check-app-icon-assets.sh \
  scripts/check-configuration-edits.sh \
  scripts/check-disk-image-assets.sh \
  scripts/generate-app-icon-assets.sh

for script in scripts/release/*.sh; do
  bash -n "$script"
done

./scripts/test.sh
./scripts/build.sh
