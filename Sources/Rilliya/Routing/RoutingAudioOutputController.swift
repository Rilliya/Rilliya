import Foundation
import Observation
import os
import RilliyaCapture
import RilliyaCore
import RilliyaPlayback
import RilliyaRealtime
import RilliyaVirtualAudio

enum RoutingAudioOutputState: Equatable {
  case idle
  case waitingForCapture
  case starting
  case running(DeviceOutputPlaybackFormat)
  case failed(RoutingNodeFailure)
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

  /// Where a node measured inside the graph reports what it sounds like.
  let meterHandler: RoutingPreparedAudioGraphSource.MeterHandler?
}

private enum RoutingAudioOutputPlan {
  case idle
  case waitingForCapture
  case blocked(RoutingNodeFailure)
  case ready(RoutingAudioOutputRequest)
}

private enum RoutingAudioOutputDesiredState: Equatable {
  case idle
  case waitingForCapture
  case blocked(RoutingNodeFailure)
  case ready(RoutingAudioOutputRequestSignature)
}

enum RoutingAudioOutputSelectionResolver {
  static func resolve(
    _ selection: RoutingAudioOutputSelection?,
    catalogSnapshot: AudioCatalogSnapshot?
  ) throws -> RoutingOutputDeviceSelection? {
    switch selection {
    case nil:
      return nil
    case .device(let selection):
      return selection
    case .systemDefault:
      guard
        let device = catalogSnapshot?.outputDevices.first(where: {
          $0.isAlive && $0.output?.isDefault == true
        })
      else {
        throw DeviceOutputCaptureError.noDefaultOutputDevice
      }
      return RoutingOutputDeviceSelection(id: device.id, displayName: device.name)
    }
  }
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

/// Which device an output settled on, and only while building for debugging.
///
/// A node reads as running whether it is playing to the device the reader expects or not, which is
/// the one thing that cannot be seen from outside while diagnosing why nothing is audible. It is
/// not something a shipped build should spend anything on, so outside a debug build this is
/// nothing.
private enum OutputDiagnostics {
  #if DEBUG
    private static let log = Logger(subsystem: "moe.uwucocoa.rilliya", category: "audio-output")
  #endif

  /// Reports one output starting or refusing to.
  static func report(_ message: @autoclosure () -> String) {
    #if DEBUG
      let text = message()
      log.debug("\(text, privacy: .public)")
    #endif
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
    audioCatalogSnapshot: AudioCatalogSnapshot? = nil,
    virtualAudioCatalog: VirtualAudioEndpointCatalog = .empty
  ) {
    let plans = makePlans(
      workflows: workflows,
      captureController: captureController,
      inputCaptureController: inputCaptureController,
      outputCaptureController: outputCaptureController,
      filePlaybackController: filePlaybackController,
      networkReceiveController: networkReceiveController,
      audioCatalogSnapshot: audioCatalogSnapshot,
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
          apply(.blocked(RoutingNodeFailure(error)), to: nodeID)
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
      case .blocked(let failure):
        if states[nodeID] == .failed(failure) { return }
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
    case .blocked(let failure):
      states[nodeID] = .failed(failure)
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
          captureSources: request.captureSources,
          meterHandler: request.meterHandler
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
        // Which device an output actually settled on, and at what rate, is otherwise invisible:
        // a node reads as running whether it is playing to the device the reader expects or not.
        OutputDiagnostics.report(
          """
          output \(nodeID.uuidString) running on \(request.signature.deviceID.rawValue) \
          at \(session.format.sampleRate) Hz, \(session.format.channelIDs.count) channels
          """)
      } catch {
        guard generations[nodeID] == generation else { return }
        // Clearing the desired state here restarts the failed plan on every reconciliation.
        OutputDiagnostics.report(
          "output \(nodeID.uuidString) failed to start: \(String(describing: error))")
        states[nodeID] = .failed(RoutingNodeFailure(error))
      }
    }
  }

  private func receiveFailure(
    _ error: DeviceOutputPlaybackError,
    nodeID: UUID,
    generation: UInt64
  ) {
    guard generations[nodeID] == generation else { return }
    apply(.blocked(RoutingNodeFailure(error)), to: nodeID)
  }

  private func makePlans(
    workflows: [RoutingWorkflowModel],
    captureController: RoutingCaptureController,
    inputCaptureController: RoutingInputCaptureController,
    outputCaptureController: RoutingOutputCaptureController,
    filePlaybackController: RoutingFilePlaybackController,
    networkReceiveController: RoutingNetworkReceiveController,
    audioCatalogSnapshot: AudioCatalogSnapshot?,
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
        var selectionFailure: RoutingNodeFailure?
        switch outputNode.value {
        case .outputAudio(let physicalSelection, _):
          do {
            selection = try RoutingAudioOutputSelectionResolver.resolve(
              physicalSelection,
              catalogSnapshot: audioCatalogSnapshot
            )
          } catch {
            selection = nil
            selectionFailure = RoutingNodeFailure(error)
          }
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
        let hasIncomingAudio = incomingEdges[outputNode.id]?.isEmpty == false
        if let selectionFailure, hasIncomingAudio {
          plans[outputNode.id] = .blocked(selectionFailure)
          continue
        }
        guard let selection, hasIncomingAudio else {
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
        var sourceFailure: RoutingNodeFailure?
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
              failure: &sourceFailure
            )
          case .inputAudio:
            source = captureCursorCache.resolvedSource(
              for: node.id,
              consumerID: outputNode.id,
              provider: inputCaptureController,
              activeKeys: &candidateCaptureCursorKeys,
              failure: &sourceFailure
            )
          case .virtualOutput:
            source = captureCursorCache.resolvedSource(
              for: node.id,
              consumerID: outputNode.id,
              provider: inputCaptureController,
              activeKeys: &candidateCaptureCursorKeys,
              failure: &sourceFailure
            )
          case .systemOutput:
            source = captureCursorCache.resolvedSource(
              for: node.id,
              consumerID: outputNode.id,
              provider: outputCaptureController,
              activeKeys: &candidateCaptureCursorKeys,
              failure: &sourceFailure
            )
            if outputCaptureController.deviceID(for: node.id) == selection.id {
              feedsCapturedOutputDevice = true
            }
            if case .failed(let upstreamFailure) = outputCaptureController.state(for: node.id) {
              sourceFailure = upstreamFailure
            }
          case .filePlayback:
            source = captureCursorCache.resolvedSource(
              for: node.id,
              consumerID: outputNode.id,
              provider: filePlaybackController,
              activeKeys: &candidateCaptureCursorKeys,
              failure: &sourceFailure
            )
            if case .failed(let upstreamFailure) = filePlaybackController.state(for: node.id) {
              sourceFailure = upstreamFailure
            }
          case .networkReceive:
            source = captureCursorCache.resolvedSource(
              for: node.id,
              consumerID: outputNode.id,
              provider: networkReceiveController,
              activeKeys: &candidateCaptureCursorKeys,
              failure: &sourceFailure
            )
            if case .failed(let upstreamFailure) = networkReceiveController.state(for: node.id) {
              sourceFailure = upstreamFailure
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
            RoutingNodeFailure(
              summary: "Feedback loop",
              message:
                "System Output cannot route back to the same physical output device. Choose a different destination to prevent feedback."
            )
          )
          continue
        }
        if let sourceFailure {
          plans[outputNode.id] = .blocked(sourceFailure)
          continue
        }
        guard !isWaitingForCapture else {
          plans[outputNode.id] = .waitingForCapture
          continue
        }

        let bufferIdentities = Set(captureSources.values.map(\.identity))
        guard claimedBuffers.isDisjoint(with: bufferIdentities) else {
          plans[outputNode.id] = .blocked(
            RoutingNodeFailure(
              summary: "Source already in use",
              message:
                "This source hands out one independently paced queue per destination and has no more left. Remove a destination, or raise the source's destination limit."
            )
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
            captureSources: captureSources,
            meterHandler: RoutingSignalGeneratorMeterController.shared.meterHandler()
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
