import Testing

@testable import Rilliya

struct RoutingChannelCountSelectionTests {
  @Test func commonCountsUsePresetsAndOtherCountsUseCustom() {
    #expect(RoutingChannelCountSelection.choice(for: 1) == .preset(1))
    #expect(RoutingChannelCountSelection.choice(for: 2) == .preset(2))
    #expect(RoutingChannelCountSelection.choice(for: 8) == .preset(8))
    #expect(RoutingChannelCountSelection.choice(for: 3) == .custom)
    #expect(RoutingChannelCountSelection.choice(for: 12) == .custom)
  }

  @Test func customCountsMustBeWholeNumbersInsideTheEditableRange() {
    let range = 1...64

    #expect(RoutingChannelCountSelection.validatedCustomCount(" 12 ", in: range) == 12)
    #expect(RoutingChannelCountSelection.validatedCustomCount("0", in: range) == nil)
    #expect(RoutingChannelCountSelection.validatedCustomCount("65", in: range) == nil)
    #expect(RoutingChannelCountSelection.validatedCustomCount("2.5", in: range) == nil)
    #expect(RoutingChannelCountSelection.validatedCustomCount("two", in: range) == nil)
  }

  @Test func channelLabelsDistinguishMonoFromMultichannelAudio() {
    #expect(RoutingChannelCountSelection.label(for: 1) == "Mono")
    #expect(RoutingChannelCountSelection.label(for: 2) == "2 ch")
    #expect(RoutingChannelCountSelection.label(for: 8) == "8 ch")
  }
}
