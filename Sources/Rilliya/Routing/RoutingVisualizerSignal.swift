import Foundation
import RilliyaCapture

enum RoutingVisualizerLaneID: Equatable, Hashable, Sendable {
  case mixed
  case channel(Int)
}

struct RoutingVisualizerLaneSignal: Equatable, Identifiable, Sendable {
  let id: RoutingVisualizerLaneID
  let samples: [Float]
}

struct RoutingVisualizerSignal: Equatable, Sendable {
  let lanes: [RoutingVisualizerLaneSignal]

  init(lanes: [RoutingVisualizerLaneSignal]) {
    self.lanes = lanes
  }

  init(waveforms: [[Float]]) {
    lanes = waveforms.enumerated().map { index, samples in
      RoutingVisualizerLaneSignal(
        id: waveforms.count == 1 ? .mixed : .channel(index),
        samples: samples
      )
    }
  }

  var waveforms: [[Float]] {
    lanes.map(\.samples)
  }
}

enum RoutingVisualizerSignalBuilder {
  static func build(
    configuration: RoutingVisualizerConfiguration,
    incomingEdges: [RoutingWorkspaceEdge],
    resolvedSignalsForSource: (RoutingWorkspacePortAddress) -> [RoutingResolvedAudioChannelSignal]
  ) -> RoutingVisualizerSignal? {
    build(configuration: configuration, incomingEdges: incomingEdges) { edge in
      resolvedSignalsForSource(edge.source).map {
        RoutedChannel(channel: $0.channelIndex, waveform: $0.waveform)
      }
    }
  }

  static func build(
    configuration: RoutingVisualizerConfiguration,
    incomingEdges: [RoutingWorkspaceEdge],
    snapshotForNode: (UUID) -> (any RoutingAudioMeterSnapshot)?,
    channelControl: (UUID, Int) -> RoutingAudioChannelControl = { _, _ in .unity }
  ) -> RoutingVisualizerSignal? {
    build(configuration: configuration, incomingEdges: incomingEdges) { edge in
      routedWaveforms(
        for: edge,
        snapshotForNode: snapshotForNode,
        channelControl: channelControl
      )
    }
  }

  /// One channel of audio arriving on a connection, and which channel it is.
  ///
  /// The channel travels with the samples because a single connection carries every channel of
  /// its source. Drawing them apart from one connection is only possible while that is known.
  private struct RoutedChannel {
    let channel: Int
    let waveform: [Float]
  }

  private static func build(
    configuration: RoutingVisualizerConfiguration,
    incomingEdges: [RoutingWorkspaceEdge],
    routedChannels: (RoutingWorkspaceEdge) -> [RoutedChannel]
  ) -> RoutingVisualizerSignal? {
    switch configuration.displayMode {
    case .mixed:
      let waveforms = incomingEdges.flatMap { routedChannels($0).map(\.waveform) }
      guard let mixed = mix(waveforms) else { return nil }
      return RoutingVisualizerSignal(
        lanes: [RoutingVisualizerLaneSignal(id: .mixed, samples: mixed)]
      )
    case .separate:
      let selectedChannels = configuration.normalizedSelectedChannels
      var routedByLane = Dictionary(
        uniqueKeysWithValues: selectedChannels.map { ($0, [[Float]]()) })
      for edge in incomingEdges {
        // A connection made to one channel's port carries that channel, whatever the source calls
        // it. One carrying every channel keeps each where it belongs — which is what lets a node
        // fed by a single cable still be drawn channel by channel.
        var targetChannel: Int?
        if case .some(.channel(let channelIndex)) = edge.target.portID.audioChannel {
          targetChannel = channelIndex
        }
        for routed in routedChannels(edge) {
          let lane = targetChannel ?? routed.channel
          guard routedByLane[lane] != nil else { continue }
          routedByLane[lane]?.append(routed.waveform)
        }
      }
      let lanes = selectedChannels.map { channel in
        RoutingVisualizerLaneSignal(
          id: .channel(channel),
          samples: mix(routedByLane[channel] ?? []) ?? []
        )
      }
      guard lanes.contains(where: { !$0.samples.isEmpty }) else { return nil }
      return RoutingVisualizerSignal(lanes: lanes)
    }
  }

  private static func routedWaveforms(
    for edge: RoutingWorkspaceEdge,
    snapshotForNode: (UUID) -> (any RoutingAudioMeterSnapshot)?,
    channelControl: (UUID, Int) -> RoutingAudioChannelControl
  ) -> [RoutedChannel] {
    guard let snapshot = snapshotForNode(edge.source.nodeID) else { return [] }
    switch edge.source.portID.audioChannel {
    case .some(.all):
      return snapshot.channels.map { channel in
        let index = channel.channelID.index.rawValue
        return RoutedChannel(
          channel: index,
          waveform: scaled(
            channel.waveform,
            by: channelControl(edge.source.nodeID, index).linearGain
          )
        )
      }
    case .some(.channel(let channelIndex)):
      return snapshot.channels
        .filter { $0.channelID.index.rawValue == channelIndex }
        .map {
          RoutedChannel(
            channel: channelIndex,
            waveform: scaled(
              $0.waveform,
              by: channelControl(edge.source.nodeID, channelIndex).linearGain
            )
          )
        }
    case .none:
      return []
    }
  }

  private static func scaled(_ samples: [Float], by gain: Float) -> [Float] {
    guard gain != 1 else { return samples }
    return samples.map { sample in
      guard sample.isFinite else { return 0 }
      return sample * gain
    }
  }

  private static func mix(_ waveforms: [[Float]]) -> [Float]? {
    guard let sampleCount = waveforms.map(\.count).min(), sampleCount > 0 else { return nil }
    return (0..<sampleCount).map { sampleIndex in
      let sum = waveforms.reduce(Float.zero) { partial, waveform in
        partial + waveform[sampleIndex]
      }
      return sum / Float(waveforms.count)
    }
  }
}

enum RoutingWaveformDisplayTransform {
  static func normalizedSamples(_ samples: [Float]) -> [Float] {
    let finiteSamples = samples.map { $0.isFinite ? $0 : 0 }
    let peak = finiteSamples.reduce(Float.zero) { max($0, abs($1)) }
    let gain: Float = peak > 0.000_001 ? min(20, 0.9 / peak) : 1
    return finiteSamples.map { min(max($0 * gain, -0.9), 0.9) }
  }
}
