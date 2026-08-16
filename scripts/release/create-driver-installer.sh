#!/bin/bash

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <signed-universal-driver> <version> <output-package>" >&2
  exit 64
fi

driver=$1
version=$2
output=$3
installer_identity=${INSTALLER_SIGN_IDENTITY:?INSTALLER_SIGN_IDENTITY is required}
signing_keychain=${SIGNING_KEYCHAIN:?SIGNING_KEYCHAIN is required}
repository_root=$(cd "$(dirname "$0")/../.." && pwd)
component_plist="$repository_root/scripts/release/driver-components.plist"
temporary_root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
staging=$(mktemp -d "$temporary_root/rilliya-driver-installer.XXXXXX")
trap 'rm -rf "$staging"' EXIT

if [[ ! -d "$driver" ]]; then
  echo "Driver does not exist: $driver" >&2
  exit 66
fi
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "Installer version is not valid: $version" >&2
  exit 65
fi
if [[ -e "$output" ]]; then
  echo "Output already exists: $output" >&2
  exit 73
fi

driver_product_name=RilliyaVADriver
driver_executable="$driver/Contents/MacOS/$driver_product_name"
architectures=$(lipo -archs "$driver_executable")
if [[ "$architectures" != *arm64* || "$architectures" != *x86_64* ]]; then
  echo "Installer requires a Universal driver" >&2
  exit 65
fi
codesign --verify --deep --strict --verbose=2 "$driver"
plutil -lint "$component_plist"

install_directory="$staging/Library/Audio/Plug-Ins/HAL"
mkdir -p "$install_directory" "$(dirname "$output")"
ditto --noextattr --noacl --noqtn \
  "$driver" \
  "$install_directory/$driver_product_name.driver"
codesign --verify --deep --strict --verbose=2 \
  "$install_directory/$driver_product_name.driver"

pkgbuild \
  --root "$staging" \
  --component-plist "$component_plist" \
  --identifier moe.uwucocoa.rilliya.virtual-audio-driver.pkg \
  --version "$version" \
  --install-location / \
  --ownership recommended \
  --sign "$installer_identity" \
  --keychain "$signing_keychain" \
  "$output"

pkgutil --check-signature "$output"
