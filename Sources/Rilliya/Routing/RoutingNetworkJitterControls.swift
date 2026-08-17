import Foundation
import RilliyaRealtime

/// How a receive node shortens its queue once the network has run it long.
enum RoutingNetworkJitterCorrection: String, Codable, CaseIterable, Sendable {
  /// Overlaps the waveform with itself so the seam is a crossfade rather than a step.
  case overlap

  /// Moves the read position, which costs almost nothing and leaves a brief click.
  case discard

  var displayName: String {
    switch self {
    case .overlap: "Blend"
    case .discard: "Skip"
    }
  }

  var explanation: String {
    switch self {
    case .overlap:
      "Overlaps the waveform with itself, so shortening the queue is inaudible. Falls back to "
        + "skipping when the render block is too short to hold the blend."
    case .discard:
      "Jumps the queue forward, which costs nothing and can click."
    }
  }

  fileprivate var libraryValue: AudioJitterCorrection {
    switch self {
    case .overlap: .overlap
    case .discard: .discard
    }
  }
}

/// How much audio a receive node holds before a render callback may read it.
///
/// The queue raises its own target after an underrun, so this is where it settles on a network
/// that behaves rather than a ceiling. Documents saved before this existed decode to ``initial``.
struct RoutingNetworkJitterControls: Codable, Equatable, Hashable, Sendable {
  static let minimumTargetMilliseconds = 2
  static let maximumTargetMilliseconds = 200

  /// Two packets of slack, which is what a wired local network needs.
  static let initial = RoutingNetworkJitterControls(targetMilliseconds: 5, correction: .overlap)

  var targetMilliseconds: Int
  var correction: RoutingNetworkJitterCorrection

  init(targetMilliseconds: Int, correction: RoutingNetworkJitterCorrection) {
    precondition(
      (Self.minimumTargetMilliseconds...Self.maximumTargetMilliseconds)
        .contains(targetMilliseconds)
    )
    self.targetMilliseconds = targetMilliseconds
    self.correction = correction
  }

  /// Decodes tolerantly, because a hand-edited document must not crash the app on load.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let target =
      try container.decodeIfPresent(Int.self, forKey: .targetMilliseconds)
      ?? Self.initial.targetMilliseconds
    targetMilliseconds = min(
      max(target, Self.minimumTargetMilliseconds),
      Self.maximumTargetMilliseconds
    )
    correction =
      try container.decodeIfPresent(RoutingNetworkJitterCorrection.self, forKey: .correction)
      ?? Self.initial.correction
  }

  /// The library controls this describes.
  func resolve() throws -> AudioJitterBufferConfiguration {
    try AudioJitterBufferConfiguration(
      targetLatency: .milliseconds(targetMilliseconds),
      correction: correction.libraryValue
    )
  }
}
