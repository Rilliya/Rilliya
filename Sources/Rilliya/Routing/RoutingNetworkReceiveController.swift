import Foundation
import Observation
import RilliyaNetworkAudio
import RilliyaRealtime

enum RoutingNetworkReceiveState: Equatable {
  case idle
  case starting
  case running(NetworkAudioStreamFormat)
  case failed(RoutingNodeFailure)
}

protocol RoutingNetworkReceiveSession: AnyObject, Sendable {
  var format: NetworkAudioStreamFormat { get }
  var jitterBuffer: AudioJitterBuffer { get }

  func stop() async
}

protocol RoutingNetworkReceiveStarting: Sendable {
  func start(
    configuration: RoutingNetworkReceiveConfiguration,
    failureHandler: @escaping @Sendable (NetworkAudioReceiverError) -> Void
  ) async throws -> any RoutingNetworkReceiveSession
}

struct SystemRoutingNetworkReceiveStarter: RoutingNetworkReceiveStarting {
  func start(
    configuration: RoutingNetworkReceiveConfiguration,
    failureHandler: @escaping @Sendable (NetworkAudioReceiverError) -> Void
  ) async throws -> any RoutingNetworkReceiveSession {
    try await Task.detached(priority: .userInitiated) {
      let format = try NetworkAudioStreamFormat(
        sampleRate: configuration.sampleRate,
        channelCount: configuration.channelCount
      )
      let receiver = try NetworkAudioReceiver(
        configuration: NetworkAudioReceiverConfiguration(
          port: configuration.port,
          format: format
        ),
        failureHandler: failureHandler
      )
      do {
        try receiver.start()
        return SystemRoutingNetworkReceiveSession(receiver: receiver, format: format)
      } catch {
        receiver.stop()
        throw error
      }
    }.value
  }
}

private final class SystemRoutingNetworkReceiveSession: RoutingNetworkReceiveSession,
  @unchecked Sendable
{
  let format: NetworkAudioStreamFormat
  let jitterBuffer: AudioJitterBuffer

  private let receiver: NetworkAudioReceiver

  init(receiver: NetworkAudioReceiver, format: NetworkAudioStreamFormat) {
    self.receiver = receiver
    self.format = format
    jitterBuffer = receiver.jitterBuffer
  }

  func stop() async {
    receiver.stop()
  }
}

@MainActor
@Observable
final class RoutingNetworkReceiveController {
  private enum SharedSourcePhase {
    case starting
    case running(any RoutingNetworkReceiveSession)
    case stopping
  }

  private struct SharedSource {
    var nodeIDs: Set<UUID>
    var phase: SharedSourcePhase
    var generation: UInt64
  }

  private(set) var states: [UUID: RoutingNetworkReceiveState] = [:]

  @ObservationIgnored private let starter: any RoutingNetworkReceiveStarting
  @ObservationIgnored private var sources: [RoutingNetworkReceiveConfiguration: SharedSource] = [:]
  @ObservationIgnored private var configurationsByNode: [UUID: RoutingNetworkReceiveConfiguration] =
    [:]
  @ObservationIgnored private var failedConfigurations: [UUID: RoutingNetworkReceiveConfiguration] =
    [:]
  @ObservationIgnored private var nextGeneration: UInt64 = 0

  init(starter: any RoutingNetworkReceiveStarting = SystemRoutingNetworkReceiveStarter()) {
    self.starter = starter
  }

  func state(for nodeID: UUID) -> RoutingNetworkReceiveState {
    states[nodeID] ?? .idle
  }

  func captureSource(for nodeID: UUID) -> RoutingRealtimeCaptureSource? {
    guard let configuration = configurationsByNode[nodeID],
      let source = sources[configuration],
      case .running(let session) = source.phase
    else { return nil }
    return .jitterBuffer(session.jitterBuffer)
  }

  func frameBuffer(for nodeID: UUID) -> AudioRealtimeFrameBuffer? {
    guard case .jitterBuffer(let jitterBuffer) = captureSource(for: nodeID) else { return nil }
    return jitterBuffer.frameBuffer
  }

  func reconcile(requirements: [UUID: RoutingNetworkReceiveConfiguration]) {
    for (nodeID, configuration) in Array(configurationsByNode)
    where requirements[nodeID] != configuration {
      detach(nodeID: nodeID, publishesIdleState: true)
    }
    for (nodeID, configuration) in requirements.sorted(by: {
      $0.key.uuidString < $1.key.uuidString
    }) {
      start(nodeID: nodeID, configuration: configuration)
    }
  }

  /// Clears a latched failure so the next reconciliation opens the listener again.
  func retry(nodeID: UUID) {
    guard case .failed = state(for: nodeID) else { return }
    failedConfigurations[nodeID] = nil
    states[nodeID] = .idle
  }

  func stopAll() {
    failedConfigurations.removeAll()
    for nodeID in Array(configurationsByNode.keys) {
      detach(nodeID: nodeID, publishesIdleState: true)
    }
  }

  private func start(nodeID: UUID, configuration: RoutingNetworkReceiveConfiguration) {
    if failedConfigurations[nodeID] == configuration { return }
    if configurationsByNode[nodeID] == configuration,
      let source = sources[configuration],
      source.nodeIDs.contains(nodeID)
    {
      synchronizeNode(nodeID, with: source)
      return
    }

    detach(nodeID: nodeID, publishesIdleState: false)
    configurationsByNode[nodeID] = configuration
    if var source = sources[configuration] {
      source.nodeIDs.insert(nodeID)
      sources[configuration] = source
      synchronizeNode(nodeID, with: source)
      return
    }

    let generation = makeGeneration()
    sources[configuration] = SharedSource(
      nodeIDs: [nodeID],
      phase: .starting,
      generation: generation
    )
    states[nodeID] = .starting
    beginStart(configuration: configuration, generation: generation)
  }

  private func detach(nodeID: UUID, publishesIdleState: Bool) {
    if publishesIdleState { states[nodeID] = .idle }
    guard let configuration = configurationsByNode.removeValue(forKey: nodeID),
      var source = sources[configuration]
    else { return }
    source.nodeIDs.remove(nodeID)
    sources[configuration] = source
    guard source.nodeIDs.isEmpty else { return }
    switch source.phase {
    case .starting, .stopping:
      return
    case .running(let session):
      source.phase = .stopping
      sources[configuration] = source
      beginStop(session, configuration: configuration, generation: source.generation)
    }
  }

  private func beginStart(
    configuration: RoutingNetworkReceiveConfiguration,
    generation: UInt64
  ) {
    let starter = starter
    let failureHandler: @Sendable (NetworkAudioReceiverError) -> Void = { [weak self] error in
      Task { @MainActor [weak self] in
        self?.receiveFailure(error, configuration: configuration, generation: generation)
      }
    }
    Task { @MainActor [weak self] in
      do {
        let session = try await starter.start(
          configuration: configuration,
          failureHandler: failureHandler
        )
        guard let self else {
          await session.stop()
          return
        }
        finishStart(session, configuration: configuration, generation: generation)
      } catch {
        self?.failStart(error, configuration: configuration, generation: generation)
      }
    }
  }

  private func finishStart(
    _ session: any RoutingNetworkReceiveSession,
    configuration: RoutingNetworkReceiveConfiguration,
    generation: UInt64
  ) {
    guard var source = sources[configuration], source.generation == generation,
      case .starting = source.phase
    else {
      Task { await session.stop() }
      return
    }
    if source.nodeIDs.isEmpty {
      source.phase = .stopping
      sources[configuration] = source
      beginStop(session, configuration: configuration, generation: generation)
      return
    }
    source.phase = .running(session)
    sources[configuration] = source
    for nodeID in source.nodeIDs where configurationsByNode[nodeID] == configuration {
      states[nodeID] = .running(session.format)
    }
  }

  private func failStart(
    _ error: any Error,
    configuration: RoutingNetworkReceiveConfiguration,
    generation: UInt64
  ) {
    guard let source = sources[configuration], source.generation == generation,
      case .starting = source.phase
    else { return }
    sources[configuration] = nil
    for nodeID in source.nodeIDs where configurationsByNode[nodeID] == configuration {
      configurationsByNode[nodeID] = nil
      failedConfigurations[nodeID] = configuration
      states[nodeID] = .failed(RoutingNodeFailure(error))
    }
  }

  private func receiveFailure(
    _ error: NetworkAudioReceiverError,
    configuration: RoutingNetworkReceiveConfiguration,
    generation: UInt64
  ) {
    guard var source = sources[configuration], source.generation == generation,
      case .running(let session) = source.phase
    else { return }
    let nodeIDs = source.nodeIDs
    source.nodeIDs.removeAll()
    source.phase = .stopping
    sources[configuration] = source
    for nodeID in nodeIDs where configurationsByNode[nodeID] == configuration {
      configurationsByNode[nodeID] = nil
      states[nodeID] = .failed(RoutingNodeFailure(error))
    }
    beginStop(session, configuration: configuration, generation: generation)
  }

  private func beginStop(
    _ session: any RoutingNetworkReceiveSession,
    configuration: RoutingNetworkReceiveConfiguration,
    generation: UInt64
  ) {
    Task { @MainActor [weak self] in
      await session.stop()
      self?.finishStop(configuration: configuration, generation: generation)
    }
  }

  private func finishStop(
    configuration: RoutingNetworkReceiveConfiguration,
    generation: UInt64
  ) {
    guard var source = sources[configuration], source.generation == generation,
      case .stopping = source.phase
    else { return }
    guard !source.nodeIDs.isEmpty else {
      sources[configuration] = nil
      return
    }
    source.phase = .starting
    source.generation = makeGeneration()
    sources[configuration] = source
    for nodeID in source.nodeIDs where configurationsByNode[nodeID] == configuration {
      states[nodeID] = .starting
    }
    beginStart(configuration: configuration, generation: source.generation)
  }

  private func synchronizeNode(_ nodeID: UUID, with source: SharedSource) {
    switch source.phase {
    case .starting, .stopping:
      states[nodeID] = .starting
    case .running(let session):
      states[nodeID] = .running(session.format)
    }
  }

  private func makeGeneration() -> UInt64 {
    nextGeneration &+= 1
    return nextGeneration
  }
}

enum RoutingNetworkReceiveRequirementResolver {
  @MainActor
  static func resolve(
    workflows: [RoutingWorkflowModel]
  ) -> [UUID: RoutingNetworkReceiveConfiguration] {
    var result: [UUID: RoutingNetworkReceiveConfiguration] = [:]
    for workflow in workflows where workflow.isRunning {
      let sourceNodeIDs = workflow.workspace.captureSourceNodeIDs
      for node in workflow.workspace.nodes where sourceNodeIDs.contains(node.id) {
        guard case .networkReceive(let configuration) = node.value else { continue }
        result[node.id] = configuration
      }
    }
    return result
  }
}
