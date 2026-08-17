import Foundation
import RilliyaNetworkAudio
import Testing

@testable import Rilliya

/// What a send node puts on the wire decides whether the node can start at all, so the choice and
/// its constraints are checked rather than trusted.
@Suite("Routing network wire format")
struct RoutingNetworkWireFormatTests {
  @Test("Every choice the interface offers names a format the library carries")
  func everyChoiceReachesTheLibrary() {
    for encoding in RoutingNetworkWireEncoding.allCases {
      switch encoding {
      case .uncompressed:
        #expect(encoding.libraryValue == .interleavedFloat32)
        #expect(encoding.codec == nil)
      default:
        let codec = encoding.codec
        #expect(codec != nil, "\(encoding) names no codec")
        #expect(codec?.encoding == encoding.libraryValue)
      }
      #expect(!encoding.displayName.isEmpty)
    }
  }

  @Test("Each choice has its own name and its own value on the wire")
  func choicesAreDistinct() {
    let names = Set(RoutingNetworkWireEncoding.allCases.map(\.displayName))
    let values = Set(RoutingNetworkWireEncoding.allCases.map(\.libraryValue))

    #expect(names.count == RoutingNetworkWireEncoding.allCases.count)
    #expect(values.count == RoutingNetworkWireEncoding.allCases.count)
  }

  /// The reason more than one compressing format is offered: Opus does not carry 44.1 kHz and the
  /// AAC profiles do, so a CD-rate source can be sent untouched.
  @Test("The formats between them carry the rates a source arrives at")
  func formatsCoverTheUsualRates() {
    let uncompressed = RoutingNetworkWireFormat(encoding: .uncompressed, bitRate: 128_000)
    let opus = RoutingNetworkWireFormat(encoding: .opus, bitRate: 128_000)
    let aac = RoutingNetworkWireFormat(encoding: .aacEnhancedLowDelay, bitRate: 128_000)

    #expect(uncompressed.carries(sampleRate: 44_100, channelCount: 2))
    #expect(!opus.carries(sampleRate: 44_100, channelCount: 2))
    #expect(aac.carries(sampleRate: 44_100, channelCount: 2))
    for format in [uncompressed, opus, aac] {
      #expect(format.carries(sampleRate: 48_000, channelCount: 2))
    }
  }

  /// Uncompressed carries whatever the graph produces; a codec carries only what it defines.
  @Test("Uncompressed carries anything and a codec does not")
  func uncompressedCarriesAnything() {
    let uncompressed = RoutingNetworkWireFormat(encoding: .uncompressed, bitRate: 128_000)
    let opus = RoutingNetworkWireFormat(encoding: .opus, bitRate: 128_000)

    #expect(uncompressed.carries(sampleRate: 192_000, channelCount: 8))
    #expect(RoutingNetworkWireFormat.supportedSampleRates(for: .uncompressed) == nil)
    #expect(RoutingNetworkWireFormat.supportedChannelCounts(for: .uncompressed) == nil)

    #expect(!opus.carries(sampleRate: 192_000, channelCount: 8))
    #expect(RoutingNetworkWireFormat.supportedSampleRates(for: .opus) != nil)
  }

  /// The figure shown beside the choice is what makes the cost visible, so it has to move with
  /// the choice rather than being a constant.
  @Test("The bandwidth shown falls when a compressing format is chosen")
  func bandwidthFallsWithCompression() {
    let uncompressed = RoutingNetworkWireFormat(encoding: .uncompressed, bitRate: 128_000)
    let opus = RoutingNetworkWireFormat(encoding: .opus, bitRate: 128_000)
    let lossless = RoutingNetworkWireFormat(encoding: .appleLossless, bitRate: 128_000)

    let raw = uncompressed.bitsPerSecond(sampleRate: 48_000, channelCount: 2)
    let compressed = opus.bitsPerSecond(sampleRate: 48_000, channelCount: 2)
    let exact = lossless.bitsPerSecond(sampleRate: 48_000, channelCount: 2)

    // Measured between two Macs: 3346, 213 and 2061 kbit/s.
    #expect(raw > 3_000_000)
    #expect(raw < 3_600_000)
    #expect(compressed > 150_000)
    #expect(compressed < 350_000)
    // Lossless spends what the audio needs, which is between the two.
    #expect(exact > compressed)
    #expect(exact < raw)
  }

  @Test("The bandwidth shown rises with the bit rate and with the channels")
  func bandwidthFollowsTheSettings() {
    let quiet = RoutingNetworkWireFormat(encoding: .opus, bitRate: 64_000)
    let loud = RoutingNetworkWireFormat(encoding: .opus, bitRate: 256_000)

    #expect(
      quiet.bitsPerSecond(sampleRate: 48_000, channelCount: 2)
        < loud.bitsPerSecond(sampleRate: 48_000, channelCount: 2)
    )

    let uncompressed = RoutingNetworkWireFormat(encoding: .uncompressed, bitRate: 128_000)
    #expect(
      uncompressed.bitsPerSecond(sampleRate: 48_000, channelCount: 1)
        < uncompressed.bitsPerSecond(sampleRate: 48_000, channelCount: 2)
    )
  }

  /// At a low bit rate more than half of what crosses the wire is per-packet framing, which is
  /// why lowering the bit rate further buys very little.
  @Test("The figure counts the framing, not only the payload")
  func bandwidthIncludesFraming() {
    let format = RoutingNetworkWireFormat(encoding: .opus, bitRate: 64_000)

    #expect(format.bitsPerSecond(sampleRate: 48_000, channelCount: 2) > 64_000 * 3 / 2)
  }

  @Test("The choice round-trips through a saved workflow")
  func choiceSurvivesPersistence() throws {
    let wire = RoutingNetworkWireFormat(encoding: .aacLowDelay, bitRate: 96_000)
    let configuration = RoutingNetworkSendConfiguration(
      host: "10.0.0.2",
      port: 48_620,
      sampleRate: 48_000,
      channelCount: 2,
      wire: wire
    )

    let encoded = try JSONEncoder().encode(configuration)
    let decoded = try JSONDecoder().decode(RoutingNetworkSendConfiguration.self, from: encoded)

    #expect(decoded == configuration)
    #expect(decoded.wire == wire)
  }

  /// The listener is rebuilt around whatever is chosen, so the choice has to be part of what the
  /// controller compares when deciding to restart a node.
  @Test("Changing the wire format is a different configuration")
  func choiceChangesTheConfiguration() {
    let plain = RoutingNetworkSendConfiguration(
      host: "10.0.0.2",
      port: 48_620,
      sampleRate: 48_000,
      channelCount: 2
    )
    var compressed = plain
    compressed.wire = RoutingNetworkWireFormat(encoding: .opus, bitRate: 128_000)
    var louder = compressed
    louder.wire.bitRate = 256_000

    #expect(plain != compressed)
    #expect(compressed != louder)
  }

  @Test("The bit rates offered are ones the system's encoders accept")
  func offeredBitRatesAreUsable() throws {
    let codec = NetworkAudioCodec.opus
    let frames = try #require(
      codec.frameCount(nearestTo: 10, sampleRate: 48_000, channelCount: 2))

    for bitRate in RoutingNetworkWireFormat.bitRates {
      #expect(throws: Never.self) {
        _ = try NetworkAudioCompressedEncoder(
          codec: codec,
          sampleRate: 48_000,
          channelCount: 2,
          frameCountPerPacket: frames,
          bitRate: bitRate
        )
      }
    }
  }
}
