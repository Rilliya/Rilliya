import Foundation
import Observation
import RilliyaNetworkAudio
import RilliyaRealtime

enum RoutingNetworkSendState: Equatable {
  case idle
  case waitingForSource
  case starting
  case running(NetworkAudioStreamFormat)
  case failed(RoutingNodeFailure)
}

protocol RoutingNetworkSendSession: AnyObject, Sendable {
  var format: NetworkAudioStreamFormat { get }

  func stop() async
}

protocol RoutingNetworkSendStarting: Sendable {
  func start(
    configuration: RoutingNetworkSendConfiguration,
    rendererFactory:
      @escaping @Sendable (AudioRenderPreparation) throws ->
      RoutingPreparedAudioGraphSource,
    failureHandler: @escaping @Sendable (String) -> Void
  ) async throws -> any RoutingNetworkSendSession
}

struct SystemRoutingNetworkSendStarter: RoutingNetworkSendStarting {
  func start(
    configuration: RoutingNetworkSendConfiguration,
    rendererFactory:
      @escaping @Sendable (AudioRenderPreparation) throws ->
      RoutingPreparedAudioGraphSource,
    failureHandler: @escaping @Sendable (String) -> Void
  ) async throws -> any RoutingNetworkSendSession {
    // Built here, on the main actor, because the registry of key sources lives there. What it
    // builds is asked for its key later, off this actor, wherever the source needs to go.
    let keyProvider = try await MainActor.run { try configuration.secret?.provider() }
    return try await Task.detached(priority: .userInitiated) {
      let format = try NetworkAudioStreamFormat(
        sampleRate: configuration.sampleRate,
        channelCount: configuration.channelCount
      )
      let sender = try NetworkAudioSender(
        configuration: NetworkAudioSenderConfiguration(
          host: configuration.host,
          port: configuration.port,
          format: format,
          framesPerPacket: configuration.wire.encoding == .uncompressed
            ? RoutingRealtimeDestinationDefaults.renderQuantumFrameCount : nil,
          encoding: configuration.wire.encoding.libraryValue,
          opusBitRate: configuration.wire.bitRate,
          keyProvider: keyProvider
        )
      ) { error in
        failureHandler(error.localizedDescription)
      }
      let preparation = try AudioRenderPreparation(
        format: AudioProcessingFormat(
          sampleRate: format.sampleRate,
          channelCount: format.channelCount
        ),
        maximumFrameCount: RoutingRealtimeDestinationDefaults.renderQuantumFrameCount
      )
      let renderer = try rendererFactory(preparation)
      let driver = try RoutingPreparedGraphRealtimeDriver(
        renderer: renderer,
        frameCount: RoutingRealtimeDestinationDefaults.renderQuantumFrameCount,
        failureContext: "network",
        consumer: { pointers, frameCount in
          _ = sender.frameBuffer.writePlanar(pointers, frameCount: frameCount)
        },
        failureHandler: failureHandler
      )
      do {
        try await sender.start()
        try driver.start()
        return SystemRoutingNetworkSendSession(
          format: format,
          sender: sender,
          driver: driver
        )
      } catch {
        await sender.stop()
        throw error
      }
    }.value
  }
}

private final class SystemRoutingNetworkSendSession: RoutingNetworkSendSession,
  @unchecked Sendable
{
  let format: NetworkAudioStreamFormat

  private let sender: NetworkAudioSender
  private let driver: RoutingPreparedGraphRealtimeDriver

  init(
    format: NetworkAudioStreamFormat,
    sender: NetworkAudioSender,
    driver: RoutingPreparedGraphRealtimeDriver
  ) {
    self.format = format
    self.sender = sender
    self.driver = driver
  }

  func stop() async {
    await driver.stop()
    await sender.stop()
  }
}

private struct RoutingNetworkSendNodeSignature: Equatable, Sendable {
  let id: UUID
  let value: RoutingNodeValue
}

private struct RoutingNetworkSendSourceSignature: Equatable, Sendable {
  let nodeID: UUID
  let identity: ObjectIdentifier
}

private struct RoutingNetworkSendRequestSignature: Equatable, Sendable {
  let nodeID: UUID
  let configuration: RoutingNetworkSendConfiguration
  let nodes: [RoutingNetworkSendNodeSignature]
  let edges: [RoutingWorkspaceEdge]
  let sources: [RoutingNetworkSendSourceSignature]
}

private struct RoutingNetworkSendRequest: Sendable {
  let signature: RoutingNetworkSendRequestSignature
  let nodes: [RoutingWorkspaceNode]
  let edges: [RoutingWorkspaceEdge]
  let captureSources: [UUID: RoutingRealtimeCaptureSource]
}

private enum RoutingNetworkSendPlan {
  case idle
  case waiting
  case blocked(RoutingNodeFailure)
  case ready(RoutingNetworkSendRequest)
}

private enum RoutingNetworkSendDesiredState: Equatable {
  case idle
  case waiting
  case blocked(RoutingNodeFailure)
  case ready(RoutingNetworkSendRequestSignature)
}

extension RoutingNetworkSendPlan {
  fileprivate var desiredState: RoutingNetworkSendDesiredState {
    switch self {
    case .idle: .idle
    case .waiting: .waiting
    case .blocked(let message): .blocked(message)
    case .ready(let request): .ready(request.signature)
    }
  }
}

@MainActor
@Observable
final class RoutingNetworkSendController {
  private struct RunningSession {
    let signature: RoutingNetworkSendRequestSignature
    let session: any RoutingNetworkSendSession
    let renderer: RoutingPreparedAudioGraphSource
  }

  private(set) var states: [UUID: RoutingNetworkSendState] = [:]

  @ObservationIgnored private let starter: any RoutingNetworkSendStarting
  @ObservationIgnored private var sessions: [UUID: RunningSession] = [:]
  @ObservationIgnored private var lifecycleTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var generations: [UUID: UInt64] = [:]
  @ObservationIgnored private var desiredStates: [UUID: RoutingNetworkSendDesiredState] = [:]
  @ObservationIgnored private var latestRequests: [UUID: RoutingNetworkSendRequest] = [:]
  @ObservationIgnored private var captureCursorCache = RoutingCaptureCursorCache()

  init(starter: any RoutingNetworkSendStarting = SystemRoutingNetworkSendStarter()) {
    self.starter = starter
  }

  func state(for nodeID: UUID) -> RoutingNetworkSendState {
    states[nodeID] ?? .idle
  }

  func reconcile(
    workflows: [RoutingWorkflowModel],
    captureController: RoutingCaptureController,
    inputCaptureController: RoutingInputCaptureController,
    outputCaptureController: RoutingOutputCaptureController = RoutingOutputCaptureController(),
    filePlaybackController: RoutingFilePlaybackController,
    networkReceiveController: RoutingNetworkReceiveController
  ) {
    let plans = makePlans(
      workflows: workflows,
      captureController: captureController,
      inputCaptureController: inputCaptureController,
      outputCaptureController: outputCaptureController,
      filePlaybackController: filePlaybackController,
      networkReceiveController: networkReceiveController
    )
    let nodeIDs = Set(plans.keys)
      .union(states.keys)
      .union(sessions.keys)
      .union(lifecycleTasks.keys)
    for nodeID in nodeIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
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
    for nodeID in Set(states.keys).union(sessions.keys).union(lifecycleTasks.keys) {
      apply(.idle, to: nodeID)
    }
    captureCursorCache.removeAll()
  }

  private func apply(_ plan: RoutingNetworkSendPlan, to nodeID: UUID) {
    let desired = plan.desiredState
    if case .ready(let request) = plan {
      latestRequests[nodeID] = request
      if let running = sessions[nodeID],
        running.signature == request.signature,
        lifecycleTasks[nodeID] == nil
      {
        do {
          try running.renderer.updateControls(nodes: request.nodes)
          desiredStates[nodeID] = desired
          states[nodeID] = .running(running.session.format)
        } catch {
          apply(.blocked(RoutingNodeFailure(error)), to: nodeID)
        }
        return
      }
    } else {
      latestRequests[nodeID] = nil
    }
    guard desiredStates[nodeID] != desired else { return }
    desiredStates[nodeID] = desired
    let generation = (generations[nodeID] ?? 0) &+ 1
    generations[nodeID] = generation
    let previous = lifecycleTasks[nodeID]
    lifecycleTasks[nodeID] = Task { @MainActor [weak self] in
      await previous?.value
      guard let self, generations[nodeID] == generation else { return }
      await transition(to: plan, nodeID: nodeID, generation: generation)
      if generations[nodeID] == generation { lifecycleTasks[nodeID] = nil }
    }
  }

  private func transition(
    to plan: RoutingNetworkSendPlan,
    nodeID: UUID,
    generation: UInt64
  ) async {
    if let running = sessions.removeValue(forKey: nodeID) {
      await running.session.stop()
    }
    guard generations[nodeID] == generation else { return }
    switch plan {
    case .idle:
      states[nodeID] = .idle
    case .waiting:
      states[nodeID] = .waitingForSource
    case .blocked(let failure):
      states[nodeID] = .failed(failure)
    case .ready(let request):
      states[nodeID] = .starting
      let rendererHolder = RoutingNetworkSendRendererHolder()
      let rendererFactory:
        @Sendable (AudioRenderPreparation) throws ->
          RoutingPreparedAudioGraphSource = { preparation in
            let renderer = try RoutingPreparedAudioGraphSource(
              preparation: preparation,
              nodes: request.nodes,
              edges: request.edges,
              outputNodeID: request.signature.nodeID,
              captureSources: request.captureSources
            )
            rendererHolder.store(renderer)
            return renderer
          }
      let failureHandler: @Sendable (String) -> Void = { [weak self] message in
        Task { @MainActor [weak self] in
          guard let self, generations[nodeID] == generation else { return }
          apply(.blocked(RoutingNodeFailure(message: message)), to: nodeID)
        }
      }
      do {
        let session = try await starter.start(
          configuration: request.signature.configuration,
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
        if let latest = latestRequests[nodeID], latest.signature == request.signature {
          try renderer.updateControls(nodes: latest.nodes)
        }
        sessions[nodeID] = RunningSession(
          signature: request.signature,
          session: session,
          renderer: renderer
        )
        states[nodeID] = .running(session.format)
      } catch {
        guard generations[nodeID] == generation else { return }
        // Clearing the desired state here restarts the failed plan on every reconciliation.
        states[nodeID] = .failed(RoutingNodeFailure(error))
      }
    }
  }

  private func makePlans(
    workflows: [RoutingWorkflowModel],
    captureController: RoutingCaptureController,
    inputCaptureController: RoutingInputCaptureController,
    outputCaptureController: RoutingOutputCaptureController,
    filePlaybackController: RoutingFilePlaybackController,
    networkReceiveController: RoutingNetworkReceiveController
  ) -> [UUID: RoutingNetworkSendPlan] {
    var plans: [UUID: RoutingNetworkSendPlan] = [:]
    var claimedBuffers = clockedSourceBuffersFeedingDeviceOutputs(
      workflows: workflows,
      captureController: captureController,
      inputCaptureController: inputCaptureController,
      outputCaptureController: outputCaptureController,
      filePlaybackController: filePlaybackController,
      networkReceiveController: networkReceiveController
    )
    var activeCaptureCursorKeys = Set<RoutingCaptureCursorKey>()

    for workflow in workflows where workflow.isRunning {
      let workspace = workflow.workspace
      let activeEdges = workspace.edges.filter(workspace.isEdgeActive)
      let incomingEdges = Dictionary(grouping: activeEdges, by: { $0.target.nodeID })
      for sendNode in workspace.nodes {
        guard case .networkSend(let configuration) = sendNode.value else { continue }
        guard incomingEdges[sendNode.id]?.isEmpty == false else {
          plans[sendNode.id] = .idle
          continue
        }
        let reachable = Self.reachableNodeIDs(from: sendNode.id, incomingEdges: incomingEdges)
        let nodes = workspace.nodes.filter { reachable.contains($0.id) }
        let edges = activeEdges.filter {
          reachable.contains($0.source.nodeID) && reachable.contains($0.target.nodeID)
        }
        var captureSources: [UUID: RoutingRealtimeCaptureSource] = [:]
        var candidateCaptureCursorKeys = Set<RoutingCaptureCursorKey>()
        var waiting = false
        var failure: RoutingNodeFailure?
        for node in nodes {
          let source: RoutingRealtimeCaptureSource?
          switch node.value {
          case .applicationAudio:
            source = captureCursorCache.resolvedSource(
              for: node.id,
              consumerID: sendNode.id,
              provider: captureController,
              activeKeys: &candidateCaptureCursorKeys,
              failure: &failure
            )
          case .inputAudio:
            source = captureCursorCache.resolvedSource(
              for: node.id,
              consumerID: sendNode.id,
              provider: inputCaptureController,
              activeKeys: &candidateCaptureCursorKeys,
              failure: &failure
            )
          case .virtualOutput:
            source = captureCursorCache.resolvedSource(
              for: node.id,
              consumerID: sendNode.id,
              provider: inputCaptureController,
              activeKeys: &candidateCaptureCursorKeys,
              failure: &failure
            )
          case .systemOutput:
            source = captureCursorCache.resolvedSource(
              for: node.id,
              consumerID: sendNode.id,
              provider: outputCaptureController,
              activeKeys: &candidateCaptureCursorKeys,
              failure: &failure
            )
            if case .failed(let sourceFailure) = outputCaptureController.state(for: node.id) {
              failure = sourceFailure
            }
          case .filePlayback:
            source = filePlaybackController.frameBuffer(for: node.id).map {
              .throttledFrameBuffer($0)
            }
            if case .failed(let sourceFailure) = filePlaybackController.state(for: node.id) {
              failure = sourceFailure
            }
          case .networkReceive:
            source = captureCursorCache.resolvedSource(
              for: node.id,
              consumerID: sendNode.id,
              provider: networkReceiveController,
              activeKeys: &candidateCaptureCursorKeys,
              failure: &failure
            )
            if case .failed(let sourceFailure) = networkReceiveController.state(for: node.id) {
              failure = sourceFailure
            }
          default:
            continue
          }
          guard let source else {
            waiting = true
            continue
          }
          captureSources[node.id] = source
        }
        if let failure {
          plans[sendNode.id] = .blocked(failure)
          continue
        }
        guard !waiting else {
          plans[sendNode.id] = .waiting
          continue
        }
        let localBuffers = Set(captureSources.values.map(\.identity))
        guard claimedBuffers.isDisjoint(with: localBuffers) else {
          plans[sendNode.id] = .blocked(
            RoutingNodeFailure(
              summary: "Source already in use",
              message:
                "This source hands out one independently paced queue per destination and has no more left. Remove a destination, or raise the source's destination limit."
            )
          )
          continue
        }
        claimedBuffers.formUnion(localBuffers)
        let sortedNodes = nodes.sorted { $0.id.uuidString < $1.id.uuidString }
        let sortedEdges = edges.sorted { $0.id.uuidString < $1.id.uuidString }
        let sources = captureSources.map {
          RoutingNetworkSendSourceSignature(nodeID: $0.key, identity: $0.value.identity)
        }.sorted { $0.nodeID.uuidString < $1.nodeID.uuidString }
        let signature = RoutingNetworkSendRequestSignature(
          nodeID: sendNode.id,
          configuration: configuration,
          nodes: sortedNodes.map {
            RoutingNetworkSendNodeSignature(
              id: $0.id,
              value: $0.value.audioOutputTopologySignatureValue
            )
          },
          edges: sortedEdges,
          sources: sources
        )
        plans[sendNode.id] = .ready(
          RoutingNetworkSendRequest(
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

  private func clockedSourceBuffersFeedingDeviceOutputs(
    workflows: [RoutingWorkflowModel],
    captureController: RoutingCaptureController,
    inputCaptureController: RoutingInputCaptureController,
    outputCaptureController: RoutingOutputCaptureController,
    filePlaybackController: RoutingFilePlaybackController,
    networkReceiveController: RoutingNetworkReceiveController
  ) -> Set<ObjectIdentifier> {
    var result = Set<ObjectIdentifier>()
    for workflow in workflows where workflow.isRunning {
      let workspace = workflow.workspace
      let activeEdges = workspace.edges.filter(workspace.isEdgeActive)
      let incomingEdges = Dictionary(grouping: activeEdges, by: { $0.target.nodeID })
      for outputNode in workspace.nodes {
        switch outputNode.value {
        case .outputAudio(let selection, _) where selection != nil:
          break
        case .virtualInput(let selection, _) where selection != nil:
          break
        default:
          continue
        }
        let reachable = Self.reachableNodeIDs(from: outputNode.id, incomingEdges: incomingEdges)
        for node in workspace.nodes where reachable.contains(node.id) {
          let buffer: AudioRealtimeFrameBuffer?
          switch node.value {
          case .applicationAudio:
            buffer = captureController.frameBuffer(for: node.id)
          case .inputAudio:
            buffer = inputCaptureController.frameBuffer(for: node.id)
          case .virtualOutput:
            buffer = inputCaptureController.frameBuffer(for: node.id)
          case .systemOutput:
            buffer = outputCaptureController.frameBuffer(for: node.id)
          case .filePlayback:
            buffer = filePlaybackController.frameBuffer(for: node.id)
          case .networkReceive:
            // Answered from the session rather than a queue: asking for a queue would claim one of
            // this stream's destinations and give it straight back.
            buffer = nil
            if let identity = networkReceiveController.captureSessionIdentity(for: node.id) {
              result.insert(identity)
            }
          default:
            buffer = nil
          }
          if let buffer {
            result.insert(ObjectIdentifier(buffer))
          }
        }
      }
    }
    return result
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

private final class RoutingNetworkSendRendererHolder: @unchecked Sendable {
  private let lock = NSLock()
  private var value: RoutingPreparedAudioGraphSource?

  var renderer: RoutingPreparedAudioGraphSource? { lock.withLock { value } }

  func store(_ renderer: RoutingPreparedAudioGraphSource) {
    lock.withLock { value = renderer }
  }
}
