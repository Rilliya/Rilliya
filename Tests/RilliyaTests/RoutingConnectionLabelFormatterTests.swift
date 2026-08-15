import RilliyaKit
import Testing

@testable import Rilliya

@Suite("Routing connection labels")
struct RoutingConnectionLabelFormatterTests {
  @Test
  func aggregateFormatUsesTheNegotiatedChannelCountAndSampleRate() throws {
    let processID = try #require(AudioProcessID(rawValue: 42))
    let channelIDs = try (0..<2).map { index in
      AudioChannelID(
        ownerID: .source(.processOutput(processID)),
        index: try #require(AudioChannelIndex(rawValue: index))
      )
    }
    let label = RoutingConnectionLabelFormatter.label(
      level: .format,
      source: audioPort(direction: .output, channel: .all),
      target: audioPort(direction: .input, channel: .all),
      targetNode: .visualizer(configuration: .initial),
      format: RoutingAudioCaptureFormat(
        sampleRate: 48_000,
        channelIDs: channelIDs
      )
    )

    #expect(label == "2 ch · 48 kHz")
  }

  @Test
  func separatedChannelsDescribeTheirDestinationLane() {
    let label = RoutingConnectionLabelFormatter.label(
      level: .channels,
      source: audioPort(direction: .output, channel: .channel(1)),
      target: audioPort(direction: .input, channel: .channel(4)),
      targetNode: .visualizer(
        configuration: RoutingVisualizerConfiguration(
          mode: .separate,
          availableChannelCount: 8,
          selectedChannels: [4]
        )
      ),
      format: nil
    )

    #expect(label == "Ch 2 → Lane 5")
  }

  @Test
  func hiddenLabelsProduceNoCanvasCopy() {
    let label = RoutingConnectionLabelFormatter.label(
      level: .hidden,
      source: audioPort(direction: .output, channel: .all),
      target: audioPort(direction: .input, channel: .all),
      targetNode: .visualizer(configuration: .initial),
      format: nil
    )

    #expect(label == nil)
  }

  @Test
  func unknownFormatsKeepTheCompactRouteLabel() {
    let label = RoutingConnectionLabelFormatter.label(
      level: .format,
      source: audioPort(direction: .output, channel: .all),
      target: audioPort(direction: .input, channel: .all),
      targetNode: .visualizer(configuration: .initial),
      format: nil
    )

    #expect(label == "All ch")
  }

  private func audioPort(
    direction: RoutingPortDirection,
    channel: RoutingAudioPortChannel
  ) -> RoutingGraphPortValue {
    RoutingGraphPortValue(direction: direction, channel: channel, ordinal: 0, total: 1)
  }
}
