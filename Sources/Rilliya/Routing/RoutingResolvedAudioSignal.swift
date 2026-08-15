import Foundation
import RilliyaKit

struct RoutingResolvedAudioChannelSignal: Equatable, Sendable {
  let channelIndex: Int
  let rootMeanSquare: Float
  let peak: Float
  let isClipping: Bool
  let waveform: [Float]
}

struct RoutingAudioSignalResolver {
  private let nodesByID: [UUID: RoutingWorkspaceNode]
  private let incomingEdgesByNodeID: [UUID: [RoutingWorkspaceEdge]]
  private let snapshotForNode: (UUID) -> (any RoutingAudioMeterSnapshot)?

  init(
    nodes: [RoutingWorkspaceNode],
    activeEdges: [RoutingWorkspaceEdge],
    snapshotForNode: @escaping (UUID) -> (any RoutingAudioMeterSnapshot)?
  ) {
    nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    incomingEdgesByNodeID = Dictionary(grouping: activeEdges, by: { $0.target.nodeID })
    self.snapshotForNode = snapshotForNode
  }

  func resolveOutput(
    _ address: RoutingWorkspacePortAddress
  ) -> [RoutingResolvedAudioChannelSignal] {
    resolveOutput(address, visited: [])
  }

  private func resolveOutput(
    _ address: RoutingWorkspacePortAddress,
    visited: Set<RoutingWorkspacePortAddress>
  ) -> [RoutingResolvedAudioChannelSignal] {
    guard address.portID.direction == .output,
      let node = nodesByID[address.nodeID],
      !visited.contains(address)
    else {
      return []
    }
    var visited = visited
    visited.insert(address)

    switch node.value {
    case .applicationAudio, .inputAudio:
      return sourceSignals(for: address, node: node)
    case .visualizer(let configuration):
      return visualizerSignals(
        for: address,
        configuration: configuration,
        visited: visited
      )
    case .peakLevel:
      return []
    }
  }

  private func sourceSignals(
    for address: RoutingWorkspacePortAddress,
    node: RoutingWorkspaceNode
  ) -> [RoutingResolvedAudioChannelSignal] {
    guard let snapshot = snapshotForNode(address.nodeID) else { return [] }
    let selectedChannels: [AudioChannelMeterSnapshot]
    switch address.portID.audioChannel {
    case .some(.all):
      selectedChannels = snapshot.channels
    case .some(.channel(let channelIndex)):
      selectedChannels = snapshot.channels.filter {
        $0.channelID.index.rawValue == channelIndex
      }
    case .none:
      return []
    }
    return selectedChannels.map { channel in
      let channelIndex = channel.channelID.index.rawValue
      let control = node.audioChannelControl(at: channelIndex)
      let gain = control.linearGain
      let rootMeanSquare = finiteNonnegative(channel.rootMeanSquare) * gain
      let peak = finiteNonnegative(channel.peak) * gain
      return RoutingResolvedAudioChannelSignal(
        channelIndex: channelIndex,
        rootMeanSquare: rootMeanSquare,
        peak: peak,
        isClipping: channel.isClipping || peak >= 1,
        waveform: scaled(channel.waveform, by: gain)
      )
    }
  }

  private func visualizerSignals(
    for address: RoutingWorkspacePortAddress,
    configuration: RoutingVisualizerConfiguration,
    visited: Set<RoutingWorkspacePortAddress>
  ) -> [RoutingResolvedAudioChannelSignal] {
    let incomingEdges = (incomingEdgesByNodeID[address.nodeID] ?? []).sorted {
      $0.id.uuidString < $1.id.uuidString
    }
    switch address.portID.audioChannel {
    case .some(.channel(let channelIndex)):
      guard
        let edge = incomingEdges.first(where: {
          $0.target.portID.audioChannel == .channel(channelIndex)
        })
      else {
        return []
      }
      return resolveOutput(edge.source, visited: visited)
    case .some(.all):
      switch configuration.mode {
      case .mixed:
        guard
          let edge = incomingEdges.first(where: {
            $0.target.portID.audioChannel == .all
          })
        else {
          return []
        }
        return resolveOutput(edge.source, visited: visited)
      case .separate:
        guard configuration.includesMixedOutput else { return [] }
        let selectedChannels = Set(configuration.normalizedSelectedChannels)
        let inputs = incomingEdges.filter { edge in
          guard case .some(.channel(let channelIndex)) = edge.target.portID.audioChannel else {
            return false
          }
          return selectedChannels.contains(channelIndex)
        }.flatMap { edge in
          resolveOutput(edge.source, visited: visited)
        }
        return normalizedMonoMix(inputs).map { [$0] } ?? []
      }
    case .none:
      return []
    }
  }

  private func normalizedMonoMix(
    _ channels: [RoutingResolvedAudioChannelSignal]
  ) -> RoutingResolvedAudioChannelSignal? {
    guard let sampleCount = channels.map(\.waveform.count).min(), sampleCount > 0 else {
      return nil
    }
    let divisor = Float(channels.count)
    let waveform = (0..<sampleCount).map { sampleIndex in
      channels.reduce(Float.zero) { partial, channel in
        partial + channel.waveform[sampleIndex]
      } / divisor
    }
    let squaredSum = waveform.reduce(Float.zero) { $0 + $1 * $1 }
    let rootMeanSquare = sqrt(squaredSum / Float(sampleCount))
    let peak = waveform.reduce(Float.zero) { max($0, abs($1)) }
    return RoutingResolvedAudioChannelSignal(
      channelIndex: 0,
      rootMeanSquare: rootMeanSquare,
      peak: peak,
      isClipping: peak >= 1 || channels.contains(where: \.isClipping),
      waveform: waveform
    )
  }

  private func finiteNonnegative(_ value: Float) -> Float {
    value.isFinite ? max(value, 0) : 0
  }

  private func scaled(_ samples: [Float], by gain: Float) -> [Float] {
    guard gain != 1 else { return samples }
    return samples.map { $0.isFinite ? $0 * gain : 0 }
  }
}
