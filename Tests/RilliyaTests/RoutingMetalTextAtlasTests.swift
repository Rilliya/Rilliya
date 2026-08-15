import Metal
import Testing

@testable import Rilliya

struct RoutingMetalTextAtlasTests {
  @Test @MainActor
  func textAndIconAtlasesHaveAFixedFiveMebibyteNominalBudget() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let atlas = RoutingMetalTextAtlas(device: device)

    #expect(RoutingMetalTextAtlas.nominalTextureMemoryByteCount == 5 * 1_024 * 1_024)
    #expect(atlas.glyphTexture.width == 1_024)
    #expect(atlas.glyphTexture.height == 1_024)
    #expect(atlas.glyphTexture.pixelFormat == .r8Unorm)
    #expect(atlas.colorTexture.width == 1_024)
    #expect(atlas.colorTexture.height == 1_024)
    #expect(atlas.colorTexture.pixelFormat == .rgba8Unorm)
  }

  @Test @MainActor
  func changingMeterValuesCacheGlyphsInsteadOfCompleteStrings() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let atlas = RoutingMetalTextAtlas(device: device)

    for index in 0..<10_000 {
      let signal = RoutingPeakLevelSignal(
        linearPeak: Float(index) / 9_999,
        isClipping: false
      )
      for glyph in RoutingDynamicMonospacedText.glyphs(in: signal.linearDescription) {
        _ = atlas.monospacedText(glyph, size: 16, weight: .semibold)
      }
      for glyph in RoutingDynamicMonospacedText.glyphs(in: signal.decibelsDescription) {
        _ = atlas.monospacedText(glyph, size: 9, weight: .medium)
      }
    }

    #expect(atlas.cachedEntryCount <= 38)
  }
}
