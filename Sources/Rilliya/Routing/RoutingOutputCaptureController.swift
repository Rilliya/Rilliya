import Foundation
import Observation
import RilliyaCapture
import RilliyaCore
import RilliyaRealtime

enum RoutingOutputCaptureState: Equatable {
  case idle
  case starting
  case running(DeviceOutputCaptureFormat)
  case failed(String)
}

protocol RoutingOutputCaptureSession: AnyObject, Sendable {
  var format: DeviceOutputCaptureFormat { get }
  var frameBuffer: AudioRealtimeFrameBuffer { get }

  func stop() async
}

protocol RoutingOutputCaptureStarting: Sendable {
  func start(
    deviceID: AudioDeviceID,
    snapshotHandler: @escaping DeviceOutputCapture.SnapshotHandler
  ) async throws -> any RoutingOutputCaptureSession
}

struct SystemRoutingOutputCaptureStarter: RoutingOutputCaptureStarting {
  func start(
    deviceID: AudioDeviceID,
    snapshotHandler: @escaping DeviceOutputCapture.SnapshotHandler
  ) async throws -> any RoutingOutputCaptureSession {
    try await Task.detached(priority: .userInitiated) {
      let capture = try DeviceOutputCapture(
        deviceID: deviceID,
        snapshotHandler: snapshotHandler
      )
      do {
        try capture.start()
        return SystemRoutingOutputCaptureSession(capture: capture)
      } catch {
        try? capture.stop()
        throw error
      }
    }.value
  }
}

private final class SystemRoutingOutputCaptureSession: RoutingOutputCaptureSession,
  @unchecked Sendable
{
  let format: DeviceOutputCaptureFormat
  let frameBuffer: AudioRealtimeFrameBuffer

  private let capture: DeviceOutputCapture

  init(capture: DeviceOutputCapture) {
    self.capture = capture
    format = capture.format
    frameBuffer = capture.frameBuffer
  }

  func stop() async {
    await Task.detached(priority: .utility) { [capture] in
      try? capture.stop()
    }.value
  }
}

@MainActor
@Observable
final class RoutingOutputCaptureController {
  private enum SharedSourcePhase {
    case starting
    case running(any RoutingOutputCaptureSession)
    case stopping
    case failed(String)
  }

  private struct SharedSource {
    var nodeIDs: Set<UUID>
    var phase: SharedSourcePhase
    var generation: UInt64
    var catalogRevision: UInt64
    var lastSnapshot: DeviceOutputMeterSnapshot?
  }

  private(set) var states: [UUID: RoutingOutputCaptureState] = [:]
  private(set) var snapshots: [UUID: DeviceOutputMeterSnapshot] = [:]

  @ObservationIgnored private let captureStarter: any RoutingOutputCaptureStarting
  @ObservationIgnored private var sources: [AudioDeviceID: SharedSource] = [:]
  @ObservationIgnored private var deviceIDsByNode: [UUID: AudioDeviceID] = [:]
  @ObservationIgnored private var nextGeneration: UInt64 = 0

  init(
    captureStarter: any RoutingOutputCaptureStarting = SystemRoutingOutputCaptureStarter()
  ) {
    self.captureStarter = captureStarter
  }

  func state(for nodeID: UUID) -> RoutingOutputCaptureState {
    states[nodeID] ?? .idle
  }

  func snapshot(for nodeID: UUID) -> DeviceOutputMeterSnapshot? {
    snapshots[nodeID]
  }

  func frameBuffer(for nodeID: UUID) -> AudioRealtimeFrameBuffer? {
    guard let deviceID = deviceIDsByNode[nodeID],
      let source = sources[deviceID],
      case .running(let capture) = source.phase
    else { return nil }
    return capture.frameBuffer
  }

  func consumerCount(for nodeID: UUID) -> Int {
    guard let deviceID = deviceIDsByNode[nodeID] else { return 0 }
    return sources[deviceID]?.nodeIDs.count ?? 0
  }

  func deviceID(for nodeID: UUID) -> AudioDeviceID? {
    deviceIDsByNode[nodeID]
  }

  func reconcile(
    deviceIDsByNode requirements: [UUID: AudioDeviceID],
    catalogRevision: UInt64
  ) {
    for (nodeID, deviceID) in Array(deviceIDsByNode) {
      guard requirements[nodeID] != deviceID else { continue }
      detach(nodeID: nodeID, publishesIdleState: true)
    }
    for (nodeID, deviceID) in requirements.sorted(by: {
      $0.key.uuidString < $1.key.uuidString
    }) {
      start(nodeID: nodeID, deviceID: deviceID, catalogRevision: catalogRevision)
    }
  }

  func retry(nodeID: UUID) {
    guard let deviceID = deviceIDsByNode[nodeID],
      let source = sources[deviceID],
      case .failed = source.phase
    else { return }
    restartFailedSource(deviceID: deviceID, catalogRevision: source.catalogRevision)
  }

  func stop(nodeID: UUID) {
    detach(nodeID: nodeID, publishesIdleState: true)
  }

  func stopAll() {
    for nodeID in Array(deviceIDsByNode.keys) {
      detach(nodeID: nodeID, publishesIdleState: true)
    }
  }

  private func start(
    nodeID: UUID,
    deviceID: AudioDeviceID,
    catalogRevision: UInt64
  ) {
    if deviceIDsByNode[nodeID] == deviceID,
      let source = sources[deviceID],
      source.nodeIDs.contains(nodeID)
    {
      if case .failed = source.phase, source.catalogRevision != catalogRevision {
        restartFailedSource(deviceID: deviceID, catalogRevision: catalogRevision)
      } else {
        synchronizeNode(nodeID, with: source)
      }
      return
    }

    detach(nodeID: nodeID, publishesIdleState: false)
    deviceIDsByNode[nodeID] = deviceID
    snapshots[nodeID] = nil

    if var source = sources[deviceID] {
      source.nodeIDs.insert(nodeID)
      sources[deviceID] = source
      if case .failed = source.phase, source.catalogRevision != catalogRevision {
        restartFailedSource(deviceID: deviceID, catalogRevision: catalogRevision)
      } else {
        synchronizeNode(nodeID, with: source)
      }
      return
    }

    let generation = makeGeneration()
    sources[deviceID] = SharedSource(
      nodeIDs: [nodeID],
      phase: .starting,
      generation: generation,
      catalogRevision: catalogRevision,
      lastSnapshot: nil
    )
    states[nodeID] = .starting
    beginStart(deviceID: deviceID, generation: generation)
  }

  private func restartFailedSource(
    deviceID: AudioDeviceID,
    catalogRevision: UInt64
  ) {
    guard var source = sources[deviceID], case .failed = source.phase else { return }
    let generation = makeGeneration()
    source.phase = .starting
    source.generation = generation
    source.catalogRevision = catalogRevision
    source.lastSnapshot = nil
    sources[deviceID] = source
    for nodeID in source.nodeIDs where deviceIDsByNode[nodeID] == deviceID {
      states[nodeID] = .starting
      snapshots[nodeID] = nil
    }
    beginStart(deviceID: deviceID, generation: generation)
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
    case .failed:
      sources[deviceID] = nil
    case .running(let capture):
      source.phase = .stopping
      sources[deviceID] = source
      beginStop(capture, deviceID: deviceID, generation: source.generation)
    }
  }

  private func beginStart(deviceID: AudioDeviceID, generation: UInt64) {
    let captureStarter = captureStarter
    let snapshotHandler: DeviceOutputCapture.SnapshotHandler = { [weak self] snapshot in
      Task { @MainActor [weak self] in
        self?.receive(snapshot, deviceID: deviceID, generation: generation)
      }
    }

    Task { @MainActor [weak self] in
      do {
        let capture = try await captureStarter.start(
          deviceID: deviceID,
          snapshotHandler: snapshotHandler
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
    _ capture: any RoutingOutputCaptureSession,
    deviceID: AudioDeviceID,
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
    deviceID: AudioDeviceID,
    generation: UInt64
  ) {
    guard var source = sources[deviceID], source.generation == generation,
      case .starting = source.phase
    else { return }

    guard !source.nodeIDs.isEmpty else {
      sources[deviceID] = nil
      return
    }

    source.phase = .failed(error.localizedDescription)
    source.lastSnapshot = nil
    sources[deviceID] = source
    for nodeID in source.nodeIDs where deviceIDsByNode[nodeID] == deviceID {
      snapshots[nodeID] = nil
      states[nodeID] = .failed(error.localizedDescription)
    }
  }

  private func beginStop(
    _ capture: any RoutingOutputCaptureSession,
    deviceID: AudioDeviceID,
    generation: UInt64
  ) {
    Task { @MainActor [weak self] in
      await capture.stop()
      self?.finishStop(deviceID: deviceID, generation: generation)
    }
  }

  private func finishStop(deviceID: AudioDeviceID, generation: UInt64) {
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
    _ snapshot: DeviceOutputMeterSnapshot,
    deviceID: AudioDeviceID,
    generation: UInt64
  ) {
    guard snapshot.format.deviceID == deviceID,
      var source = sources[deviceID],
      source.generation == generation
    else { return }
    switch source.phase {
    case .starting, .running:
      break
    case .stopping, .failed:
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
    case .failed(let message):
      states[nodeID] = .failed(message)
      snapshots[nodeID] = nil
    }
  }

  private func makeGeneration() -> UInt64 {
    nextGeneration &+= 1
    return nextGeneration
  }
}
