import CoreGraphics
import FlowingDayGraphCanvas
import Foundation
import RilliyaRealtime
import Testing

@testable import Rilliya

struct RoutingFileOutputControllerTests {
  @Test @MainActor
  func workflowLifecycleStartsAndStopsConfiguredFileOutput() async throws {
    let generatorID = UUID()
    let outputID = UUID()
    let starter = FileOutputTestStarter()
    let controller = RoutingFileOutputController(starter: starter)
    let workflow = try makeWorkflow(generatorID: generatorID, outputID: outputID)

    reconcile(controller, workflow: workflow)
    await Task.yield()
    #expect(await starter.startCount == 0)
    #expect(controller.state(for: outputID) == .idle)

    workflow.run()
    reconcile(controller, workflow: workflow)
    #expect(await eventually { controller.state(for: outputID).isRunning })
    #expect(await starter.startCount == 1)

    reconcile(controller, workflow: workflow)
    await Task.yield()
    #expect(await starter.startCount == 1)

    workflow.pause()
    reconcile(controller, workflow: workflow)
    #expect(await eventually { await starter.stopCount == 1 })
    #expect(await eventually { controller.state(for: outputID) == .idle })
  }

  @Test @MainActor
  func unconfiguredDestinationDoesNotStart() async throws {
    let generatorID = UUID()
    let outputID = UUID()
    let starter = FileOutputTestStarter()
    let controller = RoutingFileOutputController(starter: starter)
    let workflow = RoutingWorkflowModel(name: "Unconfigured Recording")
    _ = workflow.workspace.addSignalGeneratorNode(centeredAt: .zero, id: generatorID)
    _ = workflow.workspace.addFileOutputNode(
      centeredAt: CGPoint(x: 320, y: 0),
      id: outputID
    )
    try connect(sourceID: generatorID, targetID: outputID, in: workflow.workspace)
    workflow.run()

    reconcile(controller, workflow: workflow)
    await Task.yield()
    #expect(await starter.startCount == 0)
    #expect(controller.state(for: outputID) == .idle)
  }

  @MainActor
  private func makeWorkflow(
    generatorID: UUID,
    outputID: UUID
  ) throws -> RoutingWorkflowModel {
    let workflow = RoutingWorkflowModel(name: "Recording")
    _ = workflow.workspace.addSignalGeneratorNode(centeredAt: .zero, id: generatorID)
    _ = workflow.workspace.addFileOutputNode(
      centeredAt: CGPoint(x: 320, y: 0),
      id: outputID
    )
    var configuration = RoutingFileOutputConfiguration.initial
    let destination = URL(fileURLWithPath: "/tmp/Rilliya-Test-Recording.wav")
    configuration.destination = RoutingAudioFileDestination(
      url: destination,
      displayName: destination.lastPathComponent
    )
    workflow.workspace.configureFileOutput(configuration, for: outputID)
    try connect(sourceID: generatorID, targetID: outputID, in: workflow.workspace)
    return workflow
  }

  @MainActor
  private func reconcile(
    _ controller: RoutingFileOutputController,
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

private actor FileOutputTestStarter: RoutingFileOutputStarting {
  private(set) var startCount = 0
  private(set) var stopCount = 0

  func start(
    configuration: RoutingFileOutputConfiguration,
    rendererFactory:
      @escaping @Sendable (AudioRenderPreparation) throws ->
      RoutingPreparedAudioGraphSource,
    failureHandler: @escaping @Sendable (String) -> Void
  ) async throws -> any RoutingFileOutputSession {
    startCount += 1
    let preparation = try AudioRenderPreparation(
      format: AudioProcessingFormat(
        sampleRate: configuration.sampleRate,
        channelCount: configuration.channelCount
      ),
      maximumFrameCount: 32
    )
    _ = try rendererFactory(preparation)
    let url = try #require(configuration.destination?.url)
    return FileOutputTestSession(outputURL: url) { [self] in
      await recordStop()
    }
  }

  private func recordStop() {
    stopCount += 1
  }
}

private actor FileOutputTestSession: RoutingFileOutputSession {
  nonisolated let outputURL: URL

  private let stopHandler: @Sendable () async -> Void
  private var didStop = false

  init(outputURL: URL, stopHandler: @escaping @Sendable () async -> Void) {
    self.outputURL = outputURL
    self.stopHandler = stopHandler
  }

  func stop() async {
    guard !didStop else { return }
    didStop = true
    await stopHandler()
  }
}

extension RoutingFileOutputState {
  fileprivate var isRunning: Bool {
    guard case .running = self else { return false }
    return true
  }
}
