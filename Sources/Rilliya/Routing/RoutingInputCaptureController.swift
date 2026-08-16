import AVFoundation
import Foundation
import Observation
import RilliyaCapture
import RilliyaCore
import RilliyaRealtime

enum RoutingInputCaptureState: Equatable {
  case idle
  case starting
  case running(DeviceInputCaptureFormat)
  case failed(RoutingNodeFailure)
}

protocol RoutingInputCaptureSession: AnyObject, Sendable {
  var format: DeviceInputCaptureFormat { get }
  var frameBuffer: AudioRealtimeFrameBuffer { get }

  func subscribeToFrames() throws -> AudioRealtimeFrameSubscription?
  func stop() async
}

extension RoutingInputCaptureSession {
  func subscribeToFrames() throws -> AudioRealtimeFrameSubscription? { nil }
}

protocol RoutingInputCaptureStarting: Sendable {
  func start(
    deviceID: RilliyaCore.AudioDeviceID,
    snapshotHandler: @escaping DeviceInputCapture.SnapshotHandler,
    failureHandler: @escaping DeviceInputCapture.FailureHandler
  ) async throws -> any RoutingInputCaptureSession
}

struct SystemRoutingInputCaptureStarter: RoutingInputCaptureStarting {
  func start(
    deviceID: RilliyaCore.AudioDeviceID,
    snapshotHandler: @escaping DeviceInputCapture.SnapshotHandler,
    failureHandler: @escaping DeviceInputCapture.FailureHandler
  ) async throws -> any RoutingInputCaptureSession {
    guard await hasAudioInputPermission() else {
      throw DeviceInputCaptureError.permissionDenied
    }
    return try await Task.detached(priority: .userInitiated) {
      let capture = try DeviceInputCapture(
        deviceID: deviceID,
        configuration: RoutingCaptureCapacity.configuration,
        snapshotHandler: snapshotHandler,
        failureHandler: failureHandler
      )
      do {
        try capture.start()
        return SystemRoutingInputCaptureSession(capture: capture)
      } catch {
        try? capture.stop()
        throw error
      }
    }.value
  }

  private func hasAudioInputPermission() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      true
    case .notDetermined:
      await AVCaptureDevice.requestAccess(for: .audio)
    case .denied, .restricted:
      false
    @unknown default:
      false
    }
  }
}

private final class SystemRoutingInputCaptureSession: RoutingInputCaptureSession,
  @unchecked Sendable
{
  let format: DeviceInputCaptureFormat
  let frameBuffer: AudioRealtimeFrameBuffer

  private let capture: DeviceInputCapture

  init(capture: DeviceInputCapture) {
    self.capture = capture
    format = capture.format
    frameBuffer = capture.frameBuffer
  }

  func subscribeToFrames() throws -> AudioRealtimeFrameSubscription? {
    try capture.subscribeToFrames()
  }

  func stop() async {
    await Task.detached(priority: .utility) { [capture] in
      try? capture.stop()
    }.value
  }
}

@MainActor
@Observable
final class RoutingInputCaptureController {
  private enum SharedSourcePhase {
    case starting
    case running(any RoutingInputCaptureSession)
    case stopping
  }

  private struct SharedSource {
    var nodeIDs: Set<UUID>
    var phase: SharedSourcePhase
    var generation: UInt64
    var lastSnapshot: DeviceInputMeterSnapshot?
  }

  private(set) var states: [UUID: RoutingInputCaptureState] = [:]
  private(set) var snapshots: [UUID: DeviceInputMeterSnapshot] = [:]

  @ObservationIgnored private let captureStarter: any RoutingInputCaptureStarting
  @ObservationIgnored private var sources: [RilliyaCore.AudioDeviceID: SharedSource] = [:]
  @ObservationIgnored private var deviceIDsByNode: [UUID: RilliyaCore.AudioDeviceID] = [:]
  @ObservationIgnored private var failedDeviceIDs: [UUID: RilliyaCore.AudioDeviceID] = [:]
  @ObservationIgnored private var nextGeneration: UInt64 = 0

  init(
    captureStarter: any RoutingInputCaptureStarting = SystemRoutingInputCaptureStarter()
  ) {
    self.captureStarter = captureStarter
  }

  func state(for nodeID: UUID) -> RoutingInputCaptureState {
    states[nodeID] ?? .idle
  }

  func snapshot(for nodeID: UUID) -> DeviceInputMeterSnapshot? {
    snapshots[nodeID]
  }

  func frameBuffer(for nodeID: UUID) -> AudioRealtimeFrameBuffer? {
    guard let deviceID = deviceIDsByNode[nodeID],
      let source = sources[deviceID],
      case .running(let capture) = source.phase
    else { return nil }
    return capture.frameBuffer
  }

  func captureSource(for nodeID: UUID) throws -> RoutingRealtimeCaptureSource? {
    guard let deviceID = deviceIDsByNode[nodeID],
      let source = sources[deviceID],
      case .running(let capture) = source.phase
    else { return nil }
    if let subscription = try capture.subscribeToFrames() {
      return .subscription(subscription)
    }
    return .frameBuffer(capture.frameBuffer)
  }

  func captureSessionIdentity(for nodeID: UUID) -> ObjectIdentifier? {
    guard let deviceID = deviceIDsByNode[nodeID],
      let source = sources[deviceID],
      case .running(let capture) = source.phase
    else { return nil }
    return ObjectIdentifier(capture)
  }

  func consumerCount(for nodeID: UUID) -> Int {
    guard let deviceID = deviceIDsByNode[nodeID] else { return 0 }
    return sources[deviceID]?.nodeIDs.count ?? 0
  }

  func start(nodeID: UUID, deviceID: RilliyaCore.AudioDeviceID) {
    if failedDeviceIDs[nodeID] == deviceID { return }
    if deviceIDsByNode[nodeID] == deviceID,
      let source = sources[deviceID],
      source.nodeIDs.contains(nodeID)
    {
      synchronizeNode(nodeID, with: source)
      return
    }

    detach(nodeID: nodeID, publishesIdleState: false)
    deviceIDsByNode[nodeID] = deviceID
    snapshots[nodeID] = nil

    if var source = sources[deviceID] {
      source.nodeIDs.insert(nodeID)
      sources[deviceID] = source
      synchronizeNode(nodeID, with: source)
      return
    }

    let generation = makeGeneration()
    sources[deviceID] = SharedSource(
      nodeIDs: [nodeID],
      phase: .starting,
      generation: generation,
      lastSnapshot: nil
    )
    states[nodeID] = .starting
    beginStart(deviceID: deviceID, generation: generation)
  }

  func reconcile(deviceIDsByNode requirements: [UUID: RilliyaCore.AudioDeviceID]) {
    for (nodeID, deviceID) in Array(deviceIDsByNode) {
      guard requirements[nodeID] != deviceID else { continue }
      detach(nodeID: nodeID, publishesIdleState: true)
    }
    for (nodeID, deviceID) in requirements.sorted(by: {
      $0.key.uuidString < $1.key.uuidString
    }) {
      start(nodeID: nodeID, deviceID: deviceID)
    }
  }

  /// Clears a latched failure so the next reconciliation starts the capture again.
  func retry(nodeID: UUID) {
    guard case .failed = state(for: nodeID) else { return }
    failedDeviceIDs[nodeID] = nil
    states[nodeID] = .idle
  }

  func stop(nodeID: UUID) {
    detach(nodeID: nodeID, publishesIdleState: true)
  }

  func stopAll() {
    for nodeID in Array(deviceIDsByNode.keys) {
      detach(nodeID: nodeID, publishesIdleState: true)
    }
  }

  private func detach(nodeID: UUID, publishesIdleState: Bool) {
    snapshots[nodeID] = nil
    if publishesIdleState {
      states[nodeID] = .idle
    }
    guard let deviceID = deviceIDsByNode.removeValue(forKey: nodeID),
      var source = sources[deviceID]
    else { return }

    source.nodeIDs.remove(nodeID)
    sources[deviceID] = source
    guard source.nodeIDs.isEmpty else { return }

    switch source.phase {
    case .starting, .stopping:
      return
    case .running(let capture):
      source.phase = .stopping
      sources[deviceID] = source
      beginStop(capture, deviceID: deviceID, generation: source.generation)
    }
  }

  private func beginStart(deviceID: RilliyaCore.AudioDeviceID, generation: UInt64) {
    let captureStarter = captureStarter
    let snapshotHandler: DeviceInputCapture.SnapshotHandler = { [weak self] snapshot in
      Task { @MainActor [weak self] in
        self?.receive(snapshot, deviceID: deviceID, generation: generation)
      }
    }
    let failureHandler: DeviceInputCapture.FailureHandler = { [weak self] error in
      Task { @MainActor [weak self] in
        self?.receiveFailure(error, deviceID: deviceID, generation: generation)
      }
    }

    Task { @MainActor [weak self] in
      do {
        let capture = try await captureStarter.start(
          deviceID: deviceID,
          snapshotHandler: snapshotHandler,
          failureHandler: failureHandler
        )
        guard let self else {
          await capture.stop()
          return
        }
        self.finishStart(capture, deviceID: deviceID, generation: generation)
      } catch {
        self?.failStart(error, deviceID: deviceID, generation: generation)
      }
    }
  }

  private func finishStart(
    _ capture: any RoutingInputCaptureSession,
    deviceID: RilliyaCore.AudioDeviceID,
    generation: UInt64
  ) {
    guard var source = sources[deviceID], source.generation == generation,
      case .starting = source.phase
    else {
      Task { await capture.stop() }
      return
    }

    if source.nodeIDs.isEmpty {
      source.phase = .stopping
      sources[deviceID] = source
      beginStop(capture, deviceID: deviceID, generation: generation)
      return
    }

    source.phase = .running(capture)
    sources[deviceID] = source
    for nodeID in source.nodeIDs where deviceIDsByNode[nodeID] == deviceID {
      states[nodeID] = .running(capture.format)
      snapshots[nodeID] = source.lastSnapshot
    }
  }

  private func failStart(
    _ error: any Error,
    deviceID: RilliyaCore.AudioDeviceID,
    generation: UInt64
  ) {
    guard let source = sources[deviceID], source.generation == generation,
      case .starting = source.phase
    else { return }

    sources[deviceID] = nil
    for nodeID in source.nodeIDs where deviceIDsByNode[nodeID] == deviceID {
      deviceIDsByNode[nodeID] = nil
      failedDeviceIDs[nodeID] = deviceID
      snapshots[nodeID] = nil
      states[nodeID] = .failed(RoutingNodeFailure(error))
    }
  }

  private func receiveFailure(
    _ error: DeviceInputCaptureError,
    deviceID: RilliyaCore.AudioDeviceID,
    generation: UInt64
  ) {
    guard var source = sources[deviceID], source.generation == generation,
      case .running(let capture) = source.phase
    else { return }

    let nodeIDs = source.nodeIDs
    source.nodeIDs.removeAll()
    source.phase = .stopping
    sources[deviceID] = source
    for nodeID in nodeIDs where deviceIDsByNode[nodeID] == deviceID {
      deviceIDsByNode[nodeID] = nil
      failedDeviceIDs[nodeID] = deviceID
      snapshots[nodeID] = nil
      states[nodeID] = .failed(RoutingNodeFailure(error))
    }
    beginStop(capture, deviceID: deviceID, generation: generation)
  }

  private func beginStop(
    _ capture: any RoutingInputCaptureSession,
    deviceID: RilliyaCore.AudioDeviceID,
    generation: UInt64
  ) {
    Task { @MainActor [weak self] in
      await capture.stop()
      self?.finishStop(deviceID: deviceID, generation: generation)
    }
  }

  private func finishStop(deviceID: RilliyaCore.AudioDeviceID, generation: UInt64) {
    guard var source = sources[deviceID], source.generation == generation,
      case .stopping = source.phase
    else { return }

    guard !source.nodeIDs.isEmpty else {
      sources[deviceID] = nil
      return
    }

    source.phase = .starting
    source.generation = makeGeneration()
    source.lastSnapshot = nil
    sources[deviceID] = source
    for nodeID in source.nodeIDs where deviceIDsByNode[nodeID] == deviceID {
      snapshots[nodeID] = nil
      states[nodeID] = .starting
    }
    beginStart(deviceID: deviceID, generation: source.generation)
  }

  private func receive(
    _ snapshot: DeviceInputMeterSnapshot,
    deviceID: RilliyaCore.AudioDeviceID,
    generation: UInt64
  ) {
    guard snapshot.format.deviceID == deviceID,
      var source = sources[deviceID],
      source.generation == generation
    else { return }
    switch source.phase {
    case .starting, .running:
      break
    case .stopping:
      return
    }

    source.lastSnapshot = snapshot
    sources[deviceID] = source
    for nodeID in source.nodeIDs where deviceIDsByNode[nodeID] == deviceID {
      snapshots[nodeID] = snapshot
    }
  }

  private func synchronizeNode(_ nodeID: UUID, with source: SharedSource) {
    switch source.phase {
    case .starting, .stopping:
      states[nodeID] = .starting
      snapshots[nodeID] = nil
    case .running(let capture):
      states[nodeID] = .running(capture.format)
      snapshots[nodeID] = source.lastSnapshot
    }
  }

  private func makeGeneration() -> UInt64 {
    nextGeneration &+= 1
    return nextGeneration
  }
}
