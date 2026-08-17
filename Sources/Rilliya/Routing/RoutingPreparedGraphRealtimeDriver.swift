import Atomics
import Foundation
import RilliyaRealtime

enum RoutingRealtimeDestinationDefaults {
  static let renderQuantumFrameCount = 128

  /// The processing time one render quantum is expected to need.
  ///
  /// Declaring a budget and its deadline two to one is the only pairing the kernel stores
  /// verbatim; anything smaller is raised to half the deadline.
  static let renderComputationBudget = Duration.microseconds(300)

  /// How often the driver checks whether its worker stopped on a render failure.
  static let failurePollInterval = Duration.milliseconds(200)
}

/// Drives one prepared graph on a deadline-scheduled thread into a bounded destination queue.
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
  private let cadence: AudioRealtimeCadence
  private let budget: AudioRealtimeBudget
  private let renderFailure = ManagedAtomic<Int>(0)
  private let lock = NSLock()
  private var worker: AudioRealtimeWorker?
  private var failureWatcher: Task<Void, Never>?

  init(
    renderer: RoutingPreparedAudioGraphSource,
    frameCount: Int,
    failureContext: String,
    consumer: @escaping Consumer,
    failureHandler: @escaping @Sendable (String) -> Void
  ) throws {
    precondition((1...renderer.preparation.maximumFrameCount).contains(frameCount))
    self.renderer = renderer
    self.frameCount = frameCount
    self.failureContext = failureContext
    self.consumer = consumer
    self.failureHandler = failureHandler
    cadence = try AudioRealtimeCadence(
      framesPerCycle: frameCount,
      sampleRate: renderer.preparation.format.sampleRate
    )
    budget = try AudioRealtimeBudget.matching(
      computation: RoutingRealtimeDestinationDefaults.renderComputationBudget
    )
    let storage = (0..<renderer.preparation.format.channelCount).map { _ in
      UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
    }
    channelStorage = storage
    outputPointers = storage
    inputPointers = storage.map { UnsafePointer($0) }
  }

  deinit {
    worker?.stop()
    failureWatcher?.cancel()
    for pointer in channelStorage { pointer.deallocate() }
  }

  func start() throws {
    try lock.withLock {
      guard worker == nil else { return }
      let renderer = renderer
      let frameCount = frameCount
      nonisolated(unsafe) let outputPointers = outputPointers
      nonisolated(unsafe) let inputPointers = inputPointers
      let consumer = consumer
      let renderFailure = renderFailure
      let worker = AudioRealtimeWorker(
        label: "moe.uwucocoa.rilliya.\(failureContext)",
        cadence: cadence,
        budget: budget
      ) { _ in
        let result = outputPointers.withUnsafeBufferPointer {
          renderer.render(outputChannels: $0, frameCount: frameCount)
        }
        guard result == .rendered else {
          // Reporting from here would allocate, so the watcher turns this into a message.
          renderFailure.store(result.diagnosticCode, ordering: .relaxed)
          return .stop
        }
        inputPointers.withUnsafeBufferPointer {
          consumer($0, frameCount)
        }
        return .continue
      }
      try worker.start()
      self.worker = worker
      failureWatcher = makeFailureWatcher()
    }
  }

  func stop() async {
    let stopping = lock.withLock { () -> (AudioRealtimeWorker?, Task<Void, Never>?) in
      let stopping = (worker, failureWatcher)
      worker = nil
      failureWatcher = nil
      return stopping
    }
    stopping.1?.cancel()
    stopping.0?.stop()
    await stopping.1?.value
  }

  private func makeFailureWatcher() -> Task<Void, Never> {
    let renderFailure = renderFailure
    let failureContext = failureContext
    let failureHandler = failureHandler
    let interval = RoutingRealtimeDestinationDefaults.failurePollInterval
    return Task.detached(priority: .utility) {
      while !Task.isCancelled {
        let code = renderFailure.load(ordering: .relaxed)
        if code != 0 {
          failureHandler(
            "The \(failureContext) graph rejected a render quantum: "
              + "\(AudioRenderResult(diagnosticCode: code).map(String.init(describing:)) ?? "unknown")."
          )
          return
        }
        try? await Task.sleep(for: interval)
      }
    }
  }
}

extension AudioRenderResult {
  /// A nonzero code the render thread can publish without allocating.
  fileprivate var diagnosticCode: Int {
    switch self {
    case .rendered: 0
    case .invalidFrameCount: 1
    case .insufficientChannels: 2
    }
  }

  fileprivate init?(diagnosticCode: Int) {
    switch diagnosticCode {
    case 1: self = .invalidFrameCount
    case 2: self = .insufficientChannels
    default: return nil
    }
  }
}
