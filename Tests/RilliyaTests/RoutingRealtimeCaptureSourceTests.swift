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
