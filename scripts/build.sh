#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

./scripts/generate-project.sh
xcodebuild \
  -project Rilliya.xcodeproj \
  -scheme Rilliya \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath .build/DerivedData \
  -onlyUsePackageVersionsFromResolvedFile \
  build
