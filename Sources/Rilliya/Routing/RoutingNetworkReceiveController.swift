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

  /// Claims one destination's paced view of this stream.
  ///
  /// Every destination gets its own, because each reads on its own clock: sharing one would let
  /// whichever destination read first take the audio away from the rest.
  func subscribeWithJitterBuffer() throws -> AudioJitterBuffer

  /// What the stream currently sounds like, per channel.
  ///
  /// Reading the queue would take the audio away from whatever is playing it, so what is drawn
  /// comes from the receiver's own meter instead.
  func meterSnapshot() -> [AudioChannelMeterSnapshot]

  /// Asks to be told whenever there is a new waveform, rather than having to poll for one.
  func onMeter(_ handler: (@Sendable ([AudioChannelMeterSnapshot]) -> Void)?)

  func stop() async
}

protocol RoutingNetworkReceiveStarting: Sendable {
  func start(
    configuration: RoutingNetworkReceiveConfiguration,
    waveformUpdatesPerSecond: Int,
    failureHandler: @escaping @Sendable (NetworkAudioReceiverError) -> Void
  ) async throws -> any RoutingNetworkReceiveSession
}

struct SystemRoutingNetworkReceiveStarter: RoutingNetworkReceiveStarting {
  /// How long a node adopting the sender's format waits before saying nothing arrived.
  ///
  /// Waiting without end would leave the start in flight for as long as the node exists, so the
  /// node reports it instead and the user retries once the other machine is sending.
  static let formatDiscoveryTimeout = Duration.seconds(60)

  func start(
    configuration: RoutingNetworkReceiveConfiguration,
    waveformUpdatesPerSecond: Int,
    failureHandler: @escaping @Sendable (NetworkAudioReceiverError) -> Void
  ) async throws -> any RoutingNetworkReceiveSession {
    // Built here, on the main actor, because the registry of key sources lives there.
    let keyProvider = try await MainActor.run { try configuration.secret?.provider() }
    return try await Task.detached(priority: .userInitiated) {
      let format =
        configuration.adoptsSenderFormat
        ? try await NetworkAudioFormatDiscovery.discover(
          port: configuration.port,
          keyProvider: keyProvider,
          timeout: SystemRoutingNetworkReceiveStarter.formatDiscoveryTimeout
        )
        : try NetworkAudioStreamFormat(
          sampleRate: configuration.sampleRate,
          channelCount: configuration.channelCount
        )
      let receiver = try NetworkAudioReceiver(
        configuration: NetworkAudioReceiverConfiguration(
          port: configuration.port,
          format: format,
          jitter: try configuration.jitter.resolve(),
          waveformUpdatesPerSecond: waveformUpdatesPerSecond,
          keyProvider: keyProvider
        ),
        failureHandler: failureHandler
      )
      do {
        try await receiver.start()
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

  private let receiver: NetworkAudioReceiver

  init(receiver: NetworkAudioReceiver, format: NetworkAudioStreamFormat) {
    self.receiver = receiver
    self.format = format
  }

  func subscribeWithJitterBuffer() throws -> AudioJitterBuffer {
    try receiver.subscribeWithJitterBuffer()
  }

  func meterSnapshot() -> [AudioChannelMeterSnapshot] {
    receiver.meterSnapshot()
  }

  func onMeter(_ handler: (@Sendable ([AudioChannelMeterSnapshot]) -> Void)?) {
    receiver.onMeter(handler)
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

  /// Claims one destination's view of this node's stream.
  ///
  /// A fresh one per call, because the caller is a destination and every destination reads on its
  /// own clock. Whoever asked keeps what it was given for as long as it is playing it; letting go
  /// of it returns the slot.
  func captureSource(for nodeID: UUID) throws -> RoutingRealtimeCaptureSource? {
    guard let configuration = configurationsByNode[nodeID],
      let source = sources[configuration],
      case .running(let session) = source.phase
    else { return nil }
    return .jitterBuffer(try session.subscribeWithJitterBuffer())
  }

  /// Identifies the stream behind this node without claiming a destination.
  ///
  /// Named for the cursor cache, which keys one consumer's claim on the session it was made
  /// against: a claim survives a graph rebuild only if the session it belongs to is still the
  /// same one.
  ///
  /// Handing out a queue to answer a question about identity would claim a destination slot and
  /// release it again the moment the answer was read, leaving whoever kept the queue reading one
  /// that had already been given to somebody else.
  func captureSessionIdentity(for nodeID: UUID) -> ObjectIdentifier? {
    guard let configuration = configurationsByNode[nodeID],
      let source = sources[configuration],
      case .running(let session) = source.phase
    else { return nil }
    return ObjectIdentifier(session)
  }

  /// What each running node currently sounds like.
  ///
  /// Written whenever a receiver has something new, because an interface redraws when observed
  /// state changes and never because a value it did not look at moved.
  private(set) var snapshots: [UUID: RoutingNetworkReceiveMeterSnapshot] = [:]

  /// How many times a second a running node reports its waveform.
  ///
  /// Taken from the application's preferences when a node starts. Changing it takes effect the
  /// next time one does, which is what restarting a node already does.
  var waveformUpdatesPerSecond = RilliyaSettings.shared.waveformUpdatesPerSecond

  func snapshot(for nodeID: UUID) -> RoutingNetworkReceiveMeterSnapshot? {
    snapshots[nodeID]
  }

  /// Points a running session's meter at this node's observed snapshot.
  private func observeMeter(of session: any RoutingNetworkReceiveSession, nodeID: UUID) {
    session.onMeter { [weak self] channels in
      Task { @MainActor in
        guard let self else { return }
        self.snapshots[nodeID] =
          channels.isEmpty
          ? nil
          : RoutingNetworkReceiveMeterSnapshot(channels: channels)
      }
    }
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
    snapshots[nodeID] = nil
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
    snapshots[nodeID] = nil
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
    // Read where the start is decided: a preference belongs to the application, not to a node,
    // so it is never written into a saved workflow.
    let rate = waveformUpdatesPerSecond
    let failureHandler: @Sendable (NetworkAudioReceiverError) -> Void = { [weak self] error in
      Task { @MainActor [weak self] in
        self?.receiveFailure(error, configuration: configuration, generation: generation)
      }
    }
    Task { @MainActor [weak self] in
      do {
        let session = try await starter.start(
          configuration: configuration,
          waveformUpdatesPerSecond: rate,
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
      observeMeter(of: session, nodeID: nodeID)
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

/// What a receive node currently sounds like, in the shape everything that draws audio reads.
struct RoutingNetworkReceiveMeterSnapshot: RoutingAudioMeterSnapshot {
  let channels: [AudioChannelMeterSnapshot]
}
