import Foundation
import RilliyaNetworkAudio
import RilliyaRealtime
import Testing

@testable import Rilliya

/// The wire formats a node offers, driven the way the app's own starters drive them.
///
/// The library has its own tests for each codec. These exist because the app decides the packet
/// length, the queue capacities, and the render quantum, and a format that works on the library's
/// defaults can still fail on the app's.
@Suite("Routing network wire loopback", .serialized)
struct RoutingNetworkWireLoopbackTests {
  private enum Fixture {
    static let sampleRate = 48_000.0
    static let channelCount = 2
    static let frequency = 440.0
    static let renderQuantum = RoutingRealtimeDestinationDefaults.renderQuantumFrameCount
    /// Long enough for a lossless block — 4096 frames at 48 kHz is 85 ms — to arrive several
    /// times over, so a format that only produces audio in slow lumps is still seen.
    static let seconds = 3.0
  }

  /// Every format the interface offers has to reach a listener as audio, not only as packets.
  @Test(
    "Audio a node sends arrives as audio, whatever the format",
    arguments: [
      RoutingNetworkWireEncoding.uncompressed,
      .opus,
      .aacLowDelay,
      .appleLossless,
    ]
  )
  func everyFormatCrossesTheWire(encoding: RoutingNetworkWireEncoding) async throws {
    let port = try Self.reservedPort()
    let harness = try Harness(port: port, encoding: encoding)

    let level = try await harness.run(seconds: Fixture.seconds)

    #expect(harness.statistics.acceptedPacketCount > 0, "\(encoding): nothing arrived")
    #expect(harness.statistics.rejectedPacketCount == 0, "\(encoding): packets were refused")
    // A tone at a quarter amplitude has an RMS near 0.177; anything above a tenth is audio
    // rather than the silence a starved queue reads out.
    #expect(level > 0.1, "\(encoding): the listener produced silence, level \(level)")
  }

  /// A sender changing format restarts under a new session identity, and the listener has to
  /// follow it rather than staying with the format it first heard.
  @Test("A listener follows a sender that changes format mid-stream")
  func listenerFollowsAFormatChange() async throws {
    let port = try Self.reservedPort()

    let first = try Harness(port: port, encoding: .opus, ownsListener: true)
    let opusLevel = try await first.run(seconds: 2)
    #expect(opusLevel > 0.1, "the opening format produced silence")

    // The same listener, a new sender, a different format — which is what changing the control
    // on a running send node does.
    let second = try first.replacingSender(encoding: .appleLossless)
    let losslessLevel = try await second.run(seconds: 3)

    #expect(losslessLevel > 0.1, "the listener did not follow the change, level \(losslessLevel)")
    first.close()
  }

  /// Ports are taken from the ephemeral range and confirmed free, so a machine already running a
  /// receiver does not make this fail for an unrelated reason.
  private static func reservedPort() throws -> UInt16 {
    for candidate in UInt16(49_300)...UInt16(49_360) where isFree(candidate) {
      return candidate
    }
    throw RoutingNetworkWireLoopbackError.noFreePort
  }

  private static func isFree(_ port: UInt16) -> Bool {
    let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = INADDR_ANY
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    return bound == 0
  }

  /// Builds the library objects the way `SystemRoutingNetworkSendStarter` and
  /// `SystemRoutingNetworkReceiveStarter` build them, so the parameters under test are the app's.
  private final class Harness {
    let sender: NetworkAudioSender
    let receiver: NetworkAudioReceiver

    /// This harness's own paced view of the stream, as a destination in the graph would hold.
    let destination: AudioJitterBuffer
    private let ownsListener: Bool
    private let port: UInt16
    private var phase = 0.0

    var statistics: NetworkAudioReceiverStatistics { receiver.statistics() }

    init(
      port: UInt16,
      encoding: RoutingNetworkWireEncoding,
      ownsListener: Bool = true,
      existing: NetworkAudioReceiver? = nil
    ) throws {
      self.port = port
      self.ownsListener = ownsListener
      let format = try NetworkAudioStreamFormat(
        sampleRate: Fixture.sampleRate,
        channelCount: Fixture.channelCount
      )
      let wire = RoutingNetworkWireFormat(
        encoding: encoding,
        bitRate: NetworkAudioSenderConfiguration.defaultOpusBitRate
      )
      sender = try NetworkAudioSender(
        configuration: NetworkAudioSenderConfiguration(
          host: "127.0.0.1",
          port: port,
          format: format,
          framesPerPacket: wire.encoding == .uncompressed ? Fixture.renderQuantum : nil,
          encoding: wire.encoding.libraryValue,
          opusBitRate: wire.bitRate
        )
      )
      if let existing {
        receiver = existing
      } else {
        receiver = try NetworkAudioReceiver(
          configuration: NetworkAudioReceiverConfiguration(
            port: port,
            format: format,
            jitter: try RoutingNetworkJitterControls.initial.resolve()
          )
        )
      }
      destination = try receiver.subscribeWithJitterBuffer()
    }

    func replacingSender(encoding: RoutingNetworkWireEncoding) throws -> Harness {
      try Harness(port: port, encoding: encoding, ownsListener: false, existing: receiver)
    }

    /// Feeds a tone in at the app's render quantum and reads the listener at the same quantum,
    /// paced by a clock, which is what the graph does on both sides.
    func run(seconds: Double) async throws -> Float {
      if ownsListener { try await receiver.start() }
      try await sender.start()

      let quantum = Fixture.renderQuantum
      let cycles = Int(seconds * Fixture.sampleRate) / quantum
      let period = Duration.nanoseconds(
        Int64(Double(quantum) / Fixture.sampleRate * 1_000_000_000))
      var left = [Float](repeating: 0, count: quantum)
      var right = [Float](repeating: 0, count: quantum)
      // The jitter buffer reads planar, one pointer per channel.
      let readChannels = (0..<Fixture.channelCount).map { _ in
        UnsafeMutablePointer<Float>.allocate(capacity: quantum)
      }
      for channel in readChannels { channel.initialize(repeating: 0, count: quantum) }
      defer {
        for channel in readChannels {
          channel.deinitialize(count: quantum)
          channel.deallocate()
        }
      }
      var energy = 0.0
      var counted = 0
      let clock = ContinuousClock()
      var deadline = clock.now
      // The opening cycles carry a codec's lookahead and the queue filling, so the level is
      // measured over the second half of the run.
      let settled = cycles / 2

      for cycle in 0..<cycles {
        for frame in 0..<quantum {
          let value = Float(0.25 * sin(phase))
          left[frame] = value
          right[frame] = value
          phase += 2 * .pi * Fixture.frequency / Fixture.sampleRate
          if phase > 2 * .pi { phase -= 2 * .pi }
        }
        left.withUnsafeBufferPointer { leftBuffer in
          right.withUnsafeBufferPointer { rightBuffer in
            guard let l = leftBuffer.baseAddress, let r = rightBuffer.baseAddress else { return }
            [l, r].withUnsafeBufferPointer { channels in
              _ = sender.frameBuffer.writePlanar(channels, frameCount: quantum)
            }
          }
        }
        readChannels.withUnsafeBufferPointer {
          _ = destination.read(into: $0, frameCount: quantum)
        }
        if cycle >= settled {
          for channel in readChannels {
            for frame in 0..<quantum {
              energy += Double(channel[frame]) * Double(channel[frame])
            }
          }
          counted += quantum * Fixture.channelCount
        }
        deadline += period
        if deadline < clock.now { deadline = clock.now }
        try? await clock.sleep(until: deadline)
      }

      await sender.stop()
      guard counted > 0 else { return 0 }
      return Float((energy / Double(counted)).squareRoot())
    }

    func close() {
      receiver.stop()
    }
  }
}

private enum RoutingNetworkWireLoopbackError: Error {
  case noFreePort
}
