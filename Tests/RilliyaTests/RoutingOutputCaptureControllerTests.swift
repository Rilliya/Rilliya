import Foundation
import RilliyaCapture
import RilliyaCore
import RilliyaRealtime
import Testing

@testable import Rilliya

struct RoutingOutputCaptureControllerTests {
  @Test @MainActor
  func nodesUsingTheSameResolvedDeviceShareOneCaptureAndSnapshot() async throws {
    let deviceID = try #require(AudioDeviceID(rawValue: "test.output"))
    let starter = FakeRoutingOutputCaptureStarter()
    let controller = RoutingOutputCaptureController(captureStarter: starter)
    let firstNodeID = UUID()
    let secondNodeID = UUID()

    controller.reconcile(
      deviceIDsByNode: [firstNodeID: deviceID, secondNodeID: deviceID],
      catalogRevision: 1
    )

    #expect(
      await eventually {
        guard case .running = controller.state(for: firstNodeID),
          case .running = controller.state(for: secondNodeID)
        else { return false }
        return true
      }
    )
    #expect(await starter.startCount(for: deviceID) == 1)
    #expect(controller.consumerCount(for: firstNodeID) == 2)
    #expect(controller.frameBuffer(for: firstNodeID) === controller.frameBuffer(for: secondNodeID))

    let snapshot = try makeSnapshot(deviceID: deviceID)
    await starter.emit(snapshot)
    #expect(
      await eventually {
        controller.snapshot(for: firstNodeID) == snapshot
          && controller.snapshot(for: secondNodeID) == snapshot
      }
    )

    controller.stop(nodeID: firstNodeID)
    #expect(await starter.stopCount(for: deviceID) == 0)
    controller.stop(nodeID: secondNodeID)
    #expect(await eventually { await starter.stopCount(for: deviceID) == 1 })
  }

  @Test @MainActor
  func changingOneResolvedDefaultKeepsPinnedConsumersOnTheOldDevice() async throws {
    let oldDeviceID = try #require(AudioDeviceID(rawValue: "test.output.old"))
    let newDeviceID = try #require(AudioDeviceID(rawValue: "test.output.new"))
    let starter = FakeRoutingOutputCaptureStarter()
    let controller = RoutingOutputCaptureController(captureStarter: starter)
    let followingNodeID = UUID()
    let pinnedNodeID = UUID()

    controller.reconcile(
      deviceIDsByNode: [followingNodeID: oldDeviceID, pinnedNodeID: oldDeviceID],
      catalogRevision: 1
    )
    #expect(
      await eventually {
        if case .running = controller.state(for: pinnedNodeID) { return true }
        return false
      }
    )

    controller.reconcile(
      deviceIDsByNode: [followingNodeID: newDeviceID, pinnedNodeID: oldDeviceID],
      catalogRevision: 2
    )

    #expect(
      await eventually {
        guard case .running(let followingFormat) = controller.state(for: followingNodeID),
          case .running(let pinnedFormat) = controller.state(for: pinnedNodeID)
        else { return false }
        return followingFormat.deviceID == newDeviceID && pinnedFormat.deviceID == oldDeviceID
      }
    )
    #expect(await starter.startCount(for: oldDeviceID) == 1)
    #expect(await starter.startCount(for: newDeviceID) == 1)
    #expect(await starter.stopCount(for: oldDeviceID) == 0)
    #expect(controller.consumerCount(for: pinnedNodeID) == 1)
  }

  @Test @MainActor
  func failedCaptureDoesNotRetryUntilCatalogChangesOrTheUserRetries() async throws {
    let deviceID = try #require(AudioDeviceID(rawValue: "test.output.failure"))
    let starter = FakeRoutingOutputCaptureStarter(failingDeviceIDs: [deviceID])
    let controller = RoutingOutputCaptureController(captureStarter: starter)
    let nodeID = UUID()

    controller.reconcile(deviceIDsByNode: [nodeID: deviceID], catalogRevision: 7)
    #expect(
      await eventually {
        if case .failed = controller.state(for: nodeID) { return true }
        return false
      }
    )
    #expect(await starter.startCount(for: deviceID) == 1)

    controller.reconcile(deviceIDsByNode: [nodeID: deviceID], catalogRevision: 7)
    await Task.yield()
    #expect(await starter.startCount(for: deviceID) == 1)

    controller.reconcile(deviceIDsByNode: [nodeID: deviceID], catalogRevision: 8)
    #expect(
      await eventually {
        await starter.startCount(for: deviceID) == 2
          && controller.state(for: nodeID) == .failed("The fake output capture failed.")
      }
    )

    await starter.setFails(false, for: deviceID)
    controller.retry(nodeID: nodeID)
    #expect(
      await eventually {
        if case .running = controller.state(for: nodeID) { return true }
        return false
      }
    )
    #expect(await starter.startCount(for: deviceID) == 3)
  }

  @Test @MainActor
  func failedStartAfterLastConsumerDetachesDoesNotLeaveAStaleFailure() async throws {
    let deviceID = try #require(AudioDeviceID(rawValue: "test.output.detached-failure"))
    let starter = FakeRoutingOutputCaptureStarter(failingDeviceIDs: [deviceID])
    let controller = RoutingOutputCaptureController(captureStarter: starter)
    let detachedNodeID = UUID()
    let replacementNodeID = UUID()

    controller.reconcile(deviceIDsByNode: [detachedNodeID: deviceID], catalogRevision: 4)
    controller.stop(nodeID: detachedNodeID)
    #expect(await eventually { await starter.startCount(for: deviceID) == 1 })
    for _ in 0..<20 {
      await Task.yield()
    }

    await starter.setFails(false, for: deviceID)
    controller.reconcile(deviceIDsByNode: [replacementNodeID: deviceID], catalogRevision: 4)

    #expect(
      await eventually {
        if case .running = controller.state(for: replacementNodeID) { return true }
        return false
      }
    )
    #expect(await starter.startCount(for: deviceID) == 2)
  }

  private func makeSnapshot(deviceID: AudioDeviceID) throws -> DeviceOutputMeterSnapshot {
    let channelID = AudioChannelID(
      ownerID: .source(.deviceOutput(deviceID)),
      index: try #require(AudioChannelIndex(rawValue: 0))
    )
    let format = DeviceOutputCaptureFormat(
      deviceID: deviceID,
      streamIndex: try #require(AudioStreamIndex(rawValue: 0)),
      sampleRate: 48_000,
      channelIDs: [channelID]
    )
    return DeviceOutputMeterSnapshot(
      format: format,
      sequence: 1,
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

private actor FakeRoutingOutputCaptureStarter: RoutingOutputCaptureStarting {
  private var startCounts: [AudioDeviceID: Int] = [:]
  private var stopCounts: [AudioDeviceID: Int] = [:]
  private var snapshotHandlers: [AudioDeviceID: DeviceOutputCapture.SnapshotHandler] = [:]
  private var failingDeviceIDs: Set<AudioDeviceID>

  init(failingDeviceIDs: Set<AudioDeviceID> = []) {
    self.failingDeviceIDs = failingDeviceIDs
  }

  func start(
    deviceID: AudioDeviceID,
    snapshotHandler: @escaping DeviceOutputCapture.SnapshotHandler
  ) async throws -> any RoutingOutputCaptureSession {
    startCounts[deviceID, default: 0] += 1
    if failingDeviceIDs.contains(deviceID) {
      throw FakeRoutingOutputCaptureError.failed
    }
    snapshotHandlers[deviceID] = snapshotHandler
    let channelID = AudioChannelID(
      ownerID: .source(.deviceOutput(deviceID)),
      index: try #require(AudioChannelIndex(rawValue: 0))
    )
    let format = DeviceOutputCaptureFormat(
      deviceID: deviceID,
      streamIndex: try #require(AudioStreamIndex(rawValue: 0)),
      sampleRate: 48_000,
      channelIDs: [channelID]
    )
    let frameBuffer = try AudioRealtimeFrameBuffer(
      format: AudioProcessingFormat(sampleRate: format.sampleRate, channelCount: 1)
    )
    return FakeRoutingOutputCaptureSession(format: format, frameBuffer: frameBuffer) { [self] in
      await recordStop(for: deviceID)
    }
  }

  private func recordStop(for deviceID: AudioDeviceID) {
    stopCounts[deviceID, default: 0] += 1
    snapshotHandlers[deviceID] = nil
  }

  func startCount(for deviceID: AudioDeviceID) -> Int {
    startCounts[deviceID, default: 0]
  }

  func stopCount(for deviceID: AudioDeviceID) -> Int {
    stopCounts[deviceID, default: 0]
  }

  func emit(_ snapshot: DeviceOutputMeterSnapshot) {
    snapshotHandlers[snapshot.format.deviceID]?(snapshot)
  }

  func setFails(_ fails: Bool, for deviceID: AudioDeviceID) {
    if fails {
      failingDeviceIDs.insert(deviceID)
    } else {
      failingDeviceIDs.remove(deviceID)
    }
  }
}

private enum FakeRoutingOutputCaptureError: Error, LocalizedError {
  case failed

  var errorDescription: String? {
    "The fake output capture failed."
  }
}

private actor FakeRoutingOutputCaptureSession: RoutingOutputCaptureSession {
  nonisolated let format: DeviceOutputCaptureFormat
  nonisolated let frameBuffer: AudioRealtimeFrameBuffer

  private let stopHandler: @Sendable () async -> Void
  private var isStopped = false

  init(
    format: DeviceOutputCaptureFormat,
    frameBuffer: AudioRealtimeFrameBuffer,
    stopHandler: @escaping @Sendable () async -> Void
  ) {
    self.format = format
    self.frameBuffer = frameBuffer
    self.stopHandler = stopHandler
  }

  func stop() async {
    guard !isStopped else { return }
    isStopped = true
    await stopHandler()
  }
}
