import Metal
import Testing

@testable import Rilliya

struct RoutingMetalTextAtlasTests {
  @Test @MainActor
  func textAndIconAtlasesHaveAFixedTwentyMebibyteNominalBudget() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let atlas = RoutingMetalTextAtlas(device: device)

    #expect(RoutingMetalTextAtlas.nominalTextureMemoryByteCount == 20 * 1_024 * 1_024)
    #expect(atlas.glyphTexture.width == 4_096)
    #expect(atlas.glyphTexture.height == 4_096)
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

  @Test @MainActor
  func systemSymbolProducesANonemptyGlyphMask() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let atlas = RoutingMetalTextAtlas(device: device)
    let entry = try #require(
      atlas.symbol("waveform.badge.mic", pointSize: 16, weight: .semibold)
    )

    let textureWidth = atlas.glyphTexture.width
    let width = Int(round(entry.textureSize.x * Float(textureWidth)))
    let height = Int(round(entry.textureSize.y * Float(atlas.glyphTexture.height)))
    let originX = Int(round(entry.textureOrigin.x * Float(textureWidth)))
    let originY = Int(round(entry.textureOrigin.y * Float(atlas.glyphTexture.height)))
    var mask = [UInt8](repeating: 0, count: width * height)
    mask.withUnsafeMutableBytes { bytes in
      atlas.glyphTexture.getBytes(
        bytes.baseAddress!,
        bytesPerRow: width,
        from: MTLRegionMake2D(originX, originY, width, height),
        mipmapLevel: 0
      )
    }

    #expect(mask.contains { $0 > 0 })
  }
}
