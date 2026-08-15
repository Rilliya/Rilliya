import Foundation
import Observation
import RilliyaKit

enum RoutingCaptureState: Equatable {
  case idle
  case starting
  case running(ProcessOutputCaptureFormat)
  case failed(String)
}

protocol RoutingProcessCaptureSession: AnyObject, Sendable {
  var format: ProcessOutputCaptureFormat { get }

  func stop() async
}

protocol RoutingProcessCaptureStarting: Sendable {
  func start(
    processID: AudioProcessID,
    snapshotHandler: @escaping ProcessOutputCapture.SnapshotHandler
  ) async throws -> any RoutingProcessCaptureSession
}

struct SystemRoutingProcessCaptureStarter: RoutingProcessCaptureStarting {
  func start(
    processID: AudioProcessID,
    snapshotHandler: @escaping ProcessOutputCapture.SnapshotHandler
  ) async throws -> any RoutingProcessCaptureSession {
    try await Task.detached(priority: .userInitiated) {
      let capture = try ProcessOutputCapture(
        processID: processID,
        snapshotHandler: snapshotHandler
      )
      do {
        try capture.start()
        return SystemRoutingProcessCaptureSession(capture: capture)
      } catch {
        try? capture.stop()
        throw error
      }
    }.value
  }
}

private final class SystemRoutingProcessCaptureSession: RoutingProcessCaptureSession,
  @unchecked Sendable
{
  let format: ProcessOutputCaptureFormat

  private let capture: ProcessOutputCapture

  init(capture: ProcessOutputCapture) {
    self.capture = capture
    format = capture.format
  }

  func stop() async {
    await Task.detached(priority: .utility) { [capture] in
      try? capture.stop()
    }.value
  }
}

@MainActor
@Observable
final class RoutingCaptureController {
  private enum SharedSourcePhase {
    case starting
    case running(any RoutingProcessCaptureSession)
    case stopping
  }

  private struct SharedSource {
    var nodeIDs: Set<UUID>
    var phase: SharedSourcePhase
    var generation: UInt64
    var lastSnapshot: ProcessOutputMeterSnapshot?
  }

  private(set) var states: [UUID: RoutingCaptureState] = [:]
  private(set) var snapshots: [UUID: ProcessOutputMeterSnapshot] = [:]

  @ObservationIgnored private let captureStarter: any RoutingProcessCaptureStarting
  @ObservationIgnored private var sources: [AudioProcessID: SharedSource] = [:]
  @ObservationIgnored private var processIDsByNode: [UUID: AudioProcessID] = [:]
  @ObservationIgnored private var nextGeneration: UInt64 = 0

  init(
    captureStarter: any RoutingProcessCaptureStarting = SystemRoutingProcessCaptureStarter()
  ) {
    self.captureStarter = captureStarter
  }

  func state(for nodeID: UUID) -> RoutingCaptureState {
    states[nodeID] ?? .idle
  }

  func snapshot(for nodeID: UUID) -> ProcessOutputMeterSnapshot? {
    snapshots[nodeID]
  }

  func consumerCount(for nodeID: UUID) -> Int {
    guard let processID = processIDsByNode[nodeID] else { return 0 }
    return sources[processID]?.nodeIDs.count ?? 0
  }

  func start(nodeID: UUID, processID: AudioProcessID) {
    if processIDsByNode[nodeID] == processID,
      let source = sources[processID],
      source.nodeIDs.contains(nodeID)
    {
      synchronizeNode(nodeID, with: source)
      return
    }

    detach(nodeID: nodeID, publishesIdleState: false)
    processIDsByNode[nodeID] = processID
    snapshots[nodeID] = nil

    if var source = sources[processID] {
      source.nodeIDs.insert(nodeID)
      sources[processID] = source
      synchronizeNode(nodeID, with: source)
      return
    }

    let generation = makeGeneration()
    sources[processID] = SharedSource(
      nodeIDs: [nodeID],
      phase: .starting,
      generation: generation,
      lastSnapshot: nil
    )
    states[nodeID] = .starting
    beginStart(processID: processID, generation: generation)
  }

  func stop(nodeID: UUID) {
    detach(nodeID: nodeID, publishesIdleState: true)
  }

  func stop(processID: AudioProcessID) {
    let nodeIDs = processIDsByNode.compactMap { nodeID, capturedProcessID in
      capturedProcessID == processID ? nodeID : nil
    }
    for nodeID in nodeIDs {
      detach(nodeID: nodeID, publishesIdleState: true)
    }
  }

  func stopAll() {
    for nodeID in Array(processIDsByNode.keys) {
      detach(nodeID: nodeID, publishesIdleState: true)
    }
  }

  private func detach(nodeID: UUID, publishesIdleState: Bool) {
    snapshots[nodeID] = nil
    if publishesIdleState {
      states[nodeID] = .idle
    }
    guard let processID = processIDsByNode.removeValue(forKey: nodeID),
      var source = sources[processID]
    else {
      return
    }

    source.nodeIDs.remove(nodeID)
    sources[processID] = source
    guard source.nodeIDs.isEmpty else { return }

    switch source.phase {
    case .starting, .stopping:
      return
    case .running(let capture):
      source.phase = .stopping
      sources[processID] = source
      beginStop(capture, processID: processID, generation: source.generation)
    }
  }

  private func beginStart(processID: AudioProcessID, generation: UInt64) {
    let captureStarter = captureStarter
    let snapshotHandler: ProcessOutputCapture.SnapshotHandler = { [weak self] snapshot in
      Task { @MainActor [weak self] in
        self?.receive(snapshot, processID: processID, generation: generation)
      }
    }

    Task { @MainActor [weak self] in
      do {
        let capture = try await captureStarter.start(
          processID: processID,
          snapshotHandler: snapshotHandler
        )
        guard let self else {
          await capture.stop()
          return
        }
        self.finishStart(capture, processID: processID, generation: generation)
      } catch {
        self?.failStart(error, processID: processID, generation: generation)
      }
    }
  }

  private func finishStart(
    _ capture: any RoutingProcessCaptureSession,
    processID: AudioProcessID,
    generation: UInt64
  ) {
    guard var source = sources[processID], source.generation == generation,
      case .starting = source.phase
    else {
      Task {
        await capture.stop()
      }
      return
    }

    if source.nodeIDs.isEmpty {
      source.phase = .stopping
      sources[processID] = source
      beginStop(capture, processID: processID, generation: generation)
      return
    }

    source.phase = .running(capture)
    sources[processID] = source
    for nodeID in source.nodeIDs where processIDsByNode[nodeID] == processID {
      states[nodeID] = .running(capture.format)
      snapshots[nodeID] = source.lastSnapshot
    }
  }

  private func failStart(
    _ error: any Error,
    processID: AudioProcessID,
    generation: UInt64
  ) {
    guard let source = sources[processID], source.generation == generation,
      case .starting = source.phase
    else {
      return
    }

    sources[processID] = nil
    for nodeID in source.nodeIDs where processIDsByNode[nodeID] == processID {
      processIDsByNode[nodeID] = nil
      snapshots[nodeID] = nil
      states[nodeID] = .failed(error.localizedDescription)
    }
  }

  private func beginStop(
    _ capture: any RoutingProcessCaptureSession,
    processID: AudioProcessID,
    generation: UInt64
  ) {
    Task { @MainActor [weak self] in
      await capture.stop()
      self?.finishStop(processID: processID, generation: generation)
    }
  }

  private func finishStop(processID: AudioProcessID, generation: UInt64) {
    guard var source = sources[processID], source.generation == generation,
      case .stopping = source.phase
    else {
      return
    }

    guard !source.nodeIDs.isEmpty else {
      sources[processID] = nil
      return
    }

    source.phase = .starting
    source.generation = makeGeneration()
    source.lastSnapshot = nil
    sources[processID] = source
    for nodeID in source.nodeIDs where processIDsByNode[nodeID] == processID {
      snapshots[nodeID] = nil
      states[nodeID] = .starting
    }
    beginStart(processID: processID, generation: source.generation)
  }

  private func receive(
    _ snapshot: ProcessOutputMeterSnapshot,
    processID: AudioProcessID,
    generation: UInt64
  ) {
    guard snapshot.format.processID == processID,
      var source = sources[processID],
      source.generation == generation
    else {
      return
    }
    switch source.phase {
    case .starting, .running:
      break
    case .stopping:
      return
    }

    source.lastSnapshot = snapshot
    sources[processID] = source
    for nodeID in source.nodeIDs where processIDsByNode[nodeID] == processID {
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
