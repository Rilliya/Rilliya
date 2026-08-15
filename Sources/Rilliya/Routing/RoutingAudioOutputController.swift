import Foundation
import Observation
import RilliyaKit

enum RoutingAudioOutputState: Equatable {
  case idle
  case waitingForCapture
  case starting
  case running(DeviceOutputPlaybackFormat)
  case failed(String)
}

protocol RoutingOutputPlaybackSession: AnyObject, Sendable {
  var format: DeviceOutputPlaybackFormat { get }

  func stop() async
}

protocol RoutingOutputPlaybackStarting: Sendable {
  func start(
    deviceID: AudioDeviceID,
    rendererFactory: @escaping DeviceOutputPlayback.RendererFactory,
    failureHandler: @escaping DeviceOutputPlayback.FailureHandler
  ) async throws -> any RoutingOutputPlaybackSession
}

struct SystemRoutingOutputPlaybackStarter: RoutingOutputPlaybackStarting {
  func start(
    deviceID: AudioDeviceID,
    rendererFactory: @escaping DeviceOutputPlayback.RendererFactory,
    failureHandler: @escaping DeviceOutputPlayback.FailureHandler
  ) async throws -> any RoutingOutputPlaybackSession {
    try await Task.detached(priority: .userInitiated) {
      let playback = try DeviceOutputPlayback(
        deviceID: deviceID,
        rendererFactory: rendererFactory,
        failureHandler: failureHandler
      )
      do {
        try playback.start()
        return SystemRoutingOutputPlaybackSession(playback: playback)
      } catch {
        try? playback.stop()
        throw error
      }
    }.value
  }
}

private final class SystemRoutingOutputPlaybackSession: RoutingOutputPlaybackSession,
  @unchecked Sendable
{
  let format: DeviceOutputPlaybackFormat

  private let playback: DeviceOutputPlayback

  init(playback: DeviceOutputPlayback) {
    self.playback = playback
    format = playback.format
  }

  func stop() async {
    await Task.detached(priority: .utility) { [playback] in
      try? playback.stop()
    }.value
  }
}

private struct RoutingAudioOutputNodeConfiguration: Equatable, Sendable {
  let id: UUID
  let value: RoutingNodeValue
  let audioChannelControls: [Int: RoutingAudioChannelControl]
}

private struct RoutingAudioOutputBufferIdentity: Equatable, Sendable {
  let nodeID: UUID
  let identity: ObjectIdentifier
}

private struct RoutingAudioOutputRequestSignature: Equatable, Sendable {
  let outputNodeID: UUID
  let deviceID: AudioDeviceID
  let nodes: [RoutingAudioOutputNodeConfiguration]
  let edges: [RoutingWorkspaceEdge]
  let buffers: [RoutingAudioOutputBufferIdentity]
}

private struct RoutingAudioOutputRequest: Sendable {
  let signature: RoutingAudioOutputRequestSignature
  let nodes: [RoutingWorkspaceNode]
  let edges: [RoutingWorkspaceEdge]
  let frameBuffers: [UUID: AudioRealtimeFrameBuffer]
}

private enum RoutingAudioOutputPlan {
  case idle
  case waitingForCapture
  case blocked(String)
  case ready(RoutingAudioOutputRequest)
}

private enum RoutingAudioOutputDesiredState: Equatable {
  case idle
  case waitingForCapture
  case blocked(String)
  case ready(RoutingAudioOutputRequestSignature)
}

extension RoutingAudioOutputPlan {
  fileprivate var desiredState: RoutingAudioOutputDesiredState {
    switch self {
    case .idle: .idle
    case .waitingForCapture: .waitingForCapture
    case .blocked(let message): .blocked(message)
    case .ready(let request): .ready(request.signature)
    }
  }
}

@MainActor
@Observable
final class RoutingAudioOutputController {
  private struct RunningSession {
    let signature: RoutingAudioOutputRequestSignature
    let session: any RoutingOutputPlaybackSession
  }

  private(set) var states: [UUID: RoutingAudioOutputState] = [:]

  @ObservationIgnored private let playbackStarter: any RoutingOutputPlaybackStarting
  @ObservationIgnored private var runningSessions: [UUID: RunningSession] = [:]
  @ObservationIgnored private var lifecycleTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var generations: [UUID: UInt64] = [:]
  @ObservationIgnored private var desiredStates: [UUID: RoutingAudioOutputDesiredState] = [:]

  init(
    playbackStarter: any RoutingOutputPlaybackStarting = SystemRoutingOutputPlaybackStarter()
  ) {
    self.playbackStarter = playbackStarter
  }

  func state(for nodeID: UUID) -> RoutingAudioOutputState {
    states[nodeID] ?? .idle
  }

  func reconcile(
    workflows: [RoutingWorkflowModel],
    captureController: RoutingCaptureController,
    inputCaptureController: RoutingInputCaptureController
  ) {
    let plans = makePlans(
      workflows: workflows,
      captureController: captureController,
      inputCaptureController: inputCaptureController
    )
    let knownNodeIDs = Set(plans.keys)
      .union(states.keys)
      .union(runningSessions.keys)
      .union(lifecycleTasks.keys)
    for nodeID in knownNodeIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      apply(plans[nodeID] ?? .idle, to: nodeID)
    }
  }

  func stopAll() {
    let nodeIDs = Set(states.keys)
      .union(runningSessions.keys)
      .union(lifecycleTasks.keys)
    for nodeID in nodeIDs {
      apply(.idle, to: nodeID)
    }
  }

  private func apply(_ plan: RoutingAudioOutputPlan, to nodeID: UUID) {
    let desiredState = plan.desiredState
    guard desiredStates[nodeID] != desiredState else { return }
    desiredStates[nodeID] = desiredState
    if case .ready(let request) = plan,
      let runningSession = runningSessions[nodeID],
      runningSession.signature == request.signature,
      lifecycleTasks[nodeID] == nil
    {
      states[nodeID] = .running(runningSession.session.format)
      return
    }
    if runningSessions[nodeID] == nil, lifecycleTasks[nodeID] == nil {
      switch plan {
      case .idle where states[nodeID] == nil || states[nodeID] == .idle:
        states[nodeID] = .idle
        return
      case .waitingForCapture where states[nodeID] == .waitingForCapture:
        return
      case .blocked(let message):
        if states[nodeID] == .failed(message) { return }
      case .ready, .idle, .waitingForCapture:
        break
      }
    }

    let generation = (generations[nodeID] ?? 0) &+ 1
    generations[nodeID] = generation
    let previousTask = lifecycleTasks[nodeID]
    lifecycleTasks[nodeID] = Task { @MainActor [weak self] in
      await previousTask?.value
      guard let self, generations[nodeID] == generation else { return }
      await transition(to: plan, nodeID: nodeID, generation: generation)
      if generations[nodeID] == generation {
        lifecycleTasks[nodeID] = nil
      }
    }
  }

  private func transition(
    to plan: RoutingAudioOutputPlan,
    nodeID: UUID,
    generation: UInt64
  ) async {
    if let running = runningSessions.removeValue(forKey: nodeID) {
      await running.session.stop()
    }
    guard generations[nodeID] == generation else { return }

    switch plan {
    case .idle:
      states[nodeID] = .idle
    case .waitingForCapture:
      states[nodeID] = .waitingForCapture
    case .blocked(let message):
      states[nodeID] = .failed(message)
    case .ready(let request):
      states[nodeID] = .starting
      let playbackStarter = playbackStarter
      let outputNodeID = request.signature.outputNodeID
      let rendererFactory: DeviceOutputPlayback.RendererFactory = { preparation in
        try RoutingPreparedAudioGraphSource(
          preparation: preparation,
          nodes: request.nodes,
          edges: request.edges,
          outputNodeID: outputNodeID,
          frameBuffers: request.frameBuffers
        )
      }
      let failureHandler: DeviceOutputPlayback.FailureHandler = { [weak self] error in
        Task { @MainActor [weak self] in
          self?.receiveFailure(error, nodeID: nodeID, generation: generation)
        }
      }
      do {
        let session = try await playbackStarter.start(
          deviceID: request.signature.deviceID,
          rendererFactory: rendererFactory,
          failureHandler: failureHandler
        )
        guard generations[nodeID] == generation else {
          await session.stop()
          return
        }
        runningSessions[nodeID] = RunningSession(
          signature: request.signature,
          session: session
        )
        states[nodeID] = .running(session.format)
      } catch {
        guard generations[nodeID] == generation else { return }
        desiredStates[nodeID] = nil
        states[nodeID] = .failed(error.localizedDescription)
      }
    }
  }

  private func receiveFailure(
    _ error: DeviceOutputPlaybackError,
    nodeID: UUID,
    generation: UInt64
  ) {
    guard generations[nodeID] == generation else { return }
    apply(.blocked(error.localizedDescription), to: nodeID)
  }

  private func makePlans(
    workflows: [RoutingWorkflowModel],
    captureController: RoutingCaptureController,
    inputCaptureController: RoutingInputCaptureController
  ) -> [UUID: RoutingAudioOutputPlan] {
    var plans: [UUID: RoutingAudioOutputPlan] = [:]
    var claimedBuffers = Set<ObjectIdentifier>()

    for workflow in workflows {
      let workspace = workflow.workspace
      let activeEdges = workspace.edges.filter(workspace.isEdgeActive)
      let incomingEdges = Dictionary(grouping: activeEdges, by: { $0.target.nodeID })
      for outputNode in workspace.nodes {
        guard case .outputAudio(let selection, _) = outputNode.value else { continue }
        guard let selection,
          incomingEdges[outputNode.id]?.isEmpty == false
        else {
          plans[outputNode.id] = .idle
          continue
        }

        let reachableNodeIDs = Self.reachableNodeIDs(
          from: outputNode.id,
          incomingEdges: incomingEdges
        )
        let nodes = workspace.nodes.filter { reachableNodeIDs.contains($0.id) }
        let edges = activeEdges.filter {
          reachableNodeIDs.contains($0.source.nodeID)
            && reachableNodeIDs.contains($0.target.nodeID)
        }
        var frameBuffers: [UUID: AudioRealtimeFrameBuffer] = [:]
        var isWaitingForCapture = false
        for node in nodes {
          let buffer: AudioRealtimeFrameBuffer?
          switch node.value {
          case .applicationAudio:
            buffer = captureController.frameBuffer(for: node.id)
          case .inputAudio:
            buffer = inputCaptureController.frameBuffer(for: node.id)
          case .outputAudio, .visualizer, .audioMixer, .peakLevel:
            continue
          }
          guard let buffer else {
            isWaitingForCapture = true
            continue
          }
          frameBuffers[node.id] = buffer
        }
        guard !isWaitingForCapture else {
          plans[outputNode.id] = .waitingForCapture
          continue
        }

        let bufferIdentities = Set(frameBuffers.values.map(ObjectIdentifier.init))
        guard claimedBuffers.isDisjoint(with: bufferIdentities) else {
          plans[outputNode.id] = .blocked(
            "This source is already feeding another output clock. Add an explicit clocked fan-out before using multiple destinations."
          )
          continue
        }
        claimedBuffers.formUnion(bufferIdentities)

        let sortedNodes = nodes.sorted { $0.id.uuidString < $1.id.uuidString }
        let sortedEdges = edges.sorted { $0.id.uuidString < $1.id.uuidString }
        let sortedBuffers = frameBuffers.map {
          RoutingAudioOutputBufferIdentity(nodeID: $0.key, identity: ObjectIdentifier($0.value))
        }.sorted { $0.nodeID.uuidString < $1.nodeID.uuidString }
        let signature = RoutingAudioOutputRequestSignature(
          outputNodeID: outputNode.id,
          deviceID: selection.id,
          nodes: sortedNodes.map {
            RoutingAudioOutputNodeConfiguration(
              id: $0.id,
              value: $0.value,
              audioChannelControls: $0.audioChannelControls
            )
          },
          edges: sortedEdges,
          buffers: sortedBuffers
        )
        plans[outputNode.id] = .ready(
          RoutingAudioOutputRequest(
            signature: signature,
            nodes: sortedNodes,
            edges: sortedEdges,
            frameBuffers: frameBuffers
          )
        )
      }
    }
    return plans
  }

  private static func reachableNodeIDs(
    from outputNodeID: UUID,
    incomingEdges: [UUID: [RoutingWorkspaceEdge]]
  ) -> Set<UUID> {
    var reachable = Set([outputNodeID])
    var pending = [outputNodeID]
    while let nodeID = pending.popLast() {
      for edge in incomingEdges[nodeID] ?? []
      where reachable.insert(edge.source.nodeID).inserted {
        pending.append(edge.source.nodeID)
      }
    }
    return reachable
  }
}
