import Testing

@testable import Rilliya

@Suite("Routing port types")
struct RoutingPortTypeTests {
  @Test
  func audioPortLabelsStayCompactAndDoNotInventSpeakerRoles() {
    let bus = RoutingGraphPortValue(
      direction: .output,
      channel: .all,
      ordinal: 0,
      total: 1
    )
    let channels = (0..<2).map {
      RoutingGraphPortValue(
        direction: .output,
        channel: .channel($0),
        ordinal: $0,
        total: 2
      )
    }

    #expect(bus.shortLabel == "All")
    #expect(channels.map(\.shortLabel) == ["Ch 1", "Ch 2"])
  }

  @Test
  func semanticPortIdentityDoesNotDependOnPresentationOrType() {
    let first = RoutingGraphPortValue(
      direction: .output,
      id: "analysis.primary",
      name: "Emotion",
      signalType: .label(domain: "emotion.v1"),
      connectionPolicy: .fanOut,
      ordinal: 0,
      total: 2
    )
    let updated = RoutingGraphPortValue(
      direction: .output,
      id: "analysis.primary",
      name: "Detected mood",
      signalType: .structure(schema: "classification.v2"),
      connectionPolicy: .fanOut,
      ordinal: 4,
      total: 8
    )

    #expect(first.id == updated.id)
  }

  @Test
  func audioChannelsCanBeRemappedBetweenDifferentLaneNumbers() {
    let source = audioPort(direction: .output, channel: .channel(0))
    let target = audioPort(direction: .input, channel: .channel(47))

    #expect(
      RoutingPortCompatibility.incompatibilityReason(source: source, target: target) == nil
    )
  }

  @Test
  func anAggregateBusMustBeSeparatedBeforeConnectingToOneLane() {
    let source = audioPort(direction: .output, channel: .all)
    let target = audioPort(direction: .input, channel: .channel(0))

    #expect(
      RoutingPortCompatibility.incompatibilityReason(source: source, target: target)
        == "Separate the source channels before connecting"
    )
  }

  @Test
  func numericTypesDoNotConvertImplicitly() {
    let source = valuePort(direction: .output, type: .integer)
    let target = valuePort(direction: .input, type: .floatingPoint)

    #expect(
      RoutingPortCompatibility.incompatibilityReason(source: source, target: target)
        == "Connect ports carrying the same data type"
    )
  }

  @Test
  func aConcreteLabelDomainCanFeedAWildcardLabelInput() {
    let source = valuePort(direction: .output, type: .label(domain: "emotion.v1"))
    let target = valuePort(direction: .input, type: .label(domain: nil))

    #expect(
      RoutingPortCompatibility.incompatibilityReason(source: source, target: target) == nil
    )
  }

  @Test
  func structuredValuesRequireTheSameNominalSchema() {
    let source = valuePort(
      direction: .output,
      type: .structure(schema: "classification.v1")
    )
    let matching = valuePort(
      direction: .input,
      type: .structure(schema: "classification.v1")
    )
    let other = valuePort(
      direction: .input,
      type: .structure(schema: "beat-analysis.v1")
    )

    #expect(
      RoutingPortCompatibility.incompatibilityReason(source: source, target: matching) == nil
    )
    #expect(
      RoutingPortCompatibility.incompatibilityReason(source: source, target: other) != nil
    )
  }

  private func audioPort(
    direction: RoutingPortDirection,
    channel: RoutingAudioPortChannel
  ) -> RoutingGraphPortValue {
    RoutingGraphPortValue(
      direction: direction,
      channel: channel,
      ordinal: 0,
      total: 1
    )
  }

  private func valuePort(
    direction: RoutingPortDirection,
    type: RoutingSignalType
  ) -> RoutingGraphPortValue {
    RoutingGraphPortValue(
      direction: direction,
      id: "value",
      name: "Value",
      signalType: type,
      connectionPolicy: direction == .input ? .singleInput : .fanOut,
      ordinal: 0,
      total: 1
    )
  }
}
