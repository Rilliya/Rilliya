import Foundation
import Observation
import RilliyaKit

enum RoutingCaptureState: Equatable {
  case idle
  case starting
  case running(ProcessOutputCaptureFormat)
  case failed(String)
}

@MainActor
@Observable
final class RoutingCaptureController {
  private(set) var states: [UUID: RoutingCaptureState] = [:]
  private(set) var snapshots: [UUID: ProcessOutputMeterSnapshot] = [:]

  @ObservationIgnored private var captures: [UUID: ProcessOutputCapture] = [:]
  @ObservationIgnored private var captureProcessIDs: [UUID: AudioProcessID] = [:]
  @ObservationIgnored private var lifecycleTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var generations: [UUID: UInt] = [:]

  func state(for nodeID: UUID) -> RoutingCaptureState {
    states[nodeID] ?? .idle
  }

  func snapshot(for nodeID: UUID) -> ProcessOutputMeterSnapshot? {
    snapshots[nodeID]
  }

  func start(nodeID: UUID, processID: AudioProcessID) {
    let predecessor = lifecycleTasks.removeValue(forKey: nodeID)
    predecessor?.cancel()
    let retiredCapture = captures.removeValue(forKey: nodeID)
    captureProcessIDs.removeValue(forKey: nodeID)
    snapshots.removeValue(forKey: nodeID)
    let generation = generations[nodeID, default: 0] &+ 1
    generations[nodeID] = generation
    captureProcessIDs[nodeID] = processID
    states[nodeID] = .starting
    let snapshotHandler: ProcessOutputCapture.SnapshotHandler = { [weak self] snapshot in
      Task { @MainActor [weak self] in
        self?.receive(snapshot, for: nodeID, generation: generation)
      }
    }

    lifecycleTasks[nodeID] = Task { [weak self] in
      await predecessor?.value
      if let retiredCapture {
        await stopCapture(retiredCapture)
      }
      guard let self, self.generations[nodeID] == generation, !Task.isCancelled else { return }
      do {
        let capture = try await Task.detached(priority: .userInitiated) {
          let capture = try ProcessOutputCapture(
            processID: processID,
            snapshotHandler: snapshotHandler
          )
          try capture.start()
          return capture
        }.value
        guard self.generations[nodeID] == generation, !Task.isCancelled else {
          try? capture.stop()
          return
        }
        self.captures[nodeID] = capture
        self.states[nodeID] = .running(capture.format)
        self.lifecycleTasks[nodeID] = nil
      } catch is CancellationError {
        guard self.generations[nodeID] == generation else { return }
        self.captureProcessIDs[nodeID] = nil
        self.states[nodeID] = .idle
        self.lifecycleTasks[nodeID] = nil
      } catch {
        guard self.generations[nodeID] == generation else { return }
        self.captureProcessIDs[nodeID] = nil
        self.states[nodeID] = .failed(error.localizedDescription)
        self.lifecycleTasks[nodeID] = nil
      }
    }
  }

  func stop(nodeID: UUID) {
    generations[nodeID, default: 0] &+= 1
    let generation = generations[nodeID, default: 0]
    let predecessor = lifecycleTasks.removeValue(forKey: nodeID)
    predecessor?.cancel()
    let retiredCapture = captures.removeValue(forKey: nodeID)
    captureProcessIDs.removeValue(forKey: nodeID)
    snapshots.removeValue(forKey: nodeID)
    states[nodeID] = .idle
    guard predecessor != nil || retiredCapture != nil else { return }
    lifecycleTasks[nodeID] = Task { [weak self] in
      await predecessor?.value
      if let retiredCapture {
        await stopCapture(retiredCapture)
      }
      guard let self, self.generations[nodeID] == generation else { return }
      self.lifecycleTasks[nodeID] = nil
    }
  }

  func stop(processID: AudioProcessID) {
    let nodeIDs = captureProcessIDs.compactMap { nodeID, capturedProcessID in
      capturedProcessID == processID ? nodeID : nil
    }
    for nodeID in nodeIDs {
      stop(nodeID: nodeID)
    }
  }

  func stopAll() {
    let nodeIDs = Set(states.keys).union(captures.keys).union(lifecycleTasks.keys)
    for nodeID in nodeIDs {
      stop(nodeID: nodeID)
    }
  }

  private func receive(
    _ snapshot: ProcessOutputMeterSnapshot,
    for nodeID: UUID,
    generation: UInt
  ) {
    guard generations[nodeID] == generation else { return }
    snapshots[nodeID] = snapshot
  }
}

private func stopCapture(_ capture: ProcessOutputCapture) async {
  await Task.detached(priority: .utility) {
    try? capture.stop()
  }.value
}
