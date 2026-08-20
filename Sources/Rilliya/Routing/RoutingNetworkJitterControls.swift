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
  static let maximumTargetMilliseconds = 500

  private static let automaticTargetCeilingMilliseconds = 200
  private static let targetRecoveryHeadroomMilliseconds = 50
  private static let defaultReceiveCapacityFrameCount = 32_768

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

  /// Clamps what it reads, because a hand-edited document must not reach the buffer with a
  /// value the buffer would refuse.
  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    targetMilliseconds = min(
      max(
        try container.decode(Int.self, forKey: .targetMilliseconds), Self.minimumTargetMilliseconds),
      Self.maximumTargetMilliseconds
    )
    correction = try container.decode(RoutingNetworkJitterCorrection.self, forKey: .correction)
  }

  /// The library controls this describes.
  func resolve() throws -> AudioJitterBufferConfiguration {
    try AudioJitterBufferConfiguration(
      targetLatency: .milliseconds(targetMilliseconds),
      maximumLatency: .milliseconds(maximumLatencyMilliseconds),
      correction: correction.libraryValue
    )
  }

  func requiredReceiveCapacityFrameCount(sampleRate: Double) -> Int {
    max(
      Self.defaultReceiveCapacityFrameCount,
      Int(ceil(sampleRate * Double(maximumLatencyMilliseconds) / 1_000))
    )
  }

  private var maximumLatencyMilliseconds: Int {
    max(
      Self.automaticTargetCeilingMilliseconds,
      targetMilliseconds + Self.targetRecoveryHeadroomMilliseconds
    )
  }
}

enum RoutingNetworkJitterTargetChoice: Hashable {
  case preset(Int)
  case custom
}

enum RoutingNetworkJitterTargetSelection {
  static let presets = [5, 20, 50]

  static func choice(for milliseconds: Int) -> RoutingNetworkJitterTargetChoice {
    presets.contains(milliseconds) ? .preset(milliseconds) : .custom
  }

  static func label(for milliseconds: Int) -> String {
    switch milliseconds {
    case 5: "Wired · 5 ms"
    case 20: "Wi-Fi · 20 ms"
    case 50: "Tunnel · 50 ms"
    default: "\(milliseconds) ms"
    }
  }

  static func validatedCustomTarget(_ text: String) -> Int? {
    guard let milliseconds = Int(text.trimmingCharacters(in: .whitespaces)) else { return nil }
    guard
      (RoutingNetworkJitterControls
        .minimumTargetMilliseconds...RoutingNetworkJitterControls
        .maximumTargetMilliseconds).contains(milliseconds)
    else { return nil }
    return milliseconds
  }
}
