import Foundation
import RilliyaCapture
import RilliyaCore
import RilliyaRealtime
import Testing

@testable import Rilliya

struct RoutingInputCaptureControllerTests {
  /// Reconciliation reruns whenever any observed audio state changes, so a failure that restarts
  /// on an unchanged device spins the node between starting and failed.
  @Test @MainActor
  func aFailedStartDoesNotRestartOnAnUnchangedDevice() async throws {
    let deviceID = try #require(AudioDeviceID(rawValue: "failing-input"))
    let nodeID = UUID()
    let starter = FakeRoutingInputCaptureStarter(failingDeviceIDs: [deviceID])
    let controller = RoutingInputCaptureController(captureStarter: starter)

    controller.reconcile(deviceIDsByNode: [nodeID: deviceID])
    #expect(
      await eventually {
        guard case .failed = controller.state(for: nodeID) else { return false }
        return true
      })
    #expect(await starter.startCount(for: deviceID) == 1)

    for _ in 0..<InputCaptureRetryConstants.attempts {
      controller.reconcile(deviceIDsByNode: [nodeID: deviceID])
      await Task.yield()
    }
    #expect(await starter.startCount(for: deviceID) == 1)

    controller.retry(nodeID: nodeID)
    controller.reconcile(deviceIDsByNode: [nodeID: deviceID])
    #expect(await eventually { await starter.startCount(for: deviceID) == 2 })
  }

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

  @Test @MainActor
  func readdingADeviceWhileItsPreviousCaptureStopsStartsAFresh() async throws {
    let deviceID = try #require(AudioDeviceID(rawValue: "test.reselected-input"))
    let starter = FakeRoutingInputCaptureStarter(suspendsStops: true)
    let controller = RoutingInputCaptureController(captureStarter: starter)
    let nodeID = UUID()

    controller.reconcile(deviceIDsByNode: [nodeID: deviceID])
    #expect(
      await eventually {
        if case .running = controller.state(for: nodeID) { return true }
        return false
      }
    )

    controller.reconcile(deviceIDsByNode: [:])
    controller.reconcile(deviceIDsByNode: [nodeID: deviceID])

    #expect(controller.state(for: nodeID) == .starting)
    #expect(await starter.startCount(for: deviceID) == 1)
    #expect(await eventually { await starter.hasPendingStop })

    await starter.resumeStops()

    #expect(
      await eventually {
        guard case .running = controller.state(for: nodeID) else { return false }
        return await starter.startCount(for: deviceID) == 2
      }
    )
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
  private var suspendsStops: Bool
  private var stopWaiters: [CheckedContinuation<Void, Never>] = []
  private let failingDeviceIDs: Set<AudioDeviceID>

  init(suspendsStops: Bool = false, failingDeviceIDs: Set<AudioDeviceID> = []) {
    self.suspendsStops = suspendsStops
    self.failingDeviceIDs = failingDeviceIDs
  }

  var hasPendingStop: Bool {
    !stopWaiters.isEmpty
  }

  func start(
    deviceID: AudioDeviceID,
    snapshotHandler: @escaping DeviceInputCapture.SnapshotHandler,
    failureHandler: @escaping DeviceInputCapture.FailureHandler
  ) async throws -> any RoutingInputCaptureSession {
    startCounts[deviceID, default: 0] += 1
    if failingDeviceIDs.contains(deviceID) {
      throw FakeRoutingInputCaptureError.requestedFailure
    }
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
    let frameBuffer = try AudioRealtimeFrameBuffer(
      format: AudioProcessingFormat(sampleRate: format.sampleRate, channelCount: 1)
    )
    return FakeRoutingInputCaptureSession(format: format, frameBuffer: frameBuffer) { [self] in
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

  func resumeStops() {
    suspendsStops = false
    let waiters = stopWaiters
    stopWaiters.removeAll(keepingCapacity: false)
    for waiter in waiters {
      waiter.resume()
    }
  }

  private func recordStop(for deviceID: AudioDeviceID) async {
    if suspendsStops {
      await withCheckedContinuation { continuation in
        stopWaiters.append(continuation)
      }
    }
    stopCounts[deviceID, default: 0] += 1
    snapshotHandlers[deviceID] = nil
    failureHandlers[deviceID] = nil
  }
}

private enum FakeRoutingInputCaptureError: Error {
  case invalidChannelIndex
  case requestedFailure
}

private enum InputCaptureRetryConstants {
  static let attempts = 5
}

private actor FakeRoutingInputCaptureSession: RoutingInputCaptureSession {
  nonisolated let format: DeviceInputCaptureFormat
  nonisolated let frameBuffer: AudioRealtimeFrameBuffer

  private let stopHandler: @Sendable () async -> Void
  private var isStopped = false

  init(
    format: DeviceInputCaptureFormat,
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
