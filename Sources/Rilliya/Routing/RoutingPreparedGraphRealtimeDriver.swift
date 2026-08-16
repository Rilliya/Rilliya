import Foundation
import RilliyaRealtime

enum RoutingRealtimeDestinationDefaults {
  static let renderQuantumFrameCount = 128
}

/// Drives one prepared graph from a monotonic software clock into a bounded destination queue.
///
/// Storage is allocated once during initialization. The render loop performs no allocation and
/// never executes destination IO; the consumer must only copy into its own bounded realtime-safe
/// queue. Network transmission and file encoding run on their respective background consumers.
final class RoutingPreparedGraphRealtimeDriver: @unchecked Sendable {
  typealias Consumer =
    @Sendable (UnsafeBufferPointer<UnsafePointer<Float>>, Int) -> Void

  private let renderer: RoutingPreparedAudioGraphSource
  private let frameCount: Int
  private let channelStorage: [UnsafeMutablePointer<Float>]
  private let outputPointers: [UnsafeMutablePointer<Float>]
  private let inputPointers: [UnsafePointer<Float>]
  private let consumer: Consumer
  private let failureContext: String
  private let failureHandler: @Sendable (String) -> Void
  private let lock = NSLock()
  private var task: Task<Void, Never>?

  init(
    renderer: RoutingPreparedAudioGraphSource,
    frameCount: Int,
    failureContext: String,
    consumer: @escaping Consumer,
    failureHandler: @escaping @Sendable (String) -> Void
  ) {
    precondition((1...renderer.preparation.maximumFrameCount).contains(frameCount))
    self.renderer = renderer
    self.frameCount = frameCount
    self.failureContext = failureContext
    self.consumer = consumer
    self.failureHandler = failureHandler
    let storage = (0..<renderer.preparation.format.channelCount).map { _ in
      UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
    }
    channelStorage = storage
    outputPointers = storage
    inputPointers = storage.map { UnsafePointer($0) }
  }

  deinit {
    lock.withLock { task?.cancel() }
    for pointer in channelStorage { pointer.deallocate() }
  }

  func start() {
    lock.withLock {
      guard task == nil else { return }
      let renderer = renderer
      let frameCount = frameCount
      let outputPointers = outputPointers
      let inputPointers = inputPointers
      let consumer = consumer
      let failureContext = failureContext
      let failureHandler = failureHandler
      task = Task.detached(priority: .userInitiated) {
        let clock = ContinuousClock()
        let quantum = Duration.seconds(
          Double(frameCount) / renderer.preparation.format.sampleRate
        )
        var deadline = clock.now
        while !Task.isCancelled {
          let result = outputPointers.withUnsafeBufferPointer {
            renderer.render(outputChannels: $0, frameCount: frameCount)
          }
          guard result == .rendered else {
            failureHandler("The \(failureContext) graph rejected a render quantum: \(result).")
            return
          }
          inputPointers.withUnsafeBufferPointer {
            consumer($0, frameCount)
          }
          deadline += quantum
          if deadline < clock.now { deadline = clock.now }
          do {
            try await clock.sleep(until: deadline)
          } catch {
            return
          }
        }
      }
    }
  }

  func stop() async {
    let active = lock.withLock { () -> Task<Void, Never>? in
      let active = task
      task = nil
      return active
    }
    active?.cancel()
    await active?.value
  }
}
