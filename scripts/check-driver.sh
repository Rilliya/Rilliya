#!/bin/sh
set -eu

cd "$(dirname "$0")/.."

build_directory=".build/DriverCoreTests"
ring_test_binary="$build_directory/RealtimeAudioRingTests"
registry_test_binary="$build_directory/EndpointRegistryTests"
catalog_test_binary="$build_directory/DriverCatalogCodecTests"
ring_tsan_binary="$build_directory/RealtimeAudioRingTests-TSan"
runtime_test_binary="$build_directory/DriverRuntimeTests"
interface_test_binary="$build_directory/AudioServerPlugInDriverTests"
driver_binary="$build_directory/RilliyaVirtualAudioDriver"

mkdir -p "$build_directory"

xcrun clang-format --dry-run --Werror \
  Driver/Sources/RealtimeAudioRing.hpp \
  Driver/Sources/RealtimeAudioRing.cpp \
  Driver/Sources/EndpointRegistry.hpp \
  Driver/Sources/EndpointRegistry.cpp \
  Driver/Sources/DriverCatalogCodec.hpp \
  Driver/Sources/DriverCatalogCodec.cpp \
  Driver/Sources/DriverRuntime.hpp \
  Driver/Sources/DriverRuntime.cpp \
  Driver/Sources/AudioServerPlugInDriver.hpp \
  Driver/Sources/AudioServerPlugInDriver.cpp \
  Driver/Tests/RealtimeAudioRingTests.cpp \
  Driver/Tests/EndpointRegistryTests.cpp \
  Driver/Tests/DriverCatalogCodecTests.cpp \
  Driver/Tests/DriverRuntimeTests.cpp \
  Driver/Tests/AudioServerPlugInDriverTests.cpp \
  Driver/Tests/DriverBundleTests.cpp

xcrun clang++ \
  -std=c++20 \
  -O1 \
  -g \
  -Wall \
  -Wextra \
  -Wconversion \
  -Werror \
  -fsanitize=address,undefined \
  -fno-omit-frame-pointer \
  -I Driver/Sources \
  Driver/Sources/RealtimeAudioRing.cpp \
  Driver/Tests/RealtimeAudioRingTests.cpp \
  -o "$ring_test_binary"

ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 "$ring_test_binary"

xcrun clang++ \
  -std=c++20 \
  -O1 \
  -g \
  -Wall \
  -Wextra \
  -Wconversion \
  -Werror \
  -fsanitize=thread \
  -fno-omit-frame-pointer \
  -I Driver/Sources \
  Driver/Sources/RealtimeAudioRing.cpp \
  Driver/Tests/RealtimeAudioRingTests.cpp \
  -o "$ring_tsan_binary"

"$ring_tsan_binary"

xcrun clang++ \
  -std=c++20 \
  -O1 \
  -g \
  -Wall \
  -Wextra \
  -Wconversion \
  -Werror \
  -fsanitize=address,undefined \
  -fno-omit-frame-pointer \
  -I Driver/Sources \
  Driver/Sources/EndpointRegistry.cpp \
  Driver/Tests/EndpointRegistryTests.cpp \
  -o "$registry_test_binary"

ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 "$registry_test_binary"

xcrun clang++ \
  -std=c++20 \
  -O1 \
  -g \
  -Wall \
  -Wextra \
  -Wconversion \
  -Werror \
  -fsanitize=address,undefined \
  -fno-omit-frame-pointer \
  -I Driver/Sources \
  Driver/Sources/EndpointRegistry.cpp \
  Driver/Sources/DriverCatalogCodec.cpp \
  Driver/Tests/DriverCatalogCodecTests.cpp \
  -framework CoreFoundation \
  -o "$catalog_test_binary"

ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 "$catalog_test_binary"

xcrun clang++ \
  -std=c++20 \
  -O1 \
  -g \
  -Wall \
  -Wextra \
  -Wconversion \
  -Werror \
  -fsanitize=address,undefined \
  -fno-omit-frame-pointer \
  -I Driver/Sources \
  Driver/Sources/RealtimeAudioRing.cpp \
  Driver/Sources/EndpointRegistry.cpp \
  Driver/Sources/DriverRuntime.cpp \
  Driver/Tests/DriverRuntimeTests.cpp \
  -o "$runtime_test_binary"

ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 "$runtime_test_binary"

xcrun clang++ \
  -std=c++20 \
  -O1 \
  -g \
  -Wall \
  -Wextra \
  -Wconversion \
  -Werror \
  -fsanitize=address,undefined \
  -fno-omit-frame-pointer \
  -I Driver/Sources \
  Driver/Sources/RealtimeAudioRing.cpp \
  Driver/Sources/EndpointRegistry.cpp \
  Driver/Sources/DriverCatalogCodec.cpp \
  Driver/Sources/DriverRuntime.cpp \
  Driver/Sources/AudioServerPlugInDriver.cpp \
  Driver/Tests/AudioServerPlugInDriverTests.cpp \
  -framework CoreAudio \
  -framework CoreFoundation \
  -o "$interface_test_binary"

ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 "$interface_test_binary"

xcrun clang++ \
  -std=c++20 \
  -O2 \
  -Wall \
  -Wextra \
  -Wconversion \
  -Werror \
  -I Driver/Sources \
  Driver/Sources/RealtimeAudioRing.cpp \
  Driver/Sources/EndpointRegistry.cpp \
  Driver/Sources/DriverCatalogCodec.cpp \
  Driver/Sources/DriverRuntime.cpp \
  Driver/Sources/AudioServerPlugInDriver.cpp \
  -framework CoreAudio \
  -framework CoreFoundation \
  -bundle \
  -o "$driver_binary"

nm -gU "$driver_binary" | grep -q '_RilliyaVirtualAudioDriverFactory$'
plutil -lint Driver/Resources/Info.plist

factory_identifier="961AA42D-4018-4A54-81A5-AF308770CF08"
audio_server_plugin_type="443ABAB8-E7B3-491A-B985-BEB9187030DB"
factory_symbol="$(/usr/libexec/PlistBuddy -c "Print :CFPlugInFactories:$factory_identifier" \
  Driver/Resources/Info.plist)"
registered_factory="$(/usr/libexec/PlistBuddy \
  -c "Print :CFPlugInTypes:$audio_server_plugin_type:0" \
  Driver/Resources/Info.plist)"

[ "$factory_symbol" = "RilliyaVirtualAudioDriverFactory" ]
[ "$registered_factory" = "$factory_identifier" ]
