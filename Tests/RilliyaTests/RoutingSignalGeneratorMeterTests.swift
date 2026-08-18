import Foundation
import RilliyaCore
import RilliyaRealtime
import Testing

@testable import Rilliya

/// Drawing a source that has no producer to ask.
///
/// Every other source is measured by whatever produces it and asked for a snapshot afterwards. A
/// generator's samples are made as they are played, so the graph rendering them reports instead,
/// and the canvas has to be able to draw what arrives that way like anything else.
@Suite("Routing signal generator meter", .serialized)
@MainActor
struct RoutingSignalGeneratorMeterTests {
  private static func channels(rootMeanSquare: Float) -> [AudioChannelMeterSnapshot] {
    guard let index = AudioChannelIndex(rawValue: 0) else { return [] }
    return [
      AudioChannelMeterSnapshot(
        channelID: AudioChannelID(ownerID: .source(.stream(UUID())), index: index),
        rootMeanSquare: rootMeanSquare,
        peak: rootMeanSquare,
        decibels: -20,
        isClipping: false,
        waveform: [rootMeanSquare, -rootMeanSquare]
      )
    ]
  }

  private static func settles(_ predicate: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
      if predicate() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return false
  }

  @Test("What the graph reports becomes the node's snapshot")
  func reportedAudioBecomesASnapshot() async {
    let controller = RoutingSignalGeneratorMeterController()
    let nodeID = UUID()

    controller.meterHandler()(nodeID, Self.channels(rootMeanSquare: 0.5))

    #expect(await Self.settles { controller.snapshot(for: nodeID) != nil })
    #expect(controller.snapshot(for: nodeID)?.channels.first?.rootMeanSquare == 0.5)
    #expect(controller.snapshot(for: UUID()) == nil, "a node nothing reported for had a snapshot")
  }

  /// The canvas redraws when observed state changes, so the report has to land in observed state
  /// rather than somewhere a drawing would have to poll.
  @Test("A later report replaces the earlier one")
  func aLaterReportReplacesTheEarlierOne() async {
    let controller = RoutingSignalGeneratorMeterController()
    let nodeID = UUID()

    controller.meterHandler()(nodeID, Self.channels(rootMeanSquare: 0.1))
    #expect(await Self.settles { controller.snapshot(for: nodeID) != nil })
    controller.meterHandler()(nodeID, Self.channels(rootMeanSquare: 0.9))

    #expect(
      await Self.settles {
        controller.snapshot(for: nodeID)?.channels.first?.rootMeanSquare == 0.9
      },
      "the node kept the first report")
  }

  /// A node that stopped generating must stop drawing rather than hold its last loud frame.
  @Test("A node no longer generating is forgotten")
  func aStoppedNodeIsForgotten() async {
    let controller = RoutingSignalGeneratorMeterController()
    let running = UUID()
    let stopped = UUID()

    controller.meterHandler()(running, Self.channels(rootMeanSquare: 0.5))
    controller.meterHandler()(stopped, Self.channels(rootMeanSquare: 0.5))
    #expect(await Self.settles { controller.snapshot(for: stopped) != nil })

    controller.retain([running])

    #expect(controller.snapshot(for: running) != nil)
    #expect(controller.snapshot(for: stopped) == nil, "a stopped node kept drawing")
  }

  /// The point of the whole shape: a generator now resolves to something a canvas can draw.
  ///
  /// It used to resolve to nothing, so a visualizer fed by one drew an empty node while the tone
  /// was audibly playing.
  @Test("A generator resolves to a drawable signal")
  func aGeneratorResolvesToADrawableSignal() {
    let workflow = RoutingWorkflowModel(name: "Generator")
    let generatorID = workflow.workspace.addSignalGeneratorNode(centeredAt: .zero)
    let snapshot = RoutingSignalGeneratorMeterSnapshot(channels: Self.channels(rootMeanSquare: 0.5))
    let resolver = RoutingAudioSignalResolver(
      nodes: workflow.workspace.nodes,
      activeEdges: [],
      snapshotForNode: { $0 == generatorID ? snapshot : nil }
    )

    let signals = resolver.resolveOutput(
      RoutingWorkspacePortAddress(
        nodeID: generatorID,
        portID: RoutingGraphPortID(direction: .output, channel: .all)
      )
    )

    #expect(!signals.isEmpty, "a generator resolved to nothing a canvas could draw")
    #expect(signals.first?.rootMeanSquare == 0.5)
  }

  /// A generator nothing has measured yet draws nothing rather than silence, so a node that has
  /// not started is not shown as one that started and is quiet.
  @Test("A generator nothing has measured resolves to nothing")
  func anUnmeasuredGeneratorResolvesToNothing() {
    let workflow = RoutingWorkflowModel(name: "Generator")
    let generatorID = workflow.workspace.addSignalGeneratorNode(centeredAt: .zero)
    let resolver = RoutingAudioSignalResolver(
      nodes: workflow.workspace.nodes,
      activeEdges: [],
      snapshotForNode: { _ in nil }
    )

    #expect(
      resolver.resolveOutput(
        RoutingWorkspacePortAddress(
          nodeID: generatorID,
          portID: RoutingGraphPortID(direction: .output, channel: .all)
        )
      ).isEmpty)
  }
}
