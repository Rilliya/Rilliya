import Testing

@testable import Rilliya

struct RoutingPaletteSearchTests {
  @Test
  func emptyQueryShowsEveryNode() {
    #expect(
      RoutingPaletteSearch.matches(
        query: "  ",
        title: "Signal Generator",
        description: "Create tones and colored noise"
      )
    )
  }

  @Test
  func searchesNamesAndDescriptionsCaseInsensitively() {
    #expect(
      RoutingPaletteSearch.matches(
        query: "MIXER",
        title: "Audio Mixer",
        description: "Mix routed channel levels"
      )
    )
    #expect(
      RoutingPaletteSearch.matches(
        query: "colored noise",
        title: "Signal Generator",
        description: "Create tones and colored noise"
      )
    )
  }

  @Test
  func supportsOrderedFuzzyAbbreviations() {
    #expect(
      RoutingPaletteSearch.matches(
        query: "sgnl gen",
        title: "Signal Generator",
        description: "Create tones and colored noise"
      )
    )
    #expect(
      !RoutingPaletteSearch.matches(
        query: "mixer",
        title: "Peak Level",
        description: "Measure the strongest sample"
      )
    )
  }
}
