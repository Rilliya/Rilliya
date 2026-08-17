import Foundation
import RilliyaCore
import RilliyaRealtime
import Testing

@testable import Rilliya

/// A visualizer answers three questions, and they used to be one answer.
///
/// How audio reaches it, how it is drawn, and what it hands on are independent: a node fed by one
/// cable can still be drawn channel by channel, because that cable already carries every channel.
/// Requiring the channels to be wired apart before they could be drawn apart was work for nothing.
@Suite("Routing visualizer modes")
struct RoutingVisualizerModeTests {
  private static let sourceID = UUID()
  private static let visualizerID = UUID()

  // MARK: The point of the change

  /// One cable in, drawn channel by channel.
  @Test("A node fed by one cable is still drawn channel by channel")
  func oneCableDrawsEveryChannel() throws {
    let signal = try #require(
      Self.draw(
        inputMode: .mixed,
        displayMode: .separate,
        edges: [Self.allToAll()]
      )
    )

    #expect(signal.lanes.count == 2)
    #expect(signal.lanes.map(\.id) == [.channel(0), .channel(1)])
    // Each lane carries its own channel, not a copy of one.
    let left = try #require(signal.lanes.first?.samples)
    let right = try #require(signal.lanes.last?.samples)
    #expect(left != right, "both lanes drew the same channel")
    #expect(left.contains { $0 != 0 })
    #expect(right.contains { $0 != 0 })
  }

  /// The same node, drawn mixed, is one lane — the input has not changed.
  @Test("The same input drawn mixed is one lane")
  func oneCableDrawnMixedIsOneLane() throws {
    let signal = try #require(
      Self.draw(inputMode: .mixed, displayMode: .mixed, edges: [Self.allToAll()])
    )

    #expect(signal.lanes.count == 1)
    #expect(signal.lanes.first?.id == .mixed)
  }

  /// Wiring the channels apart still works, and a connection made to one channel's port carries
  /// that channel whatever the source calls it.
  @Test("Channels wired apart are still drawn apart")
  func wiredApartIsStillDrawnApart() throws {
    let signal = try #require(
      Self.draw(
        inputMode: .separate,
        displayMode: .separate,
        edges: [Self.channelToChannel(0), Self.channelToChannel(1)]
      )
    )

    #expect(signal.lanes.count == 2)
    #expect(signal.lanes.map(\.id) == [.channel(0), .channel(1)])
    #expect(signal.lanes.allSatisfy { !$0.samples.isEmpty })
  }

  // MARK: The three choices are independent

  @Test("Each choice is kept apart from the others")
  func choicesAreIndependent() {
    var configuration = RoutingVisualizerConfiguration.initial
    configuration.displayMode = .separate

    #expect(configuration.inputMode == .mixed)
    #expect(configuration.outputMode == .mixed)
    #expect(configuration.displayMode == .separate)
  }

  /// The ports follow the input and the output, and neither follows what is drawn.
  @Test("Drawing apart does not split the ports")
  func drawingApartLeavesThePorts() {
    var configuration = RoutingVisualizerConfiguration.initial
    configuration.availableChannelCount = 2
    configuration.displayMode = .separate

    let ports = RoutingGraphPorts.values(
      for: .visualizer(configuration: configuration))
    let inputs = ports.filter { $0.direction == .input }
    let outputs = ports.filter { $0.direction == .output }

    #expect(inputs.count == 1, "drawing apart split the input")
    #expect(inputs.first?.key == .audio(.all))
    #expect(outputs.count == 1, "drawing apart split the output")
    #expect(outputs.first?.key == .audio(.all))
  }

  @Test("Splitting the input leaves the output alone")
  func inputAndOutputAreApart() {
    var configuration = RoutingVisualizerConfiguration.initial
    configuration.availableChannelCount = 2
    configuration.channelSelection = .preset(.stereo)
    configuration.inputMode = .separate

    let ports = RoutingGraphPorts.values(
      for: .visualizer(configuration: configuration))

    #expect(ports.filter { $0.direction == .input }.count == 2)
    #expect(ports.filter { $0.direction == .output }.count == 1)
  }

  @Test("Splitting the output leaves the input alone")
  func outputSplitsOnItsOwn() {
    var configuration = RoutingVisualizerConfiguration.initial
    configuration.availableChannelCount = 2
    configuration.channelSelection = .preset(.stereo)
    configuration.outputMode = .separate

    let ports = RoutingGraphPorts.values(
      for: .visualizer(configuration: configuration))

    #expect(ports.filter { $0.direction == .input }.count == 1)
    #expect(ports.filter { $0.direction == .output }.count == 2)
  }

  // MARK: Persistence

  @Test("All three choices survive a saved workflow")
  func choicesSurvivePersistence() throws {
    var configuration = RoutingVisualizerConfiguration.initial
    configuration.inputMode = .mixed
    configuration.displayMode = .separate
    configuration.outputMode = .separate
    configuration.channelSelection = .preset(.stereo)

    let decoded = try JSONDecoder().decode(
      RoutingVisualizerConfiguration.self,
      from: try JSONEncoder().encode(configuration)
    )

    #expect(decoded.inputMode == .mixed)
    #expect(decoded.displayMode == .separate)
    #expect(decoded.outputMode == .separate)
    #expect(decoded == configuration)
  }

  /// A document written when one control set all three carries only `mode`, and opening it must
  /// give the node the arrangement it had rather than refusing to open.
  ///
  /// The old document is made from a real encoding rather than written by hand, so this tests the
  /// decoder against the shape the encoder actually produced.
  @Test("A document written before the split still opens")
  func documentFromBeforeTheSplitOpens() throws {
    var configuration = RoutingVisualizerConfiguration.initial
    configuration.availableChannelCount = 4
    configuration.channelSelection = .preset(.stereo)
    configuration.includesMixedOutput = true

    var fields = try #require(
      try JSONSerialization.jsonObject(
        with: try JSONEncoder().encode(configuration)) as? [String: Any]
    )
    for key in ["inputMode", "displayMode", "outputMode"] { fields.removeValue(forKey: key) }
    fields["mode"] = "separate"
    let old = try JSONSerialization.data(withJSONObject: fields)

    let decoded = try JSONDecoder().decode(RoutingVisualizerConfiguration.self, from: old)

    #expect(decoded.inputMode == .separate)
    #expect(decoded.displayMode == .separate)
    #expect(decoded.outputMode == .separate)
    #expect(decoded.availableChannelCount == 4)
    #expect(decoded.includesMixedOutput)
  }

  // MARK: Helpers

  private static func allToAll() -> RoutingWorkspaceEdge {
    RoutingWorkspaceEdge(
      id: UUID(),
      source: RoutingWorkspacePortAddress(
        nodeID: sourceID,
        portID: RoutingGraphPortID(direction: .output, channel: .all)
      ),
      target: RoutingWorkspacePortAddress(
        nodeID: visualizerID,
        portID: RoutingGraphPortID(direction: .input, channel: .all)
      )
    )
  }

  private static func channelToChannel(_ channel: Int) -> RoutingWorkspaceEdge {
    RoutingWorkspaceEdge(
      id: UUID(),
      source: RoutingWorkspacePortAddress(
        nodeID: sourceID,
        portID: RoutingGraphPortID(direction: .output, channel: .channel(channel))
      ),
      target: RoutingWorkspacePortAddress(
        nodeID: visualizerID,
        portID: RoutingGraphPortID(direction: .input, channel: .channel(channel))
      )
    )
  }

  private static func draw(
    inputMode: RoutingVisualizerMode,
    displayMode: RoutingVisualizerMode,
    edges: [RoutingWorkspaceEdge]
  ) -> RoutingVisualizerSignal? {
    var configuration = RoutingVisualizerConfiguration.initial
    configuration.inputMode = inputMode
    configuration.displayMode = displayMode
    configuration.availableChannelCount = 2
    configuration.channelSelection = .preset(.stereo)

    let snapshot = meterSnapshot()
    return RoutingVisualizerSignalBuilder.build(
      configuration: configuration,
      incomingEdges: edges,
      snapshotForNode: { $0 == sourceID ? snapshot : nil }
    )
  }

  /// Two channels that do not look alike, or a lane drawing the wrong one would pass.
  private static func meterSnapshot() -> RoutingNetworkReceiveMeterSnapshot {
    RoutingNetworkReceiveMeterSnapshot(
      channels: (0..<2).compactMap { index in
        AudioChannelIndex(rawValue: index).map { channelIndex in
          AudioChannelMeterSnapshot(
            channelID: AudioChannelID(ownerID: .source(.stream(sourceID)), index: channelIndex),
            rootMeanSquare: index == 0 ? 0.4 : 0.1,
            peak: index == 0 ? 0.8 : 0.2,
            decibels: index == 0 ? -8 : -20,
            isClipping: false,
            waveform: (0..<64).map { sample in
              Float(sin(Double(sample) / 8)) * (index == 0 ? 0.8 : 0.2)
            }
          )
        }
      }
    )
  }
}
