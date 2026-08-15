import Foundation
import Testing

@testable import Rilliya

struct RoutingDynamicMonospacedTextTests {
  @Test
  func changingMeterValuesUseABoundedGlyphSet() {
    var glyphs = Set<String>()

    for index in 0..<10_000 {
      let signal = RoutingPeakLevelSignal(
        linearPeak: Float(index) / 9_999,
        isClipping: false
      )
      glyphs.formUnion(RoutingDynamicMonospacedText.glyphs(in: signal.linearDescription))
      glyphs.formUnion(RoutingDynamicMonospacedText.glyphs(in: signal.decibelsDescription))
    }

    #expect(glyphs.isSubset(of: Set("0123456789.-−∞ dBFS".map(String.init))))
    #expect(glyphs.count <= 19)
  }
}
