import Foundation
import RilliyaCapture
import RilliyaRealtime

struct RoutingPeakLevelSignal: Equatable, Sendable {
  let linearPeak: Float
  let isClipping: Bool

  var decibelsFullScale: Float {
    guard linearPeak > 0 else { return -.infinity }
    return 20 * log10(linearPeak)
  }

  var linearDescription: String {
    String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), linearPeak)
  }

  var decibelsDescription: String {
    guard decibelsFullScale.isFinite else { return "−∞ dBFS" }
    return String(
      format: "%.1f dBFS",
      locale: Locale(identifier: "en_US_POSIX"),
      decibelsFullScale
    )
  }
}

enum RoutingPeakLevelSignalBuilder {
  static func build(
    incomingEdges: [RoutingWorkspaceEdge],
    resolvedSignalsForSource: (RoutingWorkspacePortAddress) -> [RoutingResolvedAudioChannelSignal]
  ) -> RoutingPeakLevelSignal? {
    let activeEdges = incomingEdges.filter(\.isEnabled)
    guard activeEdges.count == 1, let edge = activeEdges.first else { return nil }
    let channels = resolvedSignalsForSource(edge.source)
    guard !channels.isEmpty else { return nil }
    let linearPeak = channels.map(\.peak).max() ?? 0
    return RoutingPeakLevelSignal(
      linearPeak: linearPeak,
      isClipping: linearPeak >= 1 || channels.contains(where: \.isClipping)
    )
  }

  static func build(
    incomingEdges: [RoutingWorkspaceEdge],
    snapshotForNode: (UUID) -> (any RoutingAudioMeterSnapshot)?,
    channelControl: (UUID, Int) -> RoutingAudioChannelControl = { _, _ in .unity }
  ) -> RoutingPeakLevelSignal? {
    let activeEdges = incomingEdges.filter(\.isEnabled)
    guard activeEdges.count == 1,
      let edge = activeEdges.first,
      let snapshot = snapshotForNode(edge.source.nodeID)
    else {
      return nil
    }

    let channels: [AudioChannelMeterSnapshot]
    switch edge.source.portID.audioChannel {
    case .some(.all):
      channels = snapshot.channels
    case .some(.channel(let index)):
      channels = snapshot.channels.filter { $0.channelID.index.rawValue == index }
    case .none:
      return nil
    }
    guard !channels.isEmpty else { return nil }

    let peaks = channels.map { channel in
      let rawPeak = channel.peak.isFinite ? max(channel.peak, 0) : 0
      return rawPeak
        * channelControl(edge.source.nodeID, channel.channelID.index.rawValue).linearGain
    }
    let linearPeak = peaks.max() ?? 0
    return RoutingPeakLevelSignal(
      linearPeak: linearPeak,
      isClipping: linearPeak >= 1 || channels.contains(where: \.isClipping)
    )
  }
}
