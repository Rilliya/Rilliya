#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

./scripts/check-repository-hygiene.sh

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

for script in scripts/release/*.sh; do
  bash -n "$script"
done

./scripts/check-driver.sh
./scripts/test.sh
./scripts/build.sh
