import Foundation
import RilliyaNetworkAudio

/// How a network send node represents its audio on the wire.
enum RoutingNetworkWireEncoding: String, Codable, CaseIterable, Sendable {
  /// The samples themselves, which cost what they weigh.
  case uncompressed

  /// Opus, which packs the shortest blocks of anything offered.
  case opus

  /// AAC Enhanced Low Delay, which carries 44.1 kHz where Opus does not.
  case aacEnhancedLowDelay

  /// AAC Low Delay, the plainer of the two low-delay AAC profiles.
  case aacLowDelay

  /// Apple Lossless, which returns the audio rather than an approximation of it.
  case appleLossless

  var displayName: String {
    switch self {
    case .uncompressed: "Uncompressed"
    case .opus: "Opus"
    case .aacEnhancedLowDelay: "AAC ELD"
    case .aacLowDelay: "AAC LD"
    case .appleLossless: "Lossless"
    }
  }

  var libraryValue: NetworkAudioWireEncoding {
    switch self {
    case .uncompressed: .interleavedFloat32
    case .opus: .opus
    case .aacEnhancedLowDelay: .aacEnhancedLowDelay
    case .aacLowDelay: .aacLowDelay
    case .appleLossless: .appleLossless
    }
  }

  /// The codec behind this choice, or `nil` when the samples cross as they are.
  var codec: NetworkAudioCodec? {
    NetworkAudioCodec.codec(for: libraryValue)
  }
}

/// What a send node puts on the wire, and how much of it.
struct RoutingNetworkWireFormat: Codable, Equatable, Hashable, Sendable {
  /// The bit rates the system's encoders offer that suit music.
  static let bitRates = [64_000, 96_000, 128_000, 160_000, 256_000]

  static let initial = RoutingNetworkWireFormat(
    encoding: .uncompressed,
    bitRate: NetworkAudioSenderConfiguration.defaultOpusBitRate
  )

  var encoding: RoutingNetworkWireEncoding
  var bitRate: Int

  /// The sample rates this encoding can carry, or `nil` when it carries any.
  ///
  /// Asked of the library rather than written down, because what a codec carries is the system's
  /// answer and changes with it.
  static func supportedSampleRates(
    for encoding: RoutingNetworkWireEncoding
  ) -> [Double]? {
    encoding.codec?.supportedSampleRates
  }

  /// The channel counts this encoding can carry, or `nil` when it carries any.
  static func supportedChannelCounts(
    for encoding: RoutingNetworkWireEncoding
  ) -> [Int]? {
    encoding.codec?.supportedChannelCounts
  }

  /// Whether this format can carry audio at `sampleRate` in `channelCount` channels.
  func carries(sampleRate: Double, channelCount: Int) -> Bool {
    guard let codec = encoding.codec else { return true }
    return codec.carries(sampleRate: sampleRate, channelCount: channelCount)
  }

  /// Roughly what one second of this audio costs on the wire, in bits.
  ///
  /// Measured between two Macs, uncompressed 48 kHz stereo came to 3.3 Mbit/s and the same audio
  /// at 128 kbit/s Opus came to 213 kbit/s, so the figure includes the framing every packet
  /// carries rather than the payload alone.
  func bitsPerSecond(sampleRate: Double, channelCount: Int) -> Int {
    guard let codec = encoding.codec else {
      let payload = Int(sampleRate) * channelCount * MemoryLayout<Float>.stride * 8
      return payload + payload / 12
    }
    // A lossless codec spends what the audio needs rather than a bit rate, so the figure comes
    // from what it was measured to leave rather than from a setting.
    if codec.isLossless {
      let samples = Int(sampleRate) * channelCount * MemoryLayout<Float>.stride * 8
      return samples * 62 / 100
    }
    let frames =
      codec.frameCount(
        nearestTo: NetworkAudioSenderConfiguration.preferredBlockMilliseconds,
        sampleRate: sampleRate,
        channelCount: channelCount
      ) ?? Int(sampleRate / 100)
    let packetsPerSecond = max(sampleRate / Double(frames), 1)
    let framing = Int(packetsPerSecond) * (NetworkAudioPacketCodec.headerByteCount + 42) * 8
    return bitRate + framing
  }
}
