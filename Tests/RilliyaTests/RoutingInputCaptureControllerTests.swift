import Foundation
import RilliyaKit
import Testing

@testable import Rilliya

struct RoutingInputCaptureControllerTests {
  @Test @MainActor
  func nodesUsingTheSameDeviceShareOneCapture() async throws {
    let deviceID = try #require(AudioDeviceID(rawValue: "test.input"))
    let starter = FakeRoutingInputCaptureStarter()
    let controller = RoutingInputCaptureController(captureStarter: starter)
    let firstNodeID = UUID()
    let secondNodeID = UUID()

    controller.start(nodeID: firstNodeID, deviceID: deviceID)
    controller.start(nodeID: secondNodeID, deviceID: deviceID)

    let bothRunning = await eventually {
      guard case .running = controller.state(for: firstNodeID),
        case .running = controller.state(for: secondNodeID)
      else { return false }
      return true
    }
    #expect(bothRunning)
    #expect(await starter.startCount(for: deviceID) == 1)
    #expect(controller.consumerCount(for: firstNodeID) == 2)

    controller.start(nodeID: firstNodeID, deviceID: deviceID)
    #expect(await starter.startCount(for: deviceID) == 1)
    #expect(controller.consumerCount(for: firstNodeID) == 2)

    let snapshot = try makeSnapshot(deviceID: deviceID)
    await starter.emit(snapshot)
    let bothReceivedSnapshot = await eventually {
      controller.snapshot(for: firstNodeID) == snapshot
        && controller.snapshot(for: secondNodeID) == snapshot
    }
    #expect(bothReceivedSnapshot)

    controller.stop(nodeID: firstNodeID)
    #expect(controller.state(for: firstNodeID) == .idle)
    #expect(await starter.stopCount(for: deviceID) == 0)

    controller.stop(nodeID: secondNodeID)
    #expect(await eventually { await starter.stopCount(for: deviceID) == 1 })
  }

  @Test @MainActor
  func asynchronousDeviceFailureReachesEveryConsumer() async throws {
    let deviceID = try #require(AudioDeviceID(rawValue: "test.failing-input"))
    let starter = FakeRoutingInputCaptureStarter()
    let controller = RoutingInputCaptureController(captureStarter: starter)
    let firstNodeID = UUID()
    let secondNodeID = UUID()

    controller.start(nodeID: firstNodeID, deviceID: deviceID)
    controller.start(nodeID: secondNodeID, deviceID: deviceID)
    #expect(
      await eventually {
        if case .running = controller.state(for: firstNodeID) { return true }
        return false
      }
    )

    await starter.fail(deviceID, with: .deviceUnavailable(deviceID))

    let bothFailed = await eventually {
      guard case .failed = controller.state(for: firstNodeID),
        case .failed = controller.state(for: secondNodeID)
      else { return false }
      return true
    }
    #expect(bothFailed)
    #expect(controller.consumerCount(for: firstNodeID) == 0)
    #expect(controller.snapshot(for: firstNodeID) == nil)
  }

  private func makeSnapshot(
    deviceID: AudioDeviceID
  ) throws -> DeviceInputMeterSnapshot {
    let channelID = AudioChannelID(
      ownerID: .source(.deviceInput(deviceID)),
      index: try #require(AudioChannelIndex(rawValue: 0))
    )
    let format = DeviceInputCaptureFormat(
      deviceID: deviceID,
      sampleRate: 48_000,
      channelIDs: [channelID]
    )
    return DeviceInputMeterSnapshot(
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

private actor FakeRoutingInputCaptureStarter: RoutingInputCaptureStarting {
  private var startCounts: [AudioDeviceID: Int] = [:]
  private var stopCounts: [AudioDeviceID: Int] = [:]
  private var snapshotHandlers: [AudioDeviceID: DeviceInputCapture.SnapshotHandler] = [:]
  private var failureHandlers: [AudioDeviceID: DeviceInputCapture.FailureHandler] = [:]

  func start(
    deviceID: AudioDeviceID,
    snapshotHandler: @escaping DeviceInputCapture.SnapshotHandler,
    failureHandler: @escaping DeviceInputCapture.FailureHandler
  ) async throws -> any RoutingInputCaptureSession {
    startCounts[deviceID, default: 0] += 1
    snapshotHandlers[deviceID] = snapshotHandler
    failureHandlers[deviceID] = failureHandler
    guard let channelIndex = AudioChannelIndex(rawValue: 0) else {
      throw FakeRoutingInputCaptureError.invalidChannelIndex
    }
    let channelID = AudioChannelID(
      ownerID: .source(.deviceInput(deviceID)),
      index: channelIndex
    )
    let format = DeviceInputCaptureFormat(
      deviceID: deviceID,
      sampleRate: 48_000,
      channelIDs: [channelID]
    )
    return FakeRoutingInputCaptureSession(format: format) { [self] in
      await recordStop(for: deviceID)
    }
  }

  func startCount(for deviceID: AudioDeviceID) -> Int {
    startCounts[deviceID, default: 0]
  }

  func stopCount(for deviceID: AudioDeviceID) -> Int {
    stopCounts[deviceID, default: 0]
  }

  func emit(_ snapshot: DeviceInputMeterSnapshot) {
    snapshotHandlers[snapshot.format.deviceID]?(snapshot)
  }

  func fail(_ deviceID: AudioDeviceID, with error: DeviceInputCaptureError) {
    failureHandlers[deviceID]?(error)
  }

  private func recordStop(for deviceID: AudioDeviceID) {
    stopCounts[deviceID, default: 0] += 1
    snapshotHandlers[deviceID] = nil
    failureHandlers[deviceID] = nil
  }
}

private enum FakeRoutingInputCaptureError: Error {
  case invalidChannelIndex
}

private actor FakeRoutingInputCaptureSession: RoutingInputCaptureSession {
  nonisolated let format: DeviceInputCaptureFormat

  private let stopHandler: @Sendable () async -> Void
  private var isStopped = false

  init(
    format: DeviceInputCaptureFormat,
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
