import Foundation
import RilliyaNetworkAudio
import RilliyaRealtime
import Testing

@testable import Rilliya

struct RoutingNetworkReceiveControllerTests {
  private enum Fixture {
    static let port: UInt16 = 48_620
    static let alternatePort: UInt16 = 48_621
    static let sampleRate = 48_000.0
    static let channelCount = 2
    static let reconcileAttempts = 5

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

  @Test @MainActor
  func reconcileOpensAndClosesAListener() async throws {
    let nodeID = UUID()
    let starter = NetworkReceiveTestStarter()
    let controller = RoutingNetworkReceiveController(starter: starter)

    controller.reconcile(requirements: [nodeID: Fixture.configuration])
    #expect(await eventually { controller.state(for: nodeID).isRunning })
    #expect(await starter.startCount == 1)
    #expect(controller.frameBuffer(for: nodeID) != nil)

    controller.reconcile(requirements: [:])
    #expect(await eventually { await starter.stopCount == 1 })
    #expect(controller.state(for: nodeID) == .idle)
    #expect(controller.frameBuffer(for: nodeID) == nil)
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
    #expect(controller.frameBuffer(for: first) === controller.frameBuffer(for: second))
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

private enum NetworkReceiveTestError: Error, LocalizedError {
  case portUnavailable

  var errorDescription: String? { "The network audio listener port is unavailable." }
}

private actor NetworkReceiveTestStarter: RoutingNetworkReceiveStarting {
  private(set) var startCount = 0
  private(set) var stopCount = 0

  private let failure: (any Error)?

  init(failsWith failure: (any Error)? = nil) {
    self.failure = failure
  }

  func start(
    configuration: RoutingNetworkReceiveConfiguration,
    failureHandler: @escaping @Sendable (NetworkAudioReceiverError) -> Void
  ) async throws -> any RoutingNetworkReceiveSession {
    startCount += 1
    if let failure { throw failure }
    let format = try NetworkAudioStreamFormat(
      sampleRate: configuration.sampleRate,
      channelCount: configuration.channelCount
    )
    let frameBuffer = try AudioRealtimeFrameBuffer(
      format: AudioProcessingFormat(
        sampleRate: configuration.sampleRate,
        channelCount: configuration.channelCount
      )
    )
    return NetworkReceiveTestSession(format: format, frameBuffer: frameBuffer) { [self] in
      await recordStop()
    }
  }

  private func recordStop() {
    stopCount += 1
  }
}

private actor NetworkReceiveTestSession: RoutingNetworkReceiveSession {
  nonisolated let format: NetworkAudioStreamFormat
  nonisolated let frameBuffer: AudioRealtimeFrameBuffer

  private let stopHandler: @Sendable () async -> Void
  private var didStop = false

  init(
    format: NetworkAudioStreamFormat,
    frameBuffer: AudioRealtimeFrameBuffer,
    stopHandler: @escaping @Sendable () async -> Void
  ) {
    self.format = format
    self.frameBuffer = frameBuffer
    self.stopHandler = stopHandler
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
