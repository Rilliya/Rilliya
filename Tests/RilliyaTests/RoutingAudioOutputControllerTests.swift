import CoreGraphics
import FlowingDayGraphCanvas
import Foundation
import RilliyaCapture
import RilliyaCore
import RilliyaPlayback
import RilliyaRealtime
import RilliyaVirtualAudio
import Testing

@testable import Rilliya

struct RoutingAudioOutputControllerTests {
  @Test @MainActor
  func controlUpdatesKeepOutputRunningAndTopologyReplacementWaitsForStop() async throws {
    let processID = try #require(AudioProcessID(rawValue: 141))
    let sourceID = UUID()
    let outputID = UUID()
    let captureStarter = OutputTestCaptureStarter()
    let captureController = RoutingCaptureController(captureStarter: captureStarter)
    let inputController = RoutingInputCaptureController()
    let outputStarter = OutputTestPlaybackStarter(suspendsStops: true)
    let outputController = RoutingAudioOutputController(playbackStarter: outputStarter)
    let workflow = try makeWorkflow(sourceID: sourceID, outputIDs: [outputID])
    workflow.run()

    captureController.start(nodeID: sourceID, processID: processID)
    #expect(await eventually { captureController.frameBuffer(for: sourceID) != nil })

    outputController.reconcile(
      workflows: [workflow],
      captureController: captureController,
      inputCaptureController: inputController
    )
    #expect(await eventually { outputController.state(for: outputID).isRunning })
    #expect(await outputStarter.startCount == 1)

    outputController.reconcile(
      workflows: [workflow],
      captureController: captureController,
      inputCaptureController: inputController
    )
    await Task.yield()
    #expect(await outputStarter.startCount == 1)
    #expect(await outputStarter.stopCount == 0)

    workflow.workspace.setAudioChannelGain(-6, nodeID: sourceID, channelIndex: 0)
    outputController.reconcile(
      workflows: [workflow],
      captureController: captureController,
      inputCaptureController: inputController
    )
    await Task.yield()
    #expect(await outputStarter.startCount == 1)
    #expect(await outputStarter.stopCount == 0)

    workflow.workspace.setApplicationChannelPresentation(
      .separate(channelCount: 1),
      for: sourceID
    )
    outputController.reconcile(
      workflows: [workflow],
      captureController: captureController,
      inputCaptureController: inputController
    )
    #expect(await eventually { await outputStarter.stopCount == 1 })
    #expect(await outputStarter.startCount == 1)

    await outputStarter.resumeStops()
    #expect(
      await eventually {
        await outputStarter.startCount == 2
          && outputController.state(for: outputID).isRunning
      }
    )

    await outputStarter.setSuspendsStops(false)
    outputController.stopAll()
    captureController.stopAll()
  }

  @Test @MainActor
  func noiseGateControlUpdatesDoNotRestartOutputPlayback() async throws {
    let generatorID = UUID()
    let gateID = UUID()
    let outputID = UUID()
    let outputStarter = OutputTestPlaybackStarter()
    let outputController = RoutingAudioOutputController(playbackStarter: outputStarter)
    let captureController = RoutingCaptureController(captureStarter: OutputTestCaptureStarter())
    let inputController = RoutingInputCaptureController()
    let workflow = RoutingWorkflowModel(name: "Live Gate")
    _ = workflow.workspace.addSignalGeneratorNode(centeredAt: .zero, id: generatorID)
    _ = workflow.workspace.addNoiseGateNode(
      centeredAt: CGPoint(x: 300, y: 0),
      id: gateID
    )
    _ = workflow.workspace.addOutputAudioNode(
      centeredAt: CGPoint(x: 600, y: 0),
      id: outputID
    )
    let deviceID = try #require(AudioDeviceID(rawValue: "test.output"))
    workflow.workspace.selectOutputDevice(
      RoutingOutputDeviceSelection(id: deviceID, displayName: "Test Output"),
      for: outputID
    )
    try connect(sourceID: generatorID, targetID: gateID, in: workflow.workspace)
    try connect(sourceID: gateID, targetID: outputID, in: workflow.workspace)
    workflow.run()

    outputController.reconcile(
      workflows: [workflow],
      captureController: captureController,
      inputCaptureController: inputController
    )
    #expect(await eventually { outputController.state(for: outputID).isRunning })
    #expect(await outputStarter.startCount == 1)

    workflow.workspace.configureNoiseGate(
      RoutingNoiseGateConfiguration(
        thresholdDecibels: -32,
        hysteresisDecibels: 8,
        attackSeconds: 0.01,
        holdSeconds: 0.08,
        releaseSeconds: 0.2,
        reductionDecibels: 48
      ),
      for: gateID
    )
    outputController.reconcile(
      workflows: [workflow],
      captureController: captureController,
      inputCaptureController: inputController
    )
    await Task.yield()

    #expect(await outputStarter.startCount == 1)
    #expect(await outputStarter.stopCount == 0)
    #expect(outputController.state(for: outputID).isRunning)

    outputController.stopAll()
  }

  @Test @MainActor
  func compressorControlUpdatesDoNotRestartOutputPlayback() async throws {
    let generatorID = UUID()
    let compressorID = UUID()
    let outputID = UUID()
    let outputStarter = OutputTestPlaybackStarter()
    let outputController = RoutingAudioOutputController(playbackStarter: outputStarter)
    let captureController = RoutingCaptureController(captureStarter: OutputTestCaptureStarter())
    let inputController = RoutingInputCaptureController()
    let workflow = RoutingWorkflowModel(name: "Live Compressor")
    _ = workflow.workspace.addSignalGeneratorNode(centeredAt: .zero, id: generatorID)
    _ = workflow.workspace.addCompressorNode(
      centeredAt: CGPoint(x: 300, y: 0),
      id: compressorID
    )
    _ = workflow.workspace.addOutputAudioNode(
      centeredAt: CGPoint(x: 600, y: 0),
      id: outputID
    )
    let deviceID = try #require(AudioDeviceID(rawValue: "test.output"))
    workflow.workspace.selectOutputDevice(
      RoutingOutputDeviceSelection(id: deviceID, displayName: "Test Output"),
      for: outputID
    )
    try connect(sourceID: generatorID, targetID: compressorID, in: workflow.workspace)
    try connect(sourceID: compressorID, targetID: outputID, in: workflow.workspace)
    workflow.run()

    outputController.reconcile(
      workflows: [workflow],
      captureController: captureController,
      inputCaptureController: inputController
    )
    #expect(await eventually { outputController.state(for: outputID).isRunning })
    #expect(await outputStarter.startCount == 1)

    workflow.workspace.configureCompressor(
      RoutingCompressorConfiguration(
        thresholdDecibels: -28,
        ratio: 6,
        kneeDecibels: 8,
        attackSeconds: 0.02,
        releaseSeconds: 0.3,
        makeupGainDecibels: 2
      ),
      for: compressorID
    )
    outputController.reconcile(
      workflows: [workflow],
      captureController: captureController,
      inputCaptureController: inputController
    )
    await Task.yield()

    #expect(await outputStarter.startCount == 1)
    #expect(await outputStarter.stopCount == 0)
    #expect(outputController.state(for: outputID).isRunning)

    outputController.stopAll()
  }

  @Test @MainActor
  func gainControlUpdatesDoNotRestartOutputPlayback() async throws {
    let generatorID = UUID()
    let gainID = UUID()
    let outputID = UUID()
    let outputStarter = OutputTestPlaybackStarter()
    let outputController = RoutingAudioOutputController(playbackStarter: outputStarter)
    let captureController = RoutingCaptureController(captureStarter: OutputTestCaptureStarter())
    let inputController = RoutingInputCaptureController()
    let workflow = RoutingWorkflowModel(name: "Live Gain")
    _ = workflow.workspace.addSignalGeneratorNode(centeredAt: .zero, id: generatorID)
    _ = workflow.workspace.addGainNode(centeredAt: CGPoint(x: 300, y: 0), id: gainID)
    _ = workflow.workspace.addOutputAudioNode(
      centeredAt: CGPoint(x: 600, y: 0),
      id: outputID
    )
    let deviceID = try #require(AudioDeviceID(rawValue: "test.output"))
    workflow.workspace.selectOutputDevice(
      RoutingOutputDeviceSelection(id: deviceID, displayName: "Test Output"),
      for: outputID
    )
    try connect(sourceID: generatorID, targetID: gainID, in: workflow.workspace)
    try connect(sourceID: gainID, targetID: outputID, in: workflow.workspace)
    workflow.run()

    outputController.reconcile(
      workflows: [workflow],
      captureController: captureController,
      inputCaptureController: inputController
    )
    #expect(await eventually { outputController.state(for: outputID).isRunning })
    #expect(await outputStarter.startCount == 1)

    workflow.workspace.configureGain(
      RoutingGainConfiguration(
        gainDecibels: -18,
        isMuted: false,
        isPolarityInverted: true
      ),
      for: gainID
    )
    outputController.reconcile(
      workflows: [workflow],
      captureController: captureController,
      inputCaptureController: inputController
    )
    await Task.yield()

    #expect(await outputStarter.startCount == 1)
    #expect(await outputStarter.stopCount == 0)
    #expect(outputController.state(for: outputID).isRunning)

    outputController.stopAll()
  }

  @Test @MainActor
  func sharedCaptureFeedsTwoOutputClocksThroughIndependentSubscriptions() async throws {
    let processID = try #require(AudioProcessID(rawValue: 142))
    let sourceID = UUID()
    let firstOutputID = UUID()
    let secondOutputID = UUID()
    let captureController = RoutingCaptureController(captureStarter: OutputTestCaptureStarter())
    let inputController = RoutingInputCaptureController()
    let outputStarter = OutputTestPlaybackStarter()
    let outputController = RoutingAudioOutputController(playbackStarter: outputStarter)
    let workflow = try makeWorkflow(
      sourceID: sourceID,
      outputIDs: [firstOutputID, secondOutputID]
    )
    workflow.run()

    captureController.start(nodeID: sourceID, processID: processID)
    #expect(await eventually { captureController.frameBuffer(for: sourceID) != nil })
    outputController.reconcile(
      workflows: [workflow],
      captureController: captureController,
      inputCaptureController: inputController
    )

    #expect(await eventually { await outputStarter.startCount == 2 })
    let states = [
      outputController.state(for: firstOutputID),
      outputController.state(for: secondOutputID),
    ]
    let allOutputsAreRunning = states.allSatisfy { $0.isRunning }
    #expect(allOutputsAreRunning)

    outputController.stopAll()
    captureController.stopAll()
  }

  @Test @MainActor
  func systemOutputCannotRouteBackToTheSamePhysicalDevice() async throws {
    let deviceID = try #require(AudioDeviceID(rawValue: "test.feedback-output"))
    let sourceID = UUID()
    let outputID = UUID()
    let outputCaptureController = RoutingOutputCaptureController(
      captureStarter: FeedbackOutputCaptureStarter()
    )
    let outputStarter = OutputTestPlaybackStarter()
    let outputController = RoutingAudioOutputController(playbackStarter: outputStarter)
    let workflow = RoutingWorkflowModel(name: "Feedback Guard")
    _ = workflow.workspace.addSystemOutputNode(centeredAt: .zero, id: sourceID)
    _ = workflow.workspace.addOutputAudioNode(
      centeredAt: CGPoint(x: 400, y: 0),
      id: outputID
    )
    workflow.workspace.selectSystemOutput(
      .device(RoutingOutputDeviceSelection(id: deviceID, displayName: "Same Device")),
      for: sourceID
    )
    workflow.workspace.selectOutputDevice(
      RoutingOutputDeviceSelection(id: deviceID, displayName: "Same Device"),
      for: outputID
    )
    try connect(sourceID: sourceID, targetID: outputID, in: workflow.workspace)
    workflow.run()

    outputCaptureController.reconcile(
      deviceIDsByNode: [sourceID: deviceID],
      catalogRevision: 1
    )
    #expect(await eventually { outputCaptureController.frameBuffer(for: sourceID) != nil })

    outputController.reconcile(
      workflows: [workflow],
      captureController: RoutingCaptureController(captureStarter: OutputTestCaptureStarter()),
      inputCaptureController: RoutingInputCaptureController(),
      outputCaptureController: outputCaptureController
    )

    #expect(
      await eventually {
        guard case .failed(let message) = outputController.state(for: outputID) else {
          return false
        }
        return message.contains("same physical output device")
      }
    )
    #expect(await outputStarter.startCount == 0)
    outputCaptureController.stopAll()
  }

  @Test @MainActor
  func workflowRunStateGatesDemandDrivenSignalGenerationAndOutput() async throws {
    let outputID = UUID()
    let outputStarter = OutputTestPlaybackStarter()
    let outputController = RoutingAudioOutputController(playbackStarter: outputStarter)
    let workflow = RoutingWorkflowModel(name: "Tone")
    let generatorID = workflow.workspace.addSignalGeneratorNode(centeredAt: .zero)
    _ = workflow.workspace.addOutputAudioNode(
      centeredAt: CGPoint(x: 400, y: 0),
      id: outputID
    )
    let deviceID = try #require(AudioDeviceID(rawValue: "test.output"))
    workflow.workspace.selectOutputDevice(
      RoutingOutputDeviceSelection(id: deviceID, displayName: "Test Output"),
      for: outputID
    )
    try connect(sourceID: generatorID, targetID: outputID, in: workflow.workspace)
    let captureController = RoutingCaptureController(captureStarter: OutputTestCaptureStarter())
    let inputController = RoutingInputCaptureController()

    outputController.reconcile(
      workflows: [workflow],
      captureController: captureController,
      inputCaptureController: inputController
    )
    await Task.yield()
    #expect(await outputStarter.startCount == 0)
    #expect(outputController.state(for: outputID) == .idle)

    workflow.run()
    outputController.reconcile(
      workflows: [workflow],
      captureController: captureController,
      inputCaptureController: inputController
    )
    #expect(await eventually { outputController.state(for: outputID).isRunning })
    #expect(await outputStarter.startCount == 1)

    workflow.pause()
    outputController.reconcile(
      workflows: [workflow],
      captureController: captureController,
      inputCaptureController: inputController
    )
    #expect(await eventually { await outputStarter.stopCount == 1 })
    #expect(await eventually { outputController.state(for: outputID) == .idle })
  }

  @Test @MainActor
  func virtualInputPlaysIntoItsStableHiddenFeederDevice() async throws {
    let endpointID = VirtualAudioEndpointID(
      rawValue: try #require(UUID(uuidString: "E27B64B0-ACDC-41AB-AC5D-CF9EBE789205"))
    )
    let endpoint = VirtualAudioEndpoint(
      id: endpointID,
      configuration: try VirtualAudioEndpointConfiguration(
        name: "Shared Microphone",
        direction: .input,
        format: VirtualAudioEndpointFormat(sampleRate: 48_000, channelCount: 2)
      )
    )
    let catalog = try VirtualAudioEndpointCatalog(revision: 2, endpoints: [endpoint])
    let expectedDeviceID = try #require(AudioDeviceID(rawValue: endpoint.deviceUIDs.hostBridge))
    let outputStarter = OutputTestPlaybackStarter()
    let outputController = RoutingAudioOutputController(playbackStarter: outputStarter)
    let workflow = RoutingWorkflowModel(name: "Virtual Microphone")
    let generatorID = workflow.workspace.addSignalGeneratorNode(centeredAt: .zero)
    let outputID = workflow.workspace.addVirtualInputNode(
      centeredAt: CGPoint(x: 400, y: 0)
    )
    workflow.workspace.selectVirtualInput(
      RoutingVirtualAudioEndpointSelection(
        id: endpoint.id,
        displayName: endpoint.configuration.name
      ),
      for: outputID
    )
    try connect(sourceID: generatorID, targetID: outputID, in: workflow.workspace)
    workflow.run()

    outputController.reconcile(
      workflows: [workflow],
      captureController: RoutingCaptureController(captureStarter: OutputTestCaptureStarter()),
      inputCaptureController: RoutingInputCaptureController(),
      virtualAudioCatalog: catalog
    )

    let didStart = await eventually { await outputStarter.startCount == 1 }
    #expect(
      didStart,
      "Expected playback to start; final state: \(String(reflecting: outputController.state(for: outputID)))"
    )
    let startedDeviceID = await outputStarter.lastStartedDeviceID
    let startCount = await outputStarter.startCount
    let finalState = outputController.state(for: outputID)
    #expect(
      startedDeviceID != nil,
      "Expected a completed playback start; final state: \(String(reflecting: finalState))"
    )
    #expect(startedDeviceID == expectedDeviceID)
    #expect(startCount == 1)
    outputController.stopAll()
  }

  @MainActor
  private func makeWorkflow(
    sourceID: UUID,
    outputIDs: [UUID]
  ) throws -> RoutingWorkflowModel {
    let workflow = RoutingWorkflowModel(name: "Output")
    _ = workflow.workspace.addApplicationAudioNode(centeredAt: .zero, id: sourceID)
    for (index, outputID) in outputIDs.enumerated() {
      _ = workflow.workspace.addOutputAudioNode(
        centeredAt: CGPoint(x: 400, y: CGFloat(index * 180)),
        id: outputID
      )
      let deviceID = try #require(AudioDeviceID(rawValue: "output-\(index)"))
      workflow.workspace.selectOutputDevice(
        RoutingOutputDeviceSelection(id: deviceID, displayName: "Output \(index + 1)"),
        for: outputID
      )
      try connect(sourceID: sourceID, targetID: outputID, in: workflow.workspace)
    }
    return workflow
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
    for _ in 0..<1_000 where !(await predicate()) {
      try? await Task.sleep(for: .milliseconds(1))
    }
    return await predicate()
  }
}

private actor OutputTestCaptureStarter: RoutingProcessCaptureStarting {
  func start(
    processID: AudioProcessID,
    muteBehavior: ProcessOutputCaptureMuteBehavior,
    snapshotHandler: @escaping ProcessOutputCapture.SnapshotHandler
  ) async throws -> any RoutingProcessCaptureSession {
    let channelIndex = try #require(AudioChannelIndex(rawValue: 0))
    let format = ProcessOutputCaptureFormat(
      processID: processID,
      sampleRate: 48_000,
      channelIDs: [
        AudioChannelID(ownerID: .source(.processOutput(processID)), index: channelIndex)
      ]
    )
    return try OutputTestCaptureSession(
      format: format,
      frameBuffer: AudioRealtimeFrameBuffer(
        format: AudioProcessingFormat(sampleRate: 48_000, channelCount: 1)
      )
    )
  }
}

private actor FeedbackOutputCaptureStarter: RoutingOutputCaptureStarting {
  func start(
    deviceID: AudioDeviceID,
    snapshotHandler: @escaping DeviceOutputCapture.SnapshotHandler
  ) async throws -> any RoutingOutputCaptureSession {
    let channelIndex = try #require(AudioChannelIndex(rawValue: 0))
    let streamIndex = try #require(AudioStreamIndex(rawValue: 0))
    let format = DeviceOutputCaptureFormat(
      deviceID: deviceID,
      streamIndex: streamIndex,
      sampleRate: 48_000,
      channelIDs: [
        AudioChannelID(ownerID: .source(.deviceOutput(deviceID)), index: channelIndex)
      ]
    )
    return try FeedbackOutputCaptureSession(
      format: format,
      frameBuffer: AudioRealtimeFrameBuffer(
        format: AudioProcessingFormat(sampleRate: 48_000, channelCount: 1)
      )
    )
  }
}

private final class FeedbackOutputCaptureSession: RoutingOutputCaptureSession,
  @unchecked Sendable
{
  let format: DeviceOutputCaptureFormat
  let frameBuffer: AudioRealtimeFrameBuffer

  init(format: DeviceOutputCaptureFormat, frameBuffer: AudioRealtimeFrameBuffer) {
    self.format = format
    self.frameBuffer = frameBuffer
  }

  func stop() async {}
}

private final class OutputTestCaptureSession: RoutingProcessCaptureSession,
  @unchecked Sendable
{
  let format: ProcessOutputCaptureFormat
  let frameBuffer: AudioRealtimeFrameBuffer
  private let distributor: AudioRealtimeFrameDistributor

  init(format: ProcessOutputCaptureFormat, frameBuffer: AudioRealtimeFrameBuffer) throws {
    self.format = format
    self.frameBuffer = frameBuffer
    distributor = try AudioRealtimeFrameDistributor(
      format: frameBuffer.format,
      capacityFrameCount: frameBuffer.capacityFrameCount,
      maximumSubscriberCount: RoutingCaptureCapacity.maximumIndependentDestinationCount
    )
  }

  func subscribeToFrames() throws -> AudioRealtimeFrameSubscription? {
    try distributor.subscribe()
  }

  func stop() async {}
}

private actor OutputTestPlaybackStarter: RoutingOutputPlaybackStarting {
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private var suspendsStops: Bool
  private var stopContinuations: [CheckedContinuation<Void, Never>] = []
  private var startedDeviceIDs: [AudioDeviceID] = []

  var lastStartedDeviceID: AudioDeviceID? {
    startedDeviceIDs.last
  }

  init(suspendsStops: Bool = false) {
    self.suspendsStops = suspendsStops
  }

  func start(
    deviceID: AudioDeviceID,
    rendererFactory: @escaping DeviceOutputPlayback.RendererFactory,
    failureHandler: @escaping DeviceOutputPlayback.FailureHandler
  ) async throws -> any RoutingOutputPlaybackSession {
    startCount += 1
    let preparation = try AudioRenderPreparation(
      format: AudioProcessingFormat(sampleRate: 48_000, channelCount: 1),
      maximumFrameCount: 32
    )
    _ = try rendererFactory(preparation)
    let session = OutputTestPlaybackSession(
      format: DeviceOutputPlaybackFormat(
        deviceID: deviceID,
        sampleRate: 48_000,
        channelIDs: [],
        maximumFrameCount: 32
      )
    ) { [self] in
      await stop()
    }
    startedDeviceIDs.append(deviceID)
    return session
  }

  func setSuspendsStops(_ value: Bool) {
    suspendsStops = value
  }

  func resumeStops() {
    let continuations = stopContinuations
    stopContinuations.removeAll()
    for continuation in continuations {
      continuation.resume()
    }
  }

  private func stop() async {
    stopCount += 1
    if suspendsStops {
      await withCheckedContinuation { continuation in
        stopContinuations.append(continuation)
      }
    }
  }
}

private actor OutputTestPlaybackSession: RoutingOutputPlaybackSession {
  nonisolated let format: DeviceOutputPlaybackFormat

  private let stopHandler: @Sendable () async -> Void
  private var didStop = false

  init(
    format: DeviceOutputPlaybackFormat,
    stopHandler: @escaping @Sendable () async -> Void
  ) {
    self.format = format
    self.stopHandler = stopHandler
  }

  func stop() async {
    guard !didStop else { return }
    didStop = true
    await stopHandler()
  }
}

extension RoutingAudioOutputState {
  fileprivate var isRunning: Bool {
    guard case .running = self else { return false }
    return true
  }
}
