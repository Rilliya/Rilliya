import Foundation
import Observation
import RilliyaRealtime

/// What a signal generator sounds like, which only the graph rendering it can say.
struct RoutingSignalGeneratorMeterSnapshot: RoutingAudioMeterSnapshot {
  let channels: [AudioChannelMeterSnapshot]
}

/// Holds what each generator node is producing, so a canvas can draw it.
///
/// Every other source is measured by whatever produces it — a device, a file, a stream — and asked
/// for a snapshot afterwards. A generator has no producer outside the graph: its samples are made
/// as they are played. So the graph reports instead, and this is where the report lands.
///
/// A running generator node may be compiled into more than one prepared graph at once, one per
/// destination it feeds. Each measures its own copy; they are the same audio, so the most recent
/// report wins rather than being merged.
@MainActor
@Observable
final class RoutingSignalGeneratorMeterController {
  /// The one a running graph reports to, so every prepared graph reports to the same place.
  static let shared = RoutingSignalGeneratorMeterController()

  private(set) var snapshots: [UUID: RoutingSignalGeneratorMeterSnapshot] = [:]

  func snapshot(for nodeID: UUID) -> RoutingSignalGeneratorMeterSnapshot? {
    snapshots[nodeID]
  }

  /// A handler a prepared graph can call from wherever it delivers measurements.
  nonisolated func meterHandler() -> RoutingPreparedAudioGraphSource.MeterHandler {
    { [weak self] nodeID, channels in
      Task { @MainActor [weak self] in
        self?.snapshots[nodeID] = RoutingSignalGeneratorMeterSnapshot(channels: channels)
      }
    }
  }

  /// Forgets nodes that are no longer generating, so a stopped node stops drawing.
  func retain(_ activeNodeIDs: Set<UUID>) {
    snapshots = snapshots.filter { activeNodeIDs.contains($0.key) }
  }
}
