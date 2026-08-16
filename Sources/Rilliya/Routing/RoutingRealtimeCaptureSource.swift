import Foundation
import RilliyaCapture
import RilliyaRealtime

enum RoutingCaptureCapacity {
  /// Seven destination clocks plus the legacy compatibility cursor stay within the distributor's
  /// aggregate storage budget even for the library's 256-channel upper bound.
  static let maximumIndependentDestinationCount = 7

  static let configuration = AudioCaptureConfiguration(
    maximumAdditionalFrameSubscriberCount: maximumIndependentDestinationCount
  )
}

/// One prepared realtime input cursor owned by exactly one destination clock.
///
/// Native captures use independent subscriptions. The frame-buffer case remains for sources that
/// already own a destination-local queue, such as file playback and network receive.
enum RoutingRealtimeCaptureSource: @unchecked Sendable {
  case frameBuffer(AudioRealtimeFrameBuffer)
  case subscription(AudioRealtimeFrameSubscription)

  var format: AudioProcessingFormat {
    switch self {
    case .frameBuffer(let frameBuffer): frameBuffer.format
    case .subscription(let subscription): subscription.format
    }
  }

  var capacityFrameCount: Int {
    switch self {
    case .frameBuffer(let frameBuffer): frameBuffer.capacityFrameCount
    case .subscription(let subscription): subscription.capacityFrameCount
    }
  }

  var identity: ObjectIdentifier {
    switch self {
    case .frameBuffer(let frameBuffer): ObjectIdentifier(frameBuffer)
    case .subscription(let subscription): ObjectIdentifier(subscription)
    }
  }

  var isActive: Bool {
    switch self {
    case .frameBuffer:
      true
    case .subscription(let subscription):
      subscription.statistics().isActive
    }
  }

  @discardableResult
  func discardOldestFrames(keepingLatest retainedFrameCount: Int) -> Int {
    switch self {
    case .frameBuffer(let frameBuffer):
      frameBuffer.discardOldestFrames(keepingLatest: retainedFrameCount)
    case .subscription(let subscription):
      subscription.discardOldestFrames(keepingLatest: retainedFrameCount)
    }
  }

  func read(
    into outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRenderResult {
    guard frameCount >= 0 else { return .invalidFrameCount }
    guard outputChannels.count >= format.channelCount else { return .insufficientChannels }
    switch self {
    case .frameBuffer(let frameBuffer):
      switch frameBuffer.read(into: outputChannels, frameCount: frameCount) {
      case .read: return .rendered
      case .invalidFrameCount: return .invalidFrameCount
      case .insufficientChannels: return .insufficientChannels
      }
    case .subscription(let subscription):
      switch subscription.read(into: outputChannels, frameCount: frameCount) {
      case .read: return .rendered
      case .inactive:
        for channel in 0..<min(outputChannels.count, format.channelCount) {
          outputChannels[channel].update(repeating: 0, count: max(frameCount, 0))
        }
        return .rendered
      case .invalidFrameCount: return .invalidFrameCount
      case .insufficientChannels: return .insufficientChannels
      }
    }
  }
}

struct RoutingCaptureCursorKey: Hashable, Sendable {
  let consumerID: UUID
  let captureSessionIdentity: ObjectIdentifier
}

struct RoutingCaptureCursorCache {
  private var sources: [RoutingCaptureCursorKey: RoutingRealtimeCaptureSource] = [:]

  mutating func source(
    consumerID: UUID,
    captureSessionIdentity: ObjectIdentifier,
    makeSource: () throws -> RoutingRealtimeCaptureSource?
  ) throws -> (key: RoutingCaptureCursorKey, source: RoutingRealtimeCaptureSource)? {
    let key = RoutingCaptureCursorKey(
      consumerID: consumerID,
      captureSessionIdentity: captureSessionIdentity
    )
    if let source = sources[key], source.isActive {
      return (key, source)
    }
    sources[key] = nil
    guard let source = try makeSource() else { return nil }
    sources[key] = source
    return (key, source)
  }

  mutating func retain(_ activeKeys: Set<RoutingCaptureCursorKey>) {
    sources = sources.filter { activeKeys.contains($0.key) }
  }

  mutating func removeAll() {
    sources.removeAll()
  }
}

@MainActor
protocol RoutingCaptureSourceProviding: AnyObject {
  func captureSessionIdentity(for nodeID: UUID) -> ObjectIdentifier?
  func captureSource(for nodeID: UUID) throws -> RoutingRealtimeCaptureSource?
}

extension RoutingCaptureController: RoutingCaptureSourceProviding {}
extension RoutingInputCaptureController: RoutingCaptureSourceProviding {}
extension RoutingOutputCaptureController: RoutingCaptureSourceProviding {}

extension RoutingCaptureCursorCache {
  @MainActor
  mutating func source(
    for nodeID: UUID,
    consumerID: UUID,
    provider: any RoutingCaptureSourceProviding
  ) throws -> (key: RoutingCaptureCursorKey, source: RoutingRealtimeCaptureSource)? {
    guard let identity = provider.captureSessionIdentity(for: nodeID) else { return nil }
    return try source(
      consumerID: consumerID,
      captureSessionIdentity: identity,
      makeSource: { try provider.captureSource(for: nodeID) }
    )
  }

  @MainActor
  mutating func resolvedSource(
    for nodeID: UUID,
    consumerID: UUID,
    provider: any RoutingCaptureSourceProviding,
    activeKeys: inout Set<RoutingCaptureCursorKey>,
    failureMessage: inout String?
  ) -> RoutingRealtimeCaptureSource? {
    do {
      guard
        let cached = try source(
          for: nodeID,
          consumerID: consumerID,
          provider: provider
        )
      else { return nil }
      activeKeys.insert(cached.key)
      return cached.source
    } catch {
      failureMessage = error.localizedDescription
      return nil
    }
  }
}
