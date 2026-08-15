import Foundation
import RilliyaKit

struct RoutingVisualizerSignal: Equatable, Sendable {
  let waveforms: [[Float]]
}

enum RoutingVisualizerSignalBuilder {
  static func build(
    configuration: RoutingVisualizerConfiguration,
    incomingEdges: [RoutingWorkspaceEdge],
    snapshotForNode: (UUID) -> ProcessOutputMeterSnapshot?
  ) -> RoutingVisualizerSignal? {
    switch configuration.mode {
    case .mixed:
      let routedWaveforms = incomingEdges.flatMap { edge in
        routedWaveforms(for: edge, snapshotForNode: snapshotForNode)
      }
      guard let mixed = mix(routedWaveforms) else { return nil }
      return RoutingVisualizerSignal(waveforms: [mixed])
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
        mix(routedByTarget[channel] ?? []) ?? []
      }
      guard lanes.contains(where: { !$0.isEmpty }) else { return nil }
      return RoutingVisualizerSignal(waveforms: lanes)
    }
  }

  private static func routedWaveforms(
    for edge: RoutingWorkspaceEdge,
    snapshotForNode: (UUID) -> ProcessOutputMeterSnapshot?
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
