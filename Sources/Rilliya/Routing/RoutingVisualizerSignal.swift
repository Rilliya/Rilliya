import Foundation
import RilliyaKit

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
    snapshotForNode: (UUID) -> (any RoutingAudioMeterSnapshot)?
  ) -> RoutingVisualizerSignal? {
    switch configuration.mode {
    case .mixed:
      let routedWaveforms = incomingEdges.flatMap { edge in
        routedWaveforms(for: edge, snapshotForNode: snapshotForNode)
      }
      guard let mixed = mix(routedWaveforms) else { return nil }
      return RoutingVisualizerSignal(
        lanes: [RoutingVisualizerLaneSignal(id: .mixed, samples: mixed)]
      )
    case .separate:
      let selectedChannels = configuration.normalizedSelectedChannels
      var routedByTarget = Dictionary(
        uniqueKeysWithValues: selectedChannels.map { ($0, [[Float]]()) })
      for edge in incomingEdges {
        guard case .some(.channel(let targetChannel)) = edge.target.portID.audioChannel,
          routedByTarget[targetChannel] != nil
        else {
          continue
        }
        routedByTarget[targetChannel]?.append(
          contentsOf: routedWaveforms(for: edge, snapshotForNode: snapshotForNode)
        )
      }
      let lanes = selectedChannels.map { channel in
        RoutingVisualizerLaneSignal(
          id: .channel(channel),
          samples: mix(routedByTarget[channel] ?? []) ?? []
        )
      }
      guard lanes.contains(where: { !$0.samples.isEmpty }) else { return nil }
      return RoutingVisualizerSignal(lanes: lanes)
    }
  }

  private static func routedWaveforms(
    for edge: RoutingWorkspaceEdge,
    snapshotForNode: (UUID) -> (any RoutingAudioMeterSnapshot)?
  ) -> [[Float]] {
    guard let snapshot = snapshotForNode(edge.source.nodeID) else { return [] }
    switch edge.source.portID.audioChannel {
    case .some(.all):
      return snapshot.channels.map(\.waveform)
    case .some(.channel(let channelIndex)):
      return snapshot.channels
        .filter { $0.channelID.index.rawValue == channelIndex }
        .map(\.waveform)
    case .none:
      return []
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
