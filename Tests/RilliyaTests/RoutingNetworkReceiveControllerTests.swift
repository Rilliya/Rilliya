import Foundation
import RilliyaCore
import RilliyaNetworkAudio
import RilliyaRealtime
import Testing
import os.lock
@testable import Rilliya

struct RoutingNetworkReceiveControllerTests {
  private enum Fixture {
    static let port: UInt16 = 48_620
    static let alternatePort: UInt16 = 48_621
    static let sampleRate = 48_000.0
    static let channelCount = 2
    static let reconcileAttempts = 5

    /// What a running receiver's meter would report.
    static func meterChannels(rootMeanSquare: Float) -> [AudioChannelMeterSnapshot] {
      let owner = AudioChannelOwnerID.source(.stream(UUID()))
      return (0..<channelCount).compactMap { index in
        AudioChannelIndex(rawValue: index).map { channelIndex in
          AudioChannelMeterSnapshot(
            channelID: AudioChannelID(ownerID: owner, index: channelIndex),
            rootMeanSquare: rootMeanSquare,
            peak: rootMeanSquare * 2,
            decibels: -12,
            isClipping: false,
            waveform: (0..<32).map { _ in rootMeanSquare }
          )
        }
      }
    }

    static var configuration: RoutingNetworkReceiveConfiguration {
      RoutingNetworkReceiveConfiguration(
        port: port,
        sampleRate: sampleRate,
        channelCount: channelCount
      )
    }

    static var alternateConfiguration: RoutingNetworkReceiveConfiguration {
      RoutingNetworkReceiveConfiguration(
        port: alternatePort,
        sampleRate: sampleRate,
        channelCount: channelCount
      )
    }
  }

  /// A waveform is drawn when the interface is told it changed.
  ///
  /// Reading the meter on demand made it look right in a test and move about once every ten
  /// seconds on screen: nothing marked the node as changed, so nothing redrew it. What a running
  /// receiver reports has to land in state the interface observes.
  @Test @MainActor
  func aNewWaveformReachesObservedState() async throws {
    let nodeID = UUID()
    let starter = NetworkReceiveTestStarter()
    let controller = RoutingNetworkReceiveController(starter: starter)

    controller.reconcile(requirements: [nodeID: Fixture.configuration])
    #expect(await eventually { controller.state(for: nodeID).isRunning })
    #expect(controller.snapshot(for: nodeID) == nil, "nothing has been reported yet")

    let session = try #require(await starter.lastSession)
    session.publish(Fixture.meterChannels(rootMeanSquare: 0.4))
    #expect(await eventually { controller.snapshot(for: nodeID) != nil })
    let first = try #require(controller.snapshot(for: nodeID))
    #expect(first.channels.count == 2)
    #expect(first.channels.first?.rootMeanSquare == 0.4)

    // A later interval replaces it, which is what makes a waveform move.
    session.publish(Fixture.meterChannels(rootMeanSquare: 0.1))
    #expect(
      await eventually { controller.snapshot(for: nodeID)?.channels.first?.rootMeanSquare == 0.1 }
    )

    // And a node that stops stops being drawn.
    controller.reconcile(requirements: [:])
    #expect(await eventually { controller.snapshot(for: nodeID) == nil })
  }

  @Test @MainActor
  func reconcileOpensAndClosesAListener() async throws {
    let nodeID = UUID()
    let starter = NetworkReceiveTestStarter()
    let controller = RoutingNetworkReceiveController(starter: starter)

    controller.reconcile(requirements: [nodeID: Fixture.configuration])
    #expect(await eventually { controller.state(for: nodeID).isRunning })
    #expect(await starter.startCount == 1)
    let whileRunning = try controller.captureSource(for: nodeID)
    #expect(whileRunning != nil)

    controller.reconcile(requirements: [:])
    #expect(await eventually { await starter.stopCount == 1 })
    #expect(controller.state(for: nodeID) == .idle)
    let afterStop = try controller.captureSource(for: nodeID)
    #expect(afterStop == nil)
  }

  @Test @MainActor
  func nodesSharingAConfigurationShareOneListener() async throws {
    let first = UUID()
    let second = UUID()
    let starter = NetworkReceiveTestStarter()
    let controller = RoutingNetworkReceiveController(starter: starter)

    controller.reconcile(
      requirements: [first: Fixture.configuration, second: Fixture.configuration]
    )

    #expect(await eventually { controller.state(for: second).isRunning })
    #expect(await starter.startCount == 1)
    #expect(controller.captureSessionIdentity(for: first) == controller.captureSessionIdentity(for: second))
  }

  /// The shape the canvas depends on: one stream, several destinations, each reading its own.
  ///
  /// Two nodes sharing one listener used to share one queue as well, so whichever destination read
  /// first took the audio away and the second could only be refused.
  @Test @MainActor
  func destinationsOfOneStreamEachGetTheirOwnQueue() async throws {
    let first = UUID()
    let second = UUID()
    let controller = RoutingNetworkReceiveController(starter: NetworkReceiveTestStarter())

    controller.reconcile(
      requirements: [first: Fixture.configuration, second: Fixture.configuration]
    )
    #expect(await eventually { controller.state(for: second).isRunning })

    let one = try #require(try controller.captureSource(for: first))
    let other = try #require(try controller.captureSource(for: second))
    #expect(one.identity != other.identity, "two destinations were handed the same queue")

    // Asking twice for one node is two destinations too: a node feeds an output and a recording
    // from the same stream, and each of those reads on its own clock.
    let again = try #require(try controller.captureSource(for: first))
    #expect(again.identity != one.identity, "one node's second destination reused the first's queue")
  }

  /// A graph rebuild must not spend a destination, or a running stream stops after a few of them.
  ///
  /// Rebuilds happen whenever anything observed changes, which includes the meter many times a
  /// second. Claiming a fresh destination each time exhausts the stream in under a second and every
  /// output falls back to waiting for a source it will never be handed.
  @Test @MainActor
  func repeatedRebuildsDoNotSpendDestinations() async throws {
    let sourceNode = UUID()
    let consumer = UUID()
    let controller = RoutingNetworkReceiveController(starter: NetworkReceiveTestStarter())
    controller.reconcile(requirements: [sourceNode: Fixture.configuration])
    #expect(await eventually { controller.state(for: sourceNode).isRunning })

    var cache = RoutingCaptureCursorCache()
    var identities: Set<ObjectIdentifier> = []
    for _ in 0..<50 {
      var activeKeys = Set<RoutingCaptureCursorKey>()
      var failure: RoutingNodeFailure?
      let source = cache.resolvedSource(
        for: sourceNode,
        consumerID: consumer,
        provider: controller,
        activeKeys: &activeKeys,
        failure: &failure
      )
      #expect(failure == nil, "a rebuild ran out of destinations: \(failure as Any)")
      identities.insert(try #require(source).identity)
      cache.retain(activeKeys)
    }

    #expect(identities.count == 1, "one consumer was handed \(identities.count) destinations")

    // And the resource really is finite, so reusing it is what makes the loop above possible
    // rather than the stream simply having no limit worth respecting.
    var claims: [RoutingRealtimeCaptureSource] = []
    var ranOut = false
    for _ in 0..<50 {
      do {
        guard let claim = try controller.captureSource(for: sourceNode) else { break }
        claims.append(claim)
      } catch {
        ranOut = true
        break
      }
    }
    #expect(ranOut, "claiming a destination per rebuild never ran out, so nothing was proven")
  }

  /// Reconciliation reruns whenever any observed audio state changes, so a failure that reopens
  /// on an unchanged configuration spins the node between starting and failed.
  @Test @MainActor
  func aFailedStartDoesNotReopenOnAnUnchangedConfiguration() async throws {
    let nodeID = UUID()
    let starter = NetworkReceiveTestStarter(failsWith: NetworkReceiveTestError.portUnavailable)
    let controller = RoutingNetworkReceiveController(starter: starter)

    controller.reconcile(requirements: [nodeID: Fixture.configuration])
    #expect(await eventually { controller.state(for: nodeID).isFailed })
    #expect(await starter.startCount == 1)

    for _ in 0..<Fixture.reconcileAttempts {
      controller.reconcile(requirements: [nodeID: Fixture.configuration])
      await Task.yield()
    }

    #expect(controller.state(for: nodeID).isFailed)
    #expect(await starter.startCount == 1)
  }

  @Test @MainActor
  func retryReopensALatchedFailure() async throws {
    let nodeID = UUID()
    let starter = NetworkReceiveTestStarter(failsWith: NetworkReceiveTestError.portUnavailable)
    let controller = RoutingNetworkReceiveController(starter: starter)

    controller.reconcile(requirements: [nodeID: Fixture.configuration])
    #expect(await eventually { controller.state(for: nodeID).isFailed })

    controller.retry(nodeID: nodeID)
    controller.reconcile(requirements: [nodeID: Fixture.configuration])

    #expect(await eventually { await starter.startCount == 2 })
  }

  @Test @MainActor
  func editingTheConfigurationReopensALatchedFailure() async throws {
    let nodeID = UUID()
    let starter = NetworkReceiveTestStarter(failsWith: NetworkReceiveTestError.portUnavailable)
    let controller = RoutingNetworkReceiveController(starter: starter)

    controller.reconcile(requirements: [nodeID: Fixture.configuration])
    #expect(await eventually { controller.state(for: nodeID).isFailed })
    #expect(await starter.startCount == 1)

    controller.reconcile(requirements: [nodeID: Fixture.alternateConfiguration])

    #expect(await eventually { await starter.startCount == 2 })
  }

  @MainActor
  private func eventually(_ predicate: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<200 where !(await predicate()) { await Task.yield() }
    return await predicate()
  }
}

/// The receiver default, which is large enough for the jitter buffer ceiling.
private let receiverCapacityFrameCount = 32_768

private enum NetworkReceiveTestError: Error, LocalizedError {
  case portUnavailable

  var errorDescription: String? { "The network audio listener port is unavailable." }
}

private actor NetworkReceiveTestStarter: RoutingNetworkReceiveStarting {
  private(set) var startCount = 0
  private(set) var stopCount = 0

  private let failure: (any Error)?

  /// The session handed out most recently, so a test can drive its meter.
  private(set) var lastSession: NetworkReceiveTestSession?

  init(failsWith failure: (any Error)? = nil) {
    self.failure = failure
  }

  func start(
    configuration: RoutingNetworkReceiveConfiguration,
    waveformUpdatesPerSecond: Int,
    failureHandler: @escaping @Sendable (NetworkAudioReceiverError) -> Void
  ) async throws -> any RoutingNetworkReceiveSession {
    startCount += 1
    if let failure { throw failure }
    let format = try NetworkAudioStreamFormat(
      sampleRate: configuration.sampleRate,
      channelCount: configuration.channelCount
    )
    let distributor = try AudioRealtimeFrameDistributor(
      format: AudioProcessingFormat(
        sampleRate: configuration.sampleRate,
        channelCount: configuration.channelCount
      ),
      capacityFrameCount: receiverCapacityFrameCount,
      maximumSubscriberCount: 4
    )
    let session = NetworkReceiveTestSession(format: format, distributor: distributor) { [self] in
      await recordStop()
    }
    lastSession = session
    return session
  }

  private func recordStop() {
    stopCount += 1
  }
}

private actor NetworkReceiveTestSession: RoutingNetworkReceiveSession {
  nonisolated let format: NetworkAudioStreamFormat
  nonisolated let distributor: AudioRealtimeFrameDistributor
  /// What a fake stream sounds like, which the tests here do not exercise.
  nonisolated let meterChannels: [AudioChannelMeterSnapshot]
  private let handler = OSAllocatedUnfairLock<
    (@Sendable ([AudioChannelMeterSnapshot]) -> Void)?
  >(initialState: nil)

  private let stopHandler: @Sendable () async -> Void
  private var didStop = false

  init(
    format: NetworkAudioStreamFormat,
    distributor: AudioRealtimeFrameDistributor,
    meterChannels: [AudioChannelMeterSnapshot] = [],
    stopHandler: @escaping @Sendable () async -> Void
  ) {
    self.format = format
    self.distributor = distributor
    self.meterChannels = meterChannels
    self.stopHandler = stopHandler
  }

  nonisolated func subscribeWithJitterBuffer() throws -> AudioJitterBuffer {
    try distributor.subscribeWithJitterBuffer()
  }

  nonisolated func meterSnapshot() -> [AudioChannelMeterSnapshot] { meterChannels }

  nonisolated func onMeter(_ handler: (@Sendable ([AudioChannelMeterSnapshot]) -> Void)?) {
    self.handler.withLock { $0 = handler }
  }

  /// Pretends a new interval arrived, as a running receiver's meter would.
  nonisolated func publish(_ channels: [AudioChannelMeterSnapshot]) {
    handler.withLock { $0 }?(channels)
  }

  func stop() async {
    guard !didStop else { return }
    didStop = true
    await stopHandler()
  }
}

extension RoutingNetworkReceiveState {
  fileprivate var isRunning: Bool {
    guard case .running = self else { return false }
    return true
  }

  fileprivate var isFailed: Bool {
    guard case .failed = self else { return false }
    return true
  }
}
