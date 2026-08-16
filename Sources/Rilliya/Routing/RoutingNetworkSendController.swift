import Foundation
import Observation
import RilliyaNetworkAudio
import RilliyaRealtime

enum RoutingNetworkSendState: Equatable {
  case idle
  case waitingForSource
  case starting
  case running(NetworkAudioStreamFormat)
  case failed(String)
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
  private static let renderQuantumFrameCount = 128

  func start(
    configuration: RoutingNetworkSendConfiguration,
    rendererFactory:
      @escaping @Sendable (AudioRenderPreparation) throws ->
      RoutingPreparedAudioGraphSource,
    failureHandler: @escaping @Sendable (String) -> Void
  ) async throws -> any RoutingNetworkSendSession {
    try await Task.detached(priority: .userInitiated) {
      let format = try NetworkAudioStreamFormat(
        sampleRate: configuration.sampleRate,
        channelCount: configuration.channelCount
      )
      let sender = try NetworkAudioSender(
        configuration: NetworkAudioSenderConfiguration(
          host: configuration.host,
          port: configuration.port,
          format: format
        )
      ) { error in
        failureHandler(error.localizedDescription)
      }
      let preparation = try AudioRenderPreparation(
        format: AudioProcessingFormat(
          sampleRate: format.sampleRate,
          channelCount: format.channelCount
        ),
        maximumFrameCount: Self.renderQuantumFrameCount
      )
      let renderer = try rendererFactory(preparation)
      let driver = RoutingNetworkSendDriver(
        sender: sender,
        renderer: renderer,
        frameCount: Self.renderQuantumFrameCount,
        failureHandler: failureHandler
      )
      do {
        try sender.start()
        driver.start()
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
  private let driver: RoutingNetworkSendDriver

  init(
    format: NetworkAudioStreamFormat,
    sender: NetworkAudioSender,
    driver: RoutingNetworkSendDriver
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

private final class RoutingNetworkSendDriver: @unchecked Sendable {
  private let sender: NetworkAudioSender
  private let renderer: RoutingPreparedAudioGraphSource
  private let frameCount: Int
  private let channelStorage: [UnsafeMutablePointer<Float>]
  private let channelPointers: [UnsafeMutablePointer<Float>]
  private let inputPointers: [UnsafePointer<Float>]
  private let failureHandler: @Sendable (String) -> Void
  private let lock = NSLock()
  private var task: Task<Void, Never>?

  init(
    sender: NetworkAudioSender,
    renderer: RoutingPreparedAudioGraphSource,
    frameCount: Int,
    failureHandler: @escaping @Sendable (String) -> Void
  ) {
    self.sender = sender
    self.renderer = renderer
    self.frameCount = frameCount
    self.failureHandler = failureHandler
    let storage = (0..<renderer.preparation.format.channelCount).map { _ in
      UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
    }
    channelStorage = storage
    channelPointers = storage
    inputPointers = storage.map { UnsafePointer($0) }
  }

  deinit {
    lock.withLock { task?.cancel() }
    for pointer in channelStorage { pointer.deallocate() }
  }

  func start() {
    lock.withLock {
      guard task == nil else { return }
      let sender = sender
      let renderer = renderer
      let frameCount = frameCount
      let pointers = channelPointers
      let inputPointers = inputPointers
      let failureHandler = failureHandler
      task = Task.detached(priority: .userInitiated) {
        let clock = ContinuousClock()
        let quantum = Duration.seconds(
          Double(frameCount) / renderer.preparation.format.sampleRate
        )
        var deadline = clock.now
        while !Task.isCancelled {
          let result = pointers.withUnsafeBufferPointer {
            renderer.render(outputChannels: $0, frameCount: frameCount)
          }
          guard result == .rendered else {
            failureHandler("The network graph rejected a render quantum: \(result).")
            return
          }
          inputPointers.withUnsafeBufferPointer { pointers in
            _ = sender.frameBuffer.writePlanar(pointers, frameCount: frameCount)
          }
          deadline += quantum
          if deadline < clock.now { deadline = clock.now }
          do {
            try await clock.sleep(until: deadline)
          } catch {
            return
          }
        }
      }
    }
  }

  func stop() async {
    let active = lock.withLock { () -> Task<Void, Never>? in
      let active = task
      task = nil
      return active
    }
    active?.cancel()
    await active?.value
  }
}

private struct RoutingNetworkSendNodeSignature: Equatable, Sendable {
  let id: UUID
  let value: RoutingNodeValue
}

private struct RoutingNetworkSendBufferSignature: Equatable, Sendable {
  let nodeID: UUID
  let identity: ObjectIdentifier
}

private struct RoutingNetworkSendRequestSignature: Equatable, Sendable {
  let nodeID: UUID
  let configuration: RoutingNetworkSendConfiguration
  let nodes: [RoutingNetworkSendNodeSignature]
  let edges: [RoutingWorkspaceEdge]
  let buffers: [RoutingNetworkSendBufferSignature]
}

private struct RoutingNetworkSendRequest: Sendable {
  let signature: RoutingNetworkSendRequestSignature
  let nodes: [RoutingWorkspaceNode]
  let edges: [RoutingWorkspaceEdge]
  let frameBuffers: [UUID: AudioRealtimeFrameBuffer]
}

private enum RoutingNetworkSendPlan {
  case idle
  case waiting
  case blocked(String)
  case ready(RoutingNetworkSendRequest)
}

private enum RoutingNetworkSendDesiredState: Equatable {
  case idle
  case waiting
  case blocked(String)
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
    case .blocked(let message):
      states[nodeID] = .failed(message)
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
        states[nodeID] = .running(session.format)
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
  ) -> [UUID: RoutingNetworkSendPlan] {
    var plans: [UUID: RoutingNetworkSendPlan] = [:]
    var claimedClockedSources = clockedSourceNodeIDsFeedingDeviceOutputs(workflows: workflows)

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
        let localClockedSources = Set(
          nodes.compactMap { node -> UUID? in
            switch node.value {
            case .applicationAudio, .inputAudio, .filePlayback, .networkReceive:
              node.id
            default:
              nil
            }
          })
        guard claimedClockedSources.isDisjoint(with: localClockedSources) else {
          plans[sendNode.id] = .blocked(
            "A captured or streamed source can feed only one independent output clock. Add an explicit clocked fan-out before sending it to multiple destinations."
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
          plans[sendNode.id] = .blocked(failure)
          continue
        }
        guard !waiting else {
          plans[sendNode.id] = .waiting
          continue
        }
        claimedClockedSources.formUnion(localClockedSources)
        let sortedNodes = nodes.sorted { $0.id.uuidString < $1.id.uuidString }
        let sortedEdges = edges.sorted { $0.id.uuidString < $1.id.uuidString }
        let buffers = frameBuffers.map {
          RoutingNetworkSendBufferSignature(nodeID: $0.key, identity: ObjectIdentifier($0.value))
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
          buffers: buffers
        )
        plans[sendNode.id] = .ready(
          RoutingNetworkSendRequest(
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

  private func clockedSourceNodeIDsFeedingDeviceOutputs(
    workflows: [RoutingWorkflowModel]
  ) -> Set<UUID> {
    var result = Set<UUID>()
    for workflow in workflows where workflow.isRunning {
      let workspace = workflow.workspace
      let activeEdges = workspace.edges.filter(workspace.isEdgeActive)
      let incomingEdges = Dictionary(grouping: activeEdges, by: { $0.target.nodeID })
      for outputNode in workspace.nodes {
        guard case .outputAudio(let selection, _) = outputNode.value, selection != nil else {
          continue
        }
        let reachable = Self.reachableNodeIDs(from: outputNode.id, incomingEdges: incomingEdges)
        for node in workspace.nodes where reachable.contains(node.id) {
          switch node.value {
          case .applicationAudio, .inputAudio, .filePlayback, .networkReceive:
            result.insert(node.id)
          default:
            break
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
