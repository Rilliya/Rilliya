import Foundation
import RilliyaRealtime
import Testing

@testable import Rilliya

struct RoutingRealtimeCaptureSourceTests {
  @Test
  func cursorCacheReusesOneSubscriptionPerConsumerAndSession() throws {
    let distributor = try makeDistributor(maximumSubscriberCount: 2)
    let consumerID = UUID()
    let session = RoutingCaptureSessionIdentity()
    var cache = RoutingCaptureCursorCache()
    var subscriptionCount = 0

    let firstOptional = try cache.source(
      consumerID: consumerID,
      captureSessionIdentity: ObjectIdentifier(session),
      makeSource: {
        subscriptionCount += 1
        return .subscription(try distributor.subscribe())
      }
    )
    let first = try #require(firstOptional)
    let secondOptional = try cache.source(
      consumerID: consumerID,
      captureSessionIdentity: ObjectIdentifier(session),
      makeSource: {
        subscriptionCount += 1
        return .subscription(try distributor.subscribe())
      }
    )
    let second = try #require(secondOptional)

    #expect(first.source.identity == second.source.identity)
    #expect(subscriptionCount == 1)
  }

  @Test
  func cursorCacheGivesEachConsumerAnIndependentSubscriptionAndReleasesUnusedSlots() throws {
    let distributor = try makeDistributor(maximumSubscriberCount: 2)
    let session = RoutingCaptureSessionIdentity()
    let sessionIdentity = ObjectIdentifier(session)
    let firstConsumerID = UUID()
    let secondConsumerID = UUID()
    var cache = RoutingCaptureCursorCache()

    let firstKey = RoutingCaptureCursorKey(
      consumerID: firstConsumerID,
      captureSessionIdentity: sessionIdentity
    )
    let firstOptional = try cache.source(
      consumerID: firstConsumerID,
      captureSessionIdentity: sessionIdentity,
      makeSource: { .subscription(try distributor.subscribe()) }
    )
    let firstIdentity = try #require(firstOptional).source.identity
    var secondOptional = try cache.source(
      consumerID: secondConsumerID,
      captureSessionIdentity: sessionIdentity,
      makeSource: { .subscription(try distributor.subscribe()) }
    )
    let secondIdentity = try #require(secondOptional).source.identity
    #expect(firstIdentity != secondIdentity)

    secondOptional = nil
    cache.retain([firstKey])
    let replacementOptional = try cache.source(
      consumerID: UUID(),
      captureSessionIdentity: sessionIdentity,
      makeSource: { .subscription(try distributor.subscribe()) }
    )
    let replacement = try #require(replacementOptional)
    #expect(replacement.source.identity != firstIdentity)
  }

  @Test
  func captureSourceRejectsTooFewOutputChannelsBeforeSilencingAnInactiveSubscription() throws {
    let distributor = try makeDistributor(maximumSubscriberCount: 1)
    let subscription = try distributor.subscribe()
    subscription.cancel()
    let source = RoutingRealtimeCaptureSource.subscription(subscription)
    let noChannels = UnsafeBufferPointer<UnsafeMutablePointer<Float>>(start: nil, count: 0)

    #expect(source.read(into: noChannels, frameCount: 1) == .insufficientChannels)
  }

  private func makeDistributor(
    maximumSubscriberCount: Int
  ) throws -> AudioRealtimeFrameDistributor {
    try AudioRealtimeFrameDistributor(
      format: AudioProcessingFormat(sampleRate: 48_000, channelCount: 1),
      capacityFrameCount: 32,
      maximumSubscriberCount: maximumSubscriberCount
    )
  }
}

private final class RoutingCaptureSessionIdentity: Sendable {}

/// A file's queue is audio still owed, not lag to be trimmed.
///
/// Its producer waits for the destination that reads it, so dropping the oldest frames bounds
/// nothing: it races the file forward and plays a few seconds of jumps in place of the recording.
@Suite("Capture source backlog")
struct RoutingCaptureSourceBacklogTests {
  private enum Fixture {
    static let sampleRate = 48_000.0
    static let quantum = 128
    static let capacity = 4_096
    static let queued = 2_048
    static let retained = quantum * 2
  }

  @Test("A live producer's backlog is dropped so latency stays bounded")
  func liveBacklogIsDropped() throws {
    let harness = try Harness()

    let discarded = RoutingRealtimeCaptureSource.frameBuffer(harness.buffer)
      .discardOldestFrames(keepingLatest: Fixture.retained)

    #expect(discarded == Fixture.queued - Fixture.retained)
    #expect(harness.buffer.statistics().availableFrameCount == Fixture.retained)
  }

  @Test("A throttled producer's backlog is left alone")
  func throttledBacklogSurvives() throws {
    let harness = try Harness()

    let discarded = RoutingRealtimeCaptureSource.throttledFrameBuffer(harness.buffer)
      .discardOldestFrames(keepingLatest: Fixture.retained)

    #expect(discarded == 0)
    #expect(harness.buffer.statistics().availableFrameCount == Fixture.queued)
  }

  /// The property that matters: every frame of the file reaches the destination, in order.
  @Test("Reading a throttled source yields the whole sequence without skipping")
  func throttledSourcePlaysEverySample() throws {
    let harness = try Harness()
    let source = RoutingRealtimeCaptureSource.throttledFrameBuffer(harness.buffer)

    var played: [Float] = []
    for _ in 0..<(Fixture.queued / Fixture.quantum) {
      source.discardOldestFrames(keepingLatest: Fixture.retained)
      #expect(harness.read(from: source) == .rendered)
      played.append(contentsOf: harness.rendered())
    }

    #expect(played == (0..<Fixture.queued).map { Float($0) })
  }

  /// The same walk over a live source is what the file was getting: it jumps to the newest frames
  /// and the recording between them is gone.
  @Test("Reading a live source skips ahead, which is why the two cannot share a case")
  func liveSourceSkipsAhead() throws {
    let harness = try Harness()
    let source = RoutingRealtimeCaptureSource.frameBuffer(harness.buffer)

    source.discardOldestFrames(keepingLatest: Fixture.retained)
    #expect(harness.read(from: source) == .rendered)

    #expect(harness.rendered().first == Float(Fixture.queued - Fixture.retained))
  }

  private struct Harness {
    let buffer: AudioRealtimeFrameBuffer
    private let output: [UnsafeMutablePointer<Float>]

    init() throws {
      buffer = try AudioRealtimeFrameBuffer(
        format: AudioProcessingFormat(sampleRate: Fixture.sampleRate, channelCount: 1),
        capacityFrameCount: Fixture.capacity
      )
      output = [UnsafeMutablePointer<Float>.allocate(capacity: Fixture.quantum)]
      output[0].initialize(repeating: 0, count: Fixture.quantum)

      // A ramp, so a skipped frame is visible as a gap in the numbers.
      let input = UnsafeMutablePointer<Float>.allocate(capacity: Fixture.queued)
      defer { input.deallocate() }
      for index in 0..<Fixture.queued { input[index] = Float(index) }
      let pointers = [UnsafePointer(input)]
      _ = pointers.withUnsafeBufferPointer {
        buffer.writePlanar($0, frameCount: Fixture.queued)
      }
    }

    func read(from source: RoutingRealtimeCaptureSource) -> AudioRenderResult {
      output.withUnsafeBufferPointer {
        source.read(into: $0, frameCount: Fixture.quantum)
      }
    }

    func rendered() -> [Float] {
      Array(UnsafeBufferPointer(start: output[0], count: Fixture.quantum))
    }
  }
}
