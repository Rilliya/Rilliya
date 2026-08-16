import CoreGraphics
import FlowingDayGraphCanvas
import Foundation
import RilliyaNetworkAudio
import RilliyaRealtime
import Testing

@testable import Rilliya

struct RoutingNetworkSendControllerTests {
  private enum Fixture {
    static let host = "10.0.0.2"
    static let port: UInt16 = 48_620
    static let sampleRate = 48_000.0
    static let channelCount = 2
    static let generatorOrigin = CGPoint.zero
    static let sendOrigin = CGPoint(x: 320, y: 0)
    static let reconcileAttempts = 5
  }

  @Test @MainActor
  func workflowLifecycleStartsAndStopsConfiguredNetworkSend() async throws {
    let sendID = UUID()
    let starter = NetworkSendTestStarter()
    let controller = RoutingNetworkSendController(starter: starter)
    let workflow = try makeWorkflow(sendID: sendID)

    reconcile(controller, workflow: workflow)
    await Task.yield()
    #expect(await starter.startCount == 0)
    #expect(controller.state(for: sendID) == .idle)

    workflow.run()
    reconcile(controller, workflow: workflow)
    #expect(await eventually { controller.state(for: sendID).isRunning })
    #expect(await starter.startCount == 1)

    workflow.pause()
    reconcile(controller, workflow: workflow)
    #expect(await eventually { await starter.stopCount == 1 })
    #expect(await eventually { controller.state(for: sendID) == .idle })
  }

  /// Reconciliation reruns whenever any observed audio state changes, so a failure that restarts
  /// on an unchanged plan spins the node between starting and failed.
  @Test @MainActor
  func aFailedStartDoesNotRestartOnAnUnchangedPlan() async throws {
    let sendID = UUID()
    let starter = NetworkSendTestStarter(failsWith: NetworkSendTestError.unavailable)
    let controller = RoutingNetworkSendController(starter: starter)
    let workflow = try makeWorkflow(sendID: sendID)
    workflow.run()

    reconcile(controller, workflow: workflow)
    #expect(await eventually { controller.state(for: sendID).isFailed })
    #expect(await starter.startCount == 1)

    for _ in 0..<Fixture.reconcileAttempts {
      reconcile(controller, workflow: workflow)
      await Task.yield()
    }

    #expect(controller.state(for: sendID).isFailed)
    #expect(await starter.startCount == 1)
  }

  @Test @MainActor
  func retryRestartsALatchedFailure() async throws {
    let sendID = UUID()
    let starter = NetworkSendTestStarter(failsWith: NetworkSendTestError.unavailable)
    let controller = RoutingNetworkSendController(starter: starter)
    let workflow = try makeWorkflow(sendID: sendID)
    workflow.run()

    reconcile(controller, workflow: workflow)
    #expect(await eventually { controller.state(for: sendID).isFailed })

    controller.retry(nodeID: sendID)
    reconcile(controller, workflow: workflow)

    #expect(await eventually { await starter.startCount == 2 })
  }

  @Test @MainActor
  func editingTheConfigurationRestartsALatchedFailure() async throws {
    let sendID = UUID()
    let starter = NetworkSendTestStarter(failsWith: NetworkSendTestError.unavailable)
    let controller = RoutingNetworkSendController(starter: starter)
    let workflow = try makeWorkflow(sendID: sendID)
    workflow.run()

    reconcile(controller, workflow: workflow)
    #expect(await eventually { controller.state(for: sendID).isFailed })
    #expect(await starter.startCount == 1)

    workflow.workspace.configureNetworkSend(
      RoutingNetworkSendConfiguration(
        host: Fixture.host,
        port: Fixture.port + 1,
        sampleRate: Fixture.sampleRate,
        channelCount: Fixture.channelCount
      ),
      for: sendID
    )
    reconcile(controller, workflow: workflow)

    #expect(await eventually { await starter.startCount == 2 })
  }

  @MainActor
  private func makeWorkflow(sendID: UUID) throws -> RoutingWorkflowModel {
    let generatorID = UUID()
    let workflow = RoutingWorkflowModel(name: "Stream")
    _ = workflow.workspace.addSignalGeneratorNode(
      centeredAt: Fixture.generatorOrigin,
      id: generatorID
    )
    _ = workflow.workspace.addNetworkSendNode(centeredAt: Fixture.sendOrigin, id: sendID)
    workflow.workspace.configureNetworkSend(
      RoutingNetworkSendConfiguration(
        host: Fixture.host,
        port: Fixture.port,
        sampleRate: Fixture.sampleRate,
        channelCount: Fixture.channelCount
      ),
      for: sendID
    )
    try connect(sourceID: generatorID, targetID: sendID, in: workflow.workspace)
    return workflow
  }

  @MainActor
  private func reconcile(
    _ controller: RoutingNetworkSendController,
    workflow: RoutingWorkflowModel
  ) {
    controller.reconcile(
      workflows: [workflow],
      captureController: RoutingCaptureController(),
      inputCaptureController: RoutingInputCaptureController(),
      filePlaybackController: RoutingFilePlaybackController(),
      networkReceiveController: RoutingNetworkReceiveController()
    )
  }

  @MainActor
  private func connect(
    sourceID: UUID,
    targetID: UUID,
    in workspace: RoutingWorkspaceModel
  ) throws {
    let content = try #require(workspace.canvasContent)
    let source = try #require(
      content.presentation.ports.first {
        guard case .port(let key) = $0.address.elementID else { return false }
        return key.nodeID == sourceID && $0.value.direction == .output
      })
    let target = try #require(
      content.presentation.ports.first {
        guard case .port(let key) = $0.address.elementID else { return false }
        return key.nodeID == targetID && $0.value.direction == .input
      })
    workspace.send(
      .connectionCompleted(
        FlowingGraphCanvasConnectionCompletionIntent(
          operation: .create(sourcePortID: source.id, targetPortID: target.id),
          basePresentationSnapshotID: content.presentation.snapshotID,
          baseLayoutInputID: content.id
        )
      )
    )
  }

  @MainActor
  private func eventually(_ predicate: @MainActor () async -> Bool) async -> Bool {
    for _ in 0..<200 where !(await predicate()) { await Task.yield() }
    return await predicate()
  }
}

private enum NetworkSendTestError: Error, LocalizedError {
  case unavailable

  var errorDescription: String? { "The network audio destination is unavailable." }
}

private actor NetworkSendTestStarter: RoutingNetworkSendStarting {
  private(set) var startCount = 0
  private(set) var stopCount = 0

  private let failure: (any Error)?

  init(failsWith failure: (any Error)? = nil) {
    self.failure = failure
  }

  func start(
    configuration: RoutingNetworkSendConfiguration,
    rendererFactory:
      @escaping @Sendable (AudioRenderPreparation) throws ->
      RoutingPreparedAudioGraphSource,
    failureHandler: @escaping @Sendable (String) -> Void
  ) async throws -> any RoutingNetworkSendSession {
    startCount += 1
    if let failure { throw failure }
    let format = try NetworkAudioStreamFormat(
      sampleRate: configuration.sampleRate,
      channelCount: configuration.channelCount
    )
    let preparation = try AudioRenderPreparation(
      format: AudioProcessingFormat(
        sampleRate: configuration.sampleRate,
        channelCount: configuration.channelCount
      ),
      maximumFrameCount: RoutingRealtimeDestinationDefaults.renderQuantumFrameCount
    )
    _ = try rendererFactory(preparation)
    return NetworkSendTestSession(format: format) { [self] in
      await recordStop()
    }
  }

  private func recordStop() {
    stopCount += 1
  }
}

private actor NetworkSendTestSession: RoutingNetworkSendSession {
  nonisolated let format: NetworkAudioStreamFormat

  private let stopHandler: @Sendable () async -> Void
  private var didStop = false

  init(format: NetworkAudioStreamFormat, stopHandler: @escaping @Sendable () async -> Void) {
    self.format = format
    self.stopHandler = stopHandler
  }

  func stop() async {
    guard !didStop else { return }
    didStop = true
    await stopHandler()
  }
}

extension RoutingNetworkSendState {
  fileprivate var isRunning: Bool {
    guard case .running = self else { return false }
    return true
  }

  fileprivate var isFailed: Bool {
    guard case .failed = self else { return false }
    return true
  }
}
