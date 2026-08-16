#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

driver_bundle="${1:-.build/DerivedData/Build/Products/Debug/RilliyaVirtualAudioDriver.driver}"
driver_binary="$driver_bundle/Contents/MacOS/RilliyaVirtualAudioDriver"
driver_info="$driver_bundle/Contents/Info.plist"
bundle_test_binary=".build/DriverCoreTests/DriverBundleTests"
factory_identifier="961AA42D-4018-4A54-81A5-AF308770CF08"
audio_server_plugin_type="443ABAB8-E7B3-491A-B985-BEB9187030DB"

[ -f "$driver_binary" ]
[ -f "$driver_info" ]
plutil -lint "$driver_info"

factory_symbol="$(/usr/libexec/PlistBuddy -c "Print :CFPlugInFactories:$factory_identifier" \
  "$driver_info")"
registered_factory="$(/usr/libexec/PlistBuddy \
  -c "Print :CFPlugInTypes:$audio_server_plugin_type:0" \
  "$driver_info")"

[ "$factory_symbol" = "RilliyaVirtualAudioDriverFactory" ]
[ "$registered_factory" = "$factory_identifier" ]
nm -gU "$driver_binary" | grep -q '_RilliyaVirtualAudioDriverFactory$'

unexpected_dependencies="$(otool -L "$driver_binary" | tail -n +2 | awk '{print $1}' | \
  grep -Ev '^(/System/Library/|/usr/lib/)' || true)"
[ -z "$unexpected_dependencies" ]

mkdir -p "$(dirname "$bundle_test_binary")"
xcrun clang++ \
  -std=c++20 \
  -O2 \
  -Wall \
  -Wextra \
  -Wconversion \
  -Werror \
  Driver/Tests/DriverBundleTests.cpp \
  -framework CoreAudio \
  -framework CoreFoundation \
  -o "$bundle_test_binary"

"$bundle_test_binary" "$driver_bundle"
