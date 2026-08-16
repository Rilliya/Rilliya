import Foundation
import Observation
import RilliyaCore
import RilliyaPlayback
import RilliyaRealtime
import RilliyaVirtualAudio

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

private final class RoutingPreparedAudioGraphHolder: @unchecked Sendable {
  private let lock = NSLock()
  private var storedRenderer: RoutingPreparedAudioGraphSource?

  var renderer: RoutingPreparedAudioGraphSource? {
    lock.withLock { storedRenderer }
  }

  func store(_ renderer: RoutingPreparedAudioGraphSource) {
    lock.withLock { storedRenderer = renderer }
  }
}

private struct RoutingAudioOutputNodeConfiguration: Equatable, Sendable {
  let id: UUID
  let value: RoutingNodeValue
}

extension RoutingNodeValue {
  var audioOutputTopologySignatureValue: RoutingNodeValue {
    switch self {
    case .noiseGate:
      .noiseGate(configuration: .initial)
    case .compressor:
      .compressor(configuration: .initial)
    case .gain:
      .gain(configuration: .initial)
    default:
      self
    }
  }
}

private struct RoutingAudioOutputSourceIdentity: Equatable, Sendable {
  let nodeID: UUID
  let identity: ObjectIdentifier
}

private struct RoutingAudioOutputRequestSignature: Equatable, Sendable {
  let outputNodeID: UUID
  let deviceID: AudioDeviceID
  let nodes: [RoutingAudioOutputNodeConfiguration]
  let edges: [RoutingWorkspaceEdge]
  let sources: [RoutingAudioOutputSourceIdentity]
}

private struct RoutingAudioOutputRequest: Sendable {
  let signature: RoutingAudioOutputRequestSignature
  let nodes: [RoutingWorkspaceNode]
  let edges: [RoutingWorkspaceEdge]
  let captureSources: [UUID: RoutingRealtimeCaptureSource]
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
    let renderer: RoutingPreparedAudioGraphSource
  }

  private(set) var states: [UUID: RoutingAudioOutputState] = [:]

  @ObservationIgnored private let playbackStarter: any RoutingOutputPlaybackStarting
  @ObservationIgnored private var runningSessions: [UUID: RunningSession] = [:]
  @ObservationIgnored private var lifecycleTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var generations: [UUID: UInt64] = [:]
  @ObservationIgnored private var desiredStates: [UUID: RoutingAudioOutputDesiredState] = [:]
  @ObservationIgnored private var latestRequests: [UUID: RoutingAudioOutputRequest] = [:]
  @ObservationIgnored private var captureCursorCache = RoutingCaptureCursorCache()

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
    inputCaptureController: RoutingInputCaptureController,
    outputCaptureController: RoutingOutputCaptureController = RoutingOutputCaptureController(),
    filePlaybackController: RoutingFilePlaybackController = RoutingFilePlaybackController(),
    networkReceiveController: RoutingNetworkReceiveController = RoutingNetworkReceiveController(),
    virtualAudioCatalog: VirtualAudioEndpointCatalog = .empty
  ) {
    let plans = makePlans(
      workflows: workflows,
      captureController: captureController,
      inputCaptureController: inputCaptureController,
      outputCaptureController: outputCaptureController,
      filePlaybackController: filePlaybackController,
      networkReceiveController: networkReceiveController,
      virtualAudioCatalog: virtualAudioCatalog
    )
    let knownNodeIDs = Set(plans.keys)
      .union(states.keys)
      .union(runningSessions.keys)
      .union(lifecycleTasks.keys)
    for nodeID in knownNodeIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      apply(plans[nodeID] ?? .idle, to: nodeID)
    }
  }

  /// Clears a latched failure so the next reconciliation starts the node again.
  func retry(nodeID: UUID) {
    guard case .failed = state(for: nodeID) else { return }
    desiredStates[nodeID] = nil
    states[nodeID] = .idle
  }

  func stopAll() {
    let nodeIDs = Set(states.keys)
      .union(runningSessions.keys)
      .union(lifecycleTasks.keys)
    for nodeID in nodeIDs {
      apply(.idle, to: nodeID)
    }
    captureCursorCache.removeAll()
  }

  private func apply(_ plan: RoutingAudioOutputPlan, to nodeID: UUID) {
    let desiredState = plan.desiredState
    if case .ready(let request) = plan {
      latestRequests[nodeID] = request
      if let runningSession = runningSessions[nodeID],
        runningSession.signature == request.signature,
        lifecycleTasks[nodeID] == nil
      {
        do {
          try runningSession.renderer.updateControls(nodes: request.nodes)
          desiredStates[nodeID] = desiredState
          states[nodeID] = .running(runningSession.session.format)
        } catch {
          apply(.blocked(error.localizedDescription), to: nodeID)
        }
        return
      }
    } else {
      latestRequests[nodeID] = nil
    }
    guard desiredStates[nodeID] != desiredState else { return }
    desiredStates[nodeID] = desiredState
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
      let rendererHolder = RoutingPreparedAudioGraphHolder()
      let rendererFactory: DeviceOutputPlayback.RendererFactory = { preparation in
        let renderer = try RoutingPreparedAudioGraphSource(
          preparation: preparation,
          nodes: request.nodes,
          edges: request.edges,
          outputNodeID: outputNodeID,
          captureSources: request.captureSources
        )
        rendererHolder.store(renderer)
        return renderer
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
        guard let renderer = rendererHolder.renderer else {
          await session.stop()
          throw RoutingPreparedAudioGraphError.invalidRoute
        }
        if let latestRequest = latestRequests[nodeID],
          latestRequest.signature == request.signature
        {
          try renderer.updateControls(nodes: latestRequest.nodes)
        }
        runningSessions[nodeID] = RunningSession(
          signature: request.signature,
          session: session,
          renderer: renderer
        )
        states[nodeID] = .running(session.format)
      } catch {
        guard generations[nodeID] == generation else { return }
        // Clearing the desired state here restarts the failed plan on every reconciliation.
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
    inputCaptureController: RoutingInputCaptureController,
    outputCaptureController: RoutingOutputCaptureController,
    filePlaybackController: RoutingFilePlaybackController,
    networkReceiveController: RoutingNetworkReceiveController,
    virtualAudioCatalog: VirtualAudioEndpointCatalog
  ) -> [UUID: RoutingAudioOutputPlan] {
    var plans: [UUID: RoutingAudioOutputPlan] = [:]
    var claimedBuffers = Set<ObjectIdentifier>()
    var activeCaptureCursorKeys = Set<RoutingCaptureCursorKey>()

    for workflow in workflows where workflow.isRunning {
      let workspace = workflow.workspace
      let activeEdges = workspace.edges.filter(workspace.isEdgeActive)
      let incomingEdges = Dictionary(grouping: activeEdges, by: { $0.target.nodeID })
      for outputNode in workspace.nodes {
        let selection: RoutingOutputDeviceSelection?
        switch outputNode.value {
        case .outputAudio(let physicalSelection, _):
          selection = physicalSelection
        case .virtualInput(let virtualSelection, _):
          selection = virtualSelection.flatMap { selection in
            guard
              let endpoint = virtualAudioCatalog.endpoint(id: selection.id),
              endpoint.configuration.direction == .input,
              let deviceID = AudioDeviceID(rawValue: endpoint.deviceUIDs.hostBridge)
            else { return nil }
            return RoutingOutputDeviceSelection(
              id: deviceID,
              displayName: endpoint.configuration.name
            )
          }
        default:
          continue
        }
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
        var captureSources: [UUID: RoutingRealtimeCaptureSource] = [:]
        var candidateCaptureCursorKeys = Set<RoutingCaptureCursorKey>()
        var isWaitingForCapture = false
        var sourceFailureMessage: String?
        var feedsCapturedOutputDevice = false
        for node in nodes {
          let source: RoutingRealtimeCaptureSource?
          switch node.value {
          case .applicationAudio:
            source = captureCursorCache.resolvedSource(
              for: node.id,
              consumerID: outputNode.id,
              provider: captureController,
              activeKeys: &candidateCaptureCursorKeys,
              failureMessage: &sourceFailureMessage
            )
          case .inputAudio:
            source = captureCursorCache.resolvedSource(
              for: node.id,
              consumerID: outputNode.id,
              provider: inputCaptureController,
              activeKeys: &candidateCaptureCursorKeys,
              failureMessage: &sourceFailureMessage
            )
          case .virtualOutput:
            source = captureCursorCache.resolvedSource(
              for: node.id,
              consumerID: outputNode.id,
              provider: inputCaptureController,
              activeKeys: &candidateCaptureCursorKeys,
              failureMessage: &sourceFailureMessage
            )
          case .systemOutput:
            source = captureCursorCache.resolvedSource(
              for: node.id,
              consumerID: outputNode.id,
              provider: outputCaptureController,
              activeKeys: &candidateCaptureCursorKeys,
              failureMessage: &sourceFailureMessage
            )
            if outputCaptureController.deviceID(for: node.id) == selection.id {
              feedsCapturedOutputDevice = true
            }
            if case .failed(let message) = outputCaptureController.state(for: node.id) {
              sourceFailureMessage = message
            }
          case .filePlayback:
            source = filePlaybackController.frameBuffer(for: node.id).map {
              .frameBuffer($0)
            }
            if case .failed(let message) = filePlaybackController.state(for: node.id) {
              sourceFailureMessage = message
            }
          case .networkReceive:
            source = networkReceiveController.frameBuffer(for: node.id).map {
              .frameBuffer($0)
            }
            if case .failed(let message) = networkReceiveController.state(for: node.id) {
              sourceFailureMessage = message
            }
          case .outputAudio, .virtualInput, .visualizer, .audioMixer, .gain, .channelRouter,
            .peakLevel, .signalGenerator, .fileOutput, .networkSend, .delay, .noiseGate,
            .compressor:
            continue
          }
          guard let source else {
            isWaitingForCapture = true
            continue
          }
          captureSources[node.id] = source
        }
        if feedsCapturedOutputDevice {
          plans[outputNode.id] = .blocked(
            "System Output cannot route back to the same physical output device. Choose a different destination to prevent feedback."
          )
          continue
        }
        if let sourceFailureMessage {
          plans[outputNode.id] = .blocked(sourceFailureMessage)
          continue
        }
        guard !isWaitingForCapture else {
          plans[outputNode.id] = .waitingForCapture
          continue
        }

        let bufferIdentities = Set(captureSources.values.map(\.identity))
        guard claimedBuffers.isDisjoint(with: bufferIdentities) else {
          plans[outputNode.id] = .blocked(
            "This source is already feeding another output clock. Add an explicit clocked fan-out before using multiple destinations."
          )
          continue
        }
        claimedBuffers.formUnion(bufferIdentities)

        let sortedNodes = nodes.sorted { $0.id.uuidString < $1.id.uuidString }
        let sortedEdges = edges.sorted { $0.id.uuidString < $1.id.uuidString }
        let sortedSources = captureSources.map {
          RoutingAudioOutputSourceIdentity(nodeID: $0.key, identity: $0.value.identity)
        }.sorted { $0.nodeID.uuidString < $1.nodeID.uuidString }
        let signature = RoutingAudioOutputRequestSignature(
          outputNodeID: outputNode.id,
          deviceID: selection.id,
          nodes: sortedNodes.map {
            RoutingAudioOutputNodeConfiguration(
              id: $0.id,
              value: $0.value.audioOutputTopologySignatureValue
            )
          },
          edges: sortedEdges,
          sources: sortedSources
        )
        plans[outputNode.id] = .ready(
          RoutingAudioOutputRequest(
            signature: signature,
            nodes: sortedNodes,
            edges: sortedEdges,
            captureSources: captureSources
          )
        )
        activeCaptureCursorKeys.formUnion(candidateCaptureCursorKeys)
      }
    }
    captureCursorCache.retain(activeCaptureCursorKeys)
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
