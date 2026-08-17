import Foundation
import RilliyaCore
import RilliyaRealtime
import Testing

@testable import Rilliya

/// Which kinds of source a visualizer can draw.
///
/// The visualizer tests beside this one hand a snapshot straight to the builder, so they never
/// reach the resolver that decides whether a source has anything to give at all. That is why a
/// visualizer connected to a network stream showed "Waiting for audio input" while the same
/// stream was audibly playing, and why nothing caught it.
@Suite("Routing visualizer source kinds")
struct RoutingVisualizerSourceKindTests {
  private static let sourceID = UUID()
  private static let visualizerID = UUID()

  /// A stream meters itself now, so a visualizer behind one draws it.
  @Test("A visualizer draws a network stream")
  func networkStreamIsDrawn() throws {
    let signals = Self.resolve(
      source: .networkReceive(configuration: .initial)
    )

    #expect(!signals.isEmpty, "the visualizer resolved to nothing")
    #expect(signals.contains { $0.waveform.contains { sample in sample != 0 } })
  }

  /// The control: a source kind that already worked is not broken by opening the gate.
  @Test("A visualizer still draws a capture source")
  func captureSourceIsStillDrawn() throws {
    let signals = Self.resolve(
      source: .applicationAudio(selection: nil, channelPresentation: .separate(channelCount: 2))
    )

    #expect(!signals.isEmpty)
  }

  /// Both channels arrive, which is what lets a visualizer draw them apart.
  @Test("Every channel of a stream reaches the visualizer")
  func everyChannelReaches() throws {
    let signals = Self.resolve(
      source: .networkReceive(configuration: .initial)
    )

    #expect(Set(signals.map(\.channelIndex)) == [0, 1])
  }

  /// A file being played meters what it decodes, so a visualizer behind one draws it.
  @Test("A visualizer draws a file being played")
  func filePlaybackIsDrawn() throws {
    let signals = Self.resolve(source: .filePlayback(configuration: .initial))

    #expect(!signals.isEmpty, "the visualizer resolved to nothing")
    #expect(Set(signals.map(\.channelIndex)) == [0, 1])
  }

  /// A generator has no producer outside the graph, and is drawn anyway.
  ///
  /// Its samples are made as they are played, so the graph rendering them measures and reports;
  /// what arrives is the same per-channel snapshot every other source delivers, which is why the
  /// visualizer needs to know nothing about where it came from.
  @Test("A generator measured by the graph draws like any other source")
  func aGeneratorMeasuredByTheGraphDraws() throws {
    let generator = Self.resolve(source: .signalGenerator(configuration: .initial))

    #expect(!generator.isEmpty, "a generator the graph measured drew nothing")
  }

  /// A node nothing has measured draws nothing rather than silence: one that has not started is
  /// not the same as one that started and is quiet.
  @Test("A source nothing has measured draws nothing")
  func unmeasuredSourcesDrawNothing() throws {
    let generator = Self.resolve(
      source: .signalGenerator(configuration: .initial),
      snapshotForNode: { _ in nil }
    )

    #expect(generator.isEmpty)
  }

  /// Resolves what a visualizer fed by `source` would be given to draw.
  private static func resolve(
    source value: RoutingNodeValue,
    snapshotForNode: ((UUID) -> (any RoutingAudioMeterSnapshot)?)? = nil
  ) -> [RoutingResolvedAudioChannelSignal] {
    let sourceNode = RoutingWorkspaceNode(id: sourceID, value: value, frame: .zero)
    let visualizer = RoutingWorkspaceNode(
      id: visualizerID,
      value: .visualizer(configuration: .initial),
      frame: .zero
    )
    let edge = RoutingWorkspaceEdge(
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
    let snapshot = meterSnapshot()
    let resolver = RoutingAudioSignalResolver(
      nodes: [sourceNode, visualizer],
      activeEdges: [edge],
      snapshotForNode: snapshotForNode ?? { $0 == sourceID ? snapshot : nil }
    )
    return resolver.resolveOutput(
      RoutingWorkspacePortAddress(
        nodeID: visualizerID,
        portID: RoutingGraphPortID(direction: .output, channel: .all)
      )
    )
  }

  /// A snapshot with audio in it, so a source resolving to nothing is the only way to fail.
  private static func meterSnapshot() -> RoutingNetworkReceiveMeterSnapshot {
    RoutingNetworkReceiveMeterSnapshot(
      channels: (0..<2).compactMap { index in
        AudioChannelIndex(rawValue: index).map { channelIndex in
          AudioChannelMeterSnapshot(
            channelID: AudioChannelID(ownerID: .source(.stream(sourceID)), index: channelIndex),
            rootMeanSquare: 0.3,
            peak: 0.6,
            decibels: -10,
            isClipping: false,
            waveform: (0..<64).map { Float(sin(Double($0) / 8)) * 0.5 }
          )
        }
      }
    )
  }
}
