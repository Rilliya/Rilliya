import Foundation
import RilliyaKit
import Testing

@testable import Rilliya

struct RoutingCaptureControllerTests {
  @Test @MainActor
  func nodesFollowingTheSameProcessShareOneCapture() async throws {
    let processID = try #require(AudioProcessID(rawValue: 81))
    let starter = FakeRoutingProcessCaptureStarter()
    let controller = RoutingCaptureController(captureStarter: starter)
    let firstNodeID = UUID()
    let secondNodeID = UUID()

    controller.start(nodeID: firstNodeID, processID: processID)
    controller.start(nodeID: secondNodeID, processID: processID)

    let bothRunning = await eventually {
      guard case .running = controller.state(for: firstNodeID),
        case .running = controller.state(for: secondNodeID)
      else {
        return false
      }
      return true
    }
    #expect(bothRunning)
    let startCount = await starter.startCount(for: processID)
    #expect(startCount == 1)
    #expect(controller.consumerCount(for: firstNodeID) == 2)
    #expect(controller.consumerCount(for: secondNodeID) == 2)

    let snapshot = try makeSnapshot(processID: processID, sequence: 7)
    await starter.emit(snapshot)
    let bothReceivedSnapshot = await eventually {
      controller.snapshot(for: firstNodeID) == snapshot
        && controller.snapshot(for: secondNodeID) == snapshot
    }
    #expect(bothReceivedSnapshot)

    controller.stop(nodeID: firstNodeID)
    await Task.yield()
    let intermediateStopCount = await starter.stopCount(for: processID)
    #expect(intermediateStopCount == 0)
    #expect(controller.state(for: firstNodeID) == .idle)
    guard case .running = controller.state(for: secondNodeID) else {
      Issue.record("The remaining consumer should keep the shared capture running")
      return
    }
    #expect(controller.consumerCount(for: secondNodeID) == 1)

    controller.stop(nodeID: secondNodeID)
    let stoppedAfterLastConsumer = await eventually {
      await starter.stopCount(for: processID) == 1
    }
    #expect(stoppedAfterLastConsumer)
  }

  @Test @MainActor
  func separateProcessesCreateSeparateCaptures() async throws {
    let firstProcessID = try #require(AudioProcessID(rawValue: 91))
    let secondProcessID = try #require(AudioProcessID(rawValue: 92))
    let starter = FakeRoutingProcessCaptureStarter()
    let controller = RoutingCaptureController(captureStarter: starter)

    controller.start(nodeID: UUID(), processID: firstProcessID)
    controller.start(nodeID: UUID(), processID: secondProcessID)

    let bothStarted = await eventually {
      let firstCount = await starter.startCount(for: firstProcessID)
      let secondCount = await starter.startCount(for: secondProcessID)
      return firstCount == 1 && secondCount == 1
    }
    #expect(bothStarted)
  }

  @Test @MainActor
  func workflowSwitchingDoesNotStopASharedBackgroundCapture() async throws {
    let processID = try #require(AudioProcessID(rawValue: 96))
    let starter = FakeRoutingProcessCaptureStarter()
    let controller = RoutingCaptureController(captureStarter: starter)
    let library = RoutingWorkflowLibrary()
    let firstWorkflow = library.selectedWorkflow
    let firstNodeID = firstWorkflow.workspace.addApplicationAudioNode(centeredAt: .zero)
    let secondWorkflow = library.addWorkflow()
    let secondNodeID = secondWorkflow.workspace.addApplicationAudioNode(centeredAt: .zero)

    controller.start(nodeID: firstNodeID, processID: processID)
    controller.start(nodeID: secondNodeID, processID: processID)
    library.selectWorkflow(id: firstWorkflow.id)
    library.selectWorkflow(id: secondWorkflow.id)

    let bothRunning = await eventually {
      controller.state(for: firstNodeID).isRunning
        && controller.state(for: secondNodeID).isRunning
    }
    #expect(bothRunning)
    let startCount = await starter.startCount(for: processID)
    let stopCount = await starter.stopCount(for: processID)
    #expect(startCount == 1)
    #expect(stopCount == 0)
    #expect(controller.consumerCount(for: firstNodeID) == 2)

    controller.stopAll()
    let stopped = await eventually {
      await starter.stopCount(for: processID) == 1
    }
    #expect(stopped)
  }

  @Test @MainActor
  func oneSharedStartFailureIsPublishedToEveryConsumer() async throws {
    let processID = try #require(AudioProcessID(rawValue: 101))
    let starter = FakeRoutingProcessCaptureStarter(failingProcessIDs: [processID])
    let controller = RoutingCaptureController(captureStarter: starter)
    let firstNodeID = UUID()
    let secondNodeID = UUID()

    controller.start(nodeID: firstNodeID, processID: processID)
    controller.start(nodeID: secondNodeID, processID: processID)

    let bothFailed = await eventually {
      guard case .failed = controller.state(for: firstNodeID),
        case .failed = controller.state(for: secondNodeID)
      else {
        return false
      }
      return true
    }
    #expect(bothFailed)
    let startCount = await starter.startCount(for: processID)
    #expect(startCount == 1)
    #expect(controller.consumerCount(for: firstNodeID) == 0)
    #expect(controller.consumerCount(for: secondNodeID) == 0)
  }

  @Test @MainActor
  func reattachingDuringTeardownWaitsBeforeStartingAReplacement() async throws {
    let processID = try #require(AudioProcessID(rawValue: 111))
    let starter = FakeRoutingProcessCaptureStarter(suspendsStops: true)
    let controller = RoutingCaptureController(captureStarter: starter)
    let firstNodeID = UUID()
    let secondNodeID = UUID()

    controller.start(nodeID: firstNodeID, processID: processID)
    let firstStarted = await eventually {
      await starter.startCount(for: processID) == 1
        && controller.state(for: firstNodeID).isRunning
    }
    #expect(firstStarted)

    controller.stop(nodeID: firstNodeID)
    let teardownStarted = await eventually {
      await starter.stopCount(for: processID) == 1
    }
    #expect(teardownStarted)

    controller.start(nodeID: secondNodeID, processID: processID)
    await Task.yield()
    let countWhileStopping = await starter.startCount(for: processID)
    #expect(countWhileStopping == 1)
    #expect(controller.state(for: secondNodeID) == .starting)

    await starter.resumeStops(for: processID)
    let replacementStarted = await eventually {
      await starter.startCount(for: processID) == 2
        && controller.state(for: secondNodeID).isRunning
    }
    #expect(replacementStarted)

    await starter.setSuspendsStops(false)
    controller.stop(nodeID: secondNodeID)
    let replacementStopped = await eventually {
      await starter.stopCount(for: processID) == 2
    }
    #expect(replacementStopped)
  }

  private func makeSnapshot(
    processID: AudioProcessID,
    sequence: UInt64
  ) throws -> ProcessOutputMeterSnapshot {
    let channelIndex = try #require(AudioChannelIndex(rawValue: 0))
    let channelID = AudioChannelID(
      ownerID: .source(.processOutput(processID)),
      index: channelIndex
    )
    let format = ProcessOutputCaptureFormat(
      processID: processID,
      sampleRate: 48_000,
      channelIDs: [channelID]
    )
    return ProcessOutputMeterSnapshot(
      format: format,
      sequence: sequence,
      frameCount: 2,
      channels: [
        AudioChannelMeterSnapshot(
          channelID: channelID,
          rootMeanSquare: 0.25,
          peak: 0.5,
          decibels: -12,
          isClipping: false,
          waveform: [0.25, -0.5]
        )
      ]
    )
  }

  @MainActor
  private func eventually(
    _ predicate: @MainActor () async -> Bool
  ) async -> Bool {
    for _ in 0..<100 where !(await predicate()) {
      await Task.yield()
    }
    return await predicate()
  }
}

private enum FakeCaptureError: Error {
  case requestedFailure
  case invalidChannelIndex
}

private actor FakeRoutingProcessCaptureStarter: RoutingProcessCaptureStarting {
  private var startCounts: [AudioProcessID: Int] = [:]
  private var stopCounts: [AudioProcessID: Int] = [:]
  private var snapshotHandlers: [AudioProcessID: ProcessOutputCapture.SnapshotHandler] = [:]
  private var stopContinuations: [AudioProcessID: [CheckedContinuation<Void, Never>]] = [:]
  private let failingProcessIDs: Set<AudioProcessID>
  private var suspendsStops: Bool

  init(
    failingProcessIDs: Set<AudioProcessID> = [],
    suspendsStops: Bool = false
  ) {
    self.failingProcessIDs = failingProcessIDs
    self.suspendsStops = suspendsStops
  }

  func start(
    processID: AudioProcessID,
    snapshotHandler: @escaping ProcessOutputCapture.SnapshotHandler
  ) async throws -> any RoutingProcessCaptureSession {
    startCounts[processID, default: 0] += 1
    if failingProcessIDs.contains(processID) {
      throw FakeCaptureError.requestedFailure
    }
    guard let channelIndex = AudioChannelIndex(rawValue: 0) else {
      throw FakeCaptureError.invalidChannelIndex
    }
    snapshotHandlers[processID] = snapshotHandler
    let format = ProcessOutputCaptureFormat(
      processID: processID,
      sampleRate: 48_000,
      channelIDs: [
        AudioChannelID(
          ownerID: .source(.processOutput(processID)),
          index: channelIndex
        )
      ]
    )
    return FakeRoutingProcessCaptureSession(format: format) { [self] in
      await recordStop(for: processID)
    }
  }

  func startCount(for processID: AudioProcessID) -> Int {
    startCounts[processID, default: 0]
  }

  func stopCount(for processID: AudioProcessID) -> Int {
    stopCounts[processID, default: 0]
  }

  func emit(_ snapshot: ProcessOutputMeterSnapshot) {
    snapshotHandlers[snapshot.format.processID]?(snapshot)
  }

  func setSuspendsStops(_ suspendsStops: Bool) {
    self.suspendsStops = suspendsStops
  }

  func resumeStops(for processID: AudioProcessID) {
    let continuations = stopContinuations.removeValue(forKey: processID) ?? []
    for continuation in continuations {
      continuation.resume()
    }
  }

  private func recordStop(for processID: AudioProcessID) async {
    stopCounts[processID, default: 0] += 1
    if suspendsStops {
      await withCheckedContinuation { continuation in
        stopContinuations[processID, default: []].append(continuation)
      }
    }
    snapshotHandlers[processID] = nil
  }
}

private actor FakeRoutingProcessCaptureSession: RoutingProcessCaptureSession {
  nonisolated let format: ProcessOutputCaptureFormat

  private let stopHandler: @Sendable () async -> Void
  private var isStopped = false

  init(
    format: ProcessOutputCaptureFormat,
    stopHandler: @escaping @Sendable () async -> Void
  ) {
    self.format = format
    self.stopHandler = stopHandler
  }

  func stop() async {
    guard !isStopped else { return }
    isStopped = true
    await stopHandler()
  }
}

extension RoutingCaptureState {
  fileprivate var isRunning: Bool {
    guard case .running = self else { return false }
    return true
  }
}
