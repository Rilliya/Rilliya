#pragma once

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

namespace rilliya::audio_driver {

constexpr AudioObjectPropertySelector endpointCatalogProperty = 'rlct';

} // namespace rilliya::audio_driver

extern "C" void* RilliyaVirtualAudioDriverFactory(CFAllocatorRef allocator,
                                                  CFUUIDRef requestedTypeUUID);
