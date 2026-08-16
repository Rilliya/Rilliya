import Foundation
import Observation
import RilliyaFileWriting
import RilliyaRealtime

enum RoutingFileOutputState: Equatable {
  case idle
  case waitingForSource
  case starting
  case running(URL)
  case failed(String)
}

protocol RoutingFileOutputSession: AnyObject, Sendable {
  var outputURL: URL { get }

  func stop() async
}

protocol RoutingFileOutputStarting: Sendable {
  func start(
    configuration: RoutingFileOutputConfiguration,
    rendererFactory:
      @escaping @Sendable (AudioRenderPreparation) throws ->
      RoutingPreparedAudioGraphSource,
    failureHandler: @escaping @Sendable (String) -> Void
  ) async throws -> any RoutingFileOutputSession
}

struct SystemRoutingFileOutputStarter: RoutingFileOutputStarting {
  func start(
    configuration: RoutingFileOutputConfiguration,
    rendererFactory:
      @escaping @Sendable (AudioRenderPreparation) throws ->
      RoutingPreparedAudioGraphSource,
    failureHandler: @escaping @Sendable (String) -> Void
  ) async throws -> any RoutingFileOutputSession {
    guard let destination = configuration.destination else {
      throw RoutingFileOutputControllerError.missingDestination
    }
    return try await Task.detached(priority: .userInitiated) {
      let writerConfiguration = try AudioFileWriterConfiguration(
        destinationURL: destination.url,
        container: configuration.container,
        encoding: configuration.encoding,
        sampleRate: configuration.sampleRate,
        channelCount: configuration.channelCount,
        collisionPolicy: .appendSequenceNumber
      )
      let writer = try AudioFileWriter(
        configuration: writerConfiguration
      ) { event in
        guard case .failed(let error) = event else { return }
        failureHandler(error.localizedDescription)
      }
      let preparation = try AudioRenderPreparation(
        format: AudioProcessingFormat(
          sampleRate: configuration.sampleRate,
          channelCount: configuration.channelCount
        ),
        maximumFrameCount: RoutingRealtimeDestinationDefaults.renderQuantumFrameCount
      )
      let renderer = try rendererFactory(preparation)
      let outputURL = try await writer.start()
      let driver = RoutingPreparedGraphRealtimeDriver(
        renderer: renderer,
        frameCount: RoutingRealtimeDestinationDefaults.renderQuantumFrameCount,
        failureContext: "file",
        consumer: { pointers, frameCount in
          _ = writer.frameBuffer.writePlanar(pointers, frameCount: frameCount)
        },
        failureHandler: failureHandler
      )
      driver.start()
      return SystemRoutingFileOutputSession(
        outputURL: outputURL,
        writer: writer,
        driver: driver
      )
    }.value
  }
}

private enum RoutingFileOutputControllerError: Error, LocalizedError {
  case missingDestination

  var errorDescription: String? {
    "Choose a destination before running File Output."
  }
}

private final class SystemRoutingFileOutputSession: RoutingFileOutputSession,
  @unchecked Sendable
{
  let outputURL: URL

  private let writer: AudioFileWriter
  private let driver: RoutingPreparedGraphRealtimeDriver

  init(
    outputURL: URL,
    writer: AudioFileWriter,
    driver: RoutingPreparedGraphRealtimeDriver
  ) {
    self.outputURL = outputURL
    self.writer = writer
    self.driver = driver
  }

  func stop() async {
    await driver.stop()
    _ = await writer.stop()
  }
}

private struct RoutingFileOutputNodeSignature: Equatable, Sendable {
  let id: UUID
  let value: RoutingNodeValue
}

private struct RoutingFileOutputBufferSignature: Equatable, Sendable {
  let nodeID: UUID
  let identity: ObjectIdentifier
}

private struct RoutingFileOutputRequestSignature: Equatable, Sendable {
  let nodeID: UUID
  let configuration: RoutingFileOutputConfiguration
  let nodes: [RoutingFileOutputNodeSignature]
  let edges: [RoutingWorkspaceEdge]
  let buffers: [RoutingFileOutputBufferSignature]
}

private struct RoutingFileOutputRequest: Sendable {
  let signature: RoutingFileOutputRequestSignature
  let nodes: [RoutingWorkspaceNode]
  let edges: [RoutingWorkspaceEdge]
  let frameBuffers: [UUID: AudioRealtimeFrameBuffer]
}

private enum RoutingFileOutputPlan {
  case idle
  case waiting
  case blocked(String)
  case ready(RoutingFileOutputRequest)
}

private enum RoutingFileOutputDesiredState: Equatable {
  case idle
  case waiting
  case blocked(String)
  case ready(RoutingFileOutputRequestSignature)
}

extension RoutingFileOutputPlan {
  fileprivate var desiredState: RoutingFileOutputDesiredState {
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
final class RoutingFileOutputController {
  private struct RunningSession {
    let signature: RoutingFileOutputRequestSignature
    let session: any RoutingFileOutputSession
    let renderer: RoutingPreparedAudioGraphSource
  }

  private(set) var states: [UUID: RoutingFileOutputState] = [:]

  @ObservationIgnored private let starter: any RoutingFileOutputStarting
  @ObservationIgnored private var sessions: [UUID: RunningSession] = [:]
  @ObservationIgnored private var lifecycleTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var generations: [UUID: UInt64] = [:]
  @ObservationIgnored private var desiredStates: [UUID: RoutingFileOutputDesiredState] = [:]
  @ObservationIgnored private var latestRequests: [UUID: RoutingFileOutputRequest] = [:]

  init(starter: any RoutingFileOutputStarting = SystemRoutingFileOutputStarter()) {
    self.starter = starter
  }

  func state(for nodeID: UUID) -> RoutingFileOutputState {
    states[nodeID] ?? .idle
  }

  func reconcile(
    workflows: [RoutingWorkflowModel],
    captureController: RoutingCaptureController,
    inputCaptureController: RoutingInputCaptureController,
    filePlaybackController: RoutingFilePlaybackController,
    networkReceiveController: RoutingNetworkReceiveController
  ) {
    let plans = makePlans(
      workflows: workflows,
      captureController: captureController,
      inputCaptureController: inputCaptureController,
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

  func stopAll() {
    for nodeID in Set(states.keys).union(sessions.keys).union(lifecycleTasks.keys) {
      apply(.idle, to: nodeID)
    }
  }

  private func apply(_ plan: RoutingFileOutputPlan, to nodeID: UUID) {
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
          states[nodeID] = .running(running.session.outputURL)
        } catch {
          apply(.blocked(error.localizedDescription), to: nodeID)
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
    to plan: RoutingFileOutputPlan,
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
    case .blocked(let message):
      states[nodeID] = .failed(message)
    case .ready(let request):
      states[nodeID] = .starting
      let rendererHolder = RoutingFileOutputRendererHolder()
      let rendererFactory:
        @Sendable (AudioRenderPreparation) throws ->
          RoutingPreparedAudioGraphSource = { preparation in
            let renderer = try RoutingPreparedAudioGraphSource(
              preparation: preparation,
              nodes: request.nodes,
              edges: request.edges,
              outputNodeID: request.signature.nodeID,
              frameBuffers: request.frameBuffers
            )
            rendererHolder.store(renderer)
            return renderer
          }
      let failureHandler: @Sendable (String) -> Void = { [weak self] message in
        Task { @MainActor [weak self] in
          guard let self, generations[nodeID] == generation else { return }
          apply(.blocked(message), to: nodeID)
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
        states[nodeID] = .running(session.outputURL)
      } catch {
        guard generations[nodeID] == generation else { return }
        desiredStates[nodeID] = nil
        states[nodeID] = .failed(error.localizedDescription)
      }
    }
  }

  private func makePlans(
    workflows: [RoutingWorkflowModel],
    captureController: RoutingCaptureController,
    inputCaptureController: RoutingInputCaptureController,
    filePlaybackController: RoutingFilePlaybackController,
    networkReceiveController: RoutingNetworkReceiveController
  ) -> [UUID: RoutingFileOutputPlan] {
    var plans: [UUID: RoutingFileOutputPlan] = [:]
    var claimedClockedSources = clockedSourcesClaimedByOtherDestinations(workflows: workflows)

    for workflow in workflows where workflow.isRunning {
      let workspace = workflow.workspace
      let activeEdges = workspace.edges.filter(workspace.isEdgeActive)
      let incomingEdges = Dictionary(grouping: activeEdges, by: { $0.target.nodeID })
      for outputNode in workspace.nodes {
        guard case .fileOutput(let configuration) = outputNode.value else { continue }
        guard configuration.destination != nil,
          incomingEdges[outputNode.id]?.isEmpty == false
        else {
          plans[outputNode.id] = .idle
          continue
        }
        let reachable = Self.reachableNodeIDs(
          from: outputNode.id,
          incomingEdges: incomingEdges
        )
        let nodes = workspace.nodes.filter { reachable.contains($0.id) }
        let edges = activeEdges.filter {
          reachable.contains($0.source.nodeID) && reachable.contains($0.target.nodeID)
        }
        let localClockedSources = Set(nodes.compactMap(Self.clockedSourceNodeID))
        guard claimedClockedSources.isDisjoint(with: localClockedSources) else {
          plans[outputNode.id] = .blocked(
            "A captured or streamed source can feed only one independent output clock. Add an explicit clocked fan-out before recording it to multiple destinations."
          )
          continue
        }

        var frameBuffers: [UUID: AudioRealtimeFrameBuffer] = [:]
        var waiting = false
        var failure: String?
        for node in nodes {
          let buffer: AudioRealtimeFrameBuffer?
          switch node.value {
          case .applicationAudio:
            buffer = captureController.frameBuffer(for: node.id)
          case .inputAudio:
            buffer = inputCaptureController.frameBuffer(for: node.id)
          case .filePlayback:
            buffer = filePlaybackController.frameBuffer(for: node.id)
            if case .failed(let message) = filePlaybackController.state(for: node.id) {
              failure = message
            }
          case .networkReceive:
            buffer = networkReceiveController.frameBuffer(for: node.id)
            if case .failed(let message) = networkReceiveController.state(for: node.id) {
              failure = message
            }
          default:
            continue
          }
          guard let buffer else {
            waiting = true
            continue
          }
          frameBuffers[node.id] = buffer
        }
        if let failure {
          plans[outputNode.id] = .blocked(failure)
          continue
        }
        guard !waiting else {
          plans[outputNode.id] = .waiting
          continue
        }
        claimedClockedSources.formUnion(localClockedSources)
        let sortedNodes = nodes.sorted { $0.id.uuidString < $1.id.uuidString }
        let sortedEdges = edges.sorted { $0.id.uuidString < $1.id.uuidString }
        let buffers = frameBuffers.map {
          RoutingFileOutputBufferSignature(nodeID: $0.key, identity: ObjectIdentifier($0.value))
        }.sorted { $0.nodeID.uuidString < $1.nodeID.uuidString }
        let signature = RoutingFileOutputRequestSignature(
          nodeID: outputNode.id,
          configuration: configuration,
          nodes: sortedNodes.map {
            RoutingFileOutputNodeSignature(
              id: $0.id,
              value: $0.value.audioOutputTopologySignatureValue
            )
          },
          edges: sortedEdges,
          buffers: buffers
        )
        plans[outputNode.id] = .ready(
          RoutingFileOutputRequest(
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

  private func clockedSourcesClaimedByOtherDestinations(
    workflows: [RoutingWorkflowModel]
  ) -> Set<UUID> {
    var result = Set<UUID>()
    for workflow in workflows where workflow.isRunning {
      let workspace = workflow.workspace
      let activeEdges = workspace.edges.filter(workspace.isEdgeActive)
      let incomingEdges = Dictionary(grouping: activeEdges, by: { $0.target.nodeID })
      for destination in workspace.nodes {
        switch destination.value {
        case .outputAudio(let selection, _) where selection != nil:
          break
        case .networkSend:
          break
        default:
          continue
        }
        let reachable = Self.reachableNodeIDs(
          from: destination.id,
          incomingEdges: incomingEdges
        )
        for node in workspace.nodes where reachable.contains(node.id) {
          if let sourceID = Self.clockedSourceNodeID(node) { result.insert(sourceID) }
        }
      }
    }
    return result
  }

  private static func clockedSourceNodeID(_ node: RoutingWorkspaceNode) -> UUID? {
    switch node.value {
    case .applicationAudio, .inputAudio, .filePlayback, .networkReceive:
      node.id
    default:
      nil
    }
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

private final class RoutingFileOutputRendererHolder: @unchecked Sendable {
  private let lock = NSLock()
  private var value: RoutingPreparedAudioGraphSource?

  var renderer: RoutingPreparedAudioGraphSource? { lock.withLock { value } }

  func store(_ renderer: RoutingPreparedAudioGraphSource) {
    lock.withLock { value = renderer }
  }
}
