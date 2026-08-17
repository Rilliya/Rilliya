import Foundation
import Observation
import RilliyaCore
import RilliyaFilePlayback
import RilliyaRealtime

enum RoutingFilePlaybackState: Equatable {
  case idle
  case preparing
  case streaming(AudioFileDescription)
  case completed(AudioFileDescription)
  case failed(RoutingNodeFailure)
}

struct RoutingFilePlaybackRequest: Equatable, Sendable {
  let url: URL
  let sampleRate: Double
  let loopMode: RoutingFilePlaybackLoopMode
}

enum RoutingFilePlaybackRequirement: Equatable, Sendable {
  case ready(RoutingFilePlaybackRequest)
  case blocked(RoutingNodeFailure)
}

protocol RoutingFilePlaybackSession: AnyObject, Sendable {
  var sourceDescription: AudioFileDescription { get }
  var frameBuffer: AudioRealtimeFrameBuffer { get }

  /// What the file currently sounds like, per channel.
  ///
  /// Reading the queue would take the audio away from whatever is playing it, so what is drawn
  /// comes from the stream's own meter instead.
  func meterSnapshot() -> [AudioChannelMeterSnapshot]

  /// Asks to be told whenever there is a new waveform, rather than having to poll for one.
  func onMeter(_ handler: (@Sendable ([AudioChannelMeterSnapshot]) -> Void)?)

  func stop() async
}

protocol RoutingFilePlaybackStarting: Sendable {
  func start(
    request: RoutingFilePlaybackRequest,
    eventHandler: @escaping AudioFileFrameStream.EventHandler
  ) async throws -> any RoutingFilePlaybackSession
}

struct SystemRoutingFilePlaybackStarter: RoutingFilePlaybackStarting {
  func start(
    request: RoutingFilePlaybackRequest,
    eventHandler: @escaping AudioFileFrameStream.EventHandler
  ) async throws -> any RoutingFilePlaybackSession {
    try await Task.detached(priority: .userInitiated) {
      let stream = try AudioFileFrameStream(
        url: request.url,
        configuration: AudioFileFrameStreamConfiguration(
          sampleRate: request.sampleRate,
          loopMode: request.loopMode.filePlaybackLoopMode
        ),
        eventHandler: eventHandler
      )
      stream.start()
      return SystemRoutingFilePlaybackSession(stream: stream)
    }.value
  }
}

extension RoutingFilePlaybackLoopMode {
  fileprivate var filePlaybackLoopMode: AudioFileLoopMode {
    switch self {
    case .once: .once
    case .playCount(let count): .playCount(count)
    case .infinite: .infinite
    }
  }
}

private final class SystemRoutingFilePlaybackSession: RoutingFilePlaybackSession,
  @unchecked Sendable
{
  let sourceDescription: AudioFileDescription
  let frameBuffer: AudioRealtimeFrameBuffer

  private let stream: AudioFileFrameStream

  init(stream: AudioFileFrameStream) {
    self.stream = stream
    sourceDescription = stream.sourceDescription
    frameBuffer = stream.frameBuffer
  }

  func meterSnapshot() -> [AudioChannelMeterSnapshot] {
    stream.meterSnapshot()
  }

  func onMeter(_ handler: (@Sendable ([AudioChannelMeterSnapshot]) -> Void)?) {
    stream.onMeter(handler)
  }

  func stop() async {
    await stream.stop()
  }
}

@MainActor
@Observable
final class RoutingFilePlaybackController {
  private struct RunningSession {
    let request: RoutingFilePlaybackRequest
    let session: any RoutingFilePlaybackSession
  }

  private(set) var states: [UUID: RoutingFilePlaybackState] = [:]

  @ObservationIgnored private let starter: any RoutingFilePlaybackStarting
  @ObservationIgnored private var runningSessions: [UUID: RunningSession] = [:]
  @ObservationIgnored private var lifecycleTasks: [UUID: Task<Void, Never>] = [:]
  @ObservationIgnored private var generations: [UUID: UInt64] = [:]
  @ObservationIgnored private var desiredRequirements: [UUID: RoutingFilePlaybackRequirement] = [:]
  @ObservationIgnored private var pendingEvents: [UUID: (UInt64, AudioFileFrameStreamEvent)] = [:]

  init(starter: any RoutingFilePlaybackStarting = SystemRoutingFilePlaybackStarter()) {
    self.starter = starter
  }

  func state(for nodeID: UUID) -> RoutingFilePlaybackState {
    states[nodeID] ?? .idle
  }

  /// What each playing file currently sounds like.
  ///
  /// Written whenever a stream has something new, because an interface redraws when observed
  /// state changes and never because a value it did not look at moved.
  private(set) var snapshots: [UUID: RoutingFilePlaybackMeterSnapshot] = [:]

  func snapshot(for nodeID: UUID) -> RoutingFilePlaybackMeterSnapshot? {
    snapshots[nodeID]
  }

  private func observeMeter(of session: any RoutingFilePlaybackSession, nodeID: UUID) {
    session.onMeter { [weak self] channels in
      Task { @MainActor in
        guard let self else { return }
        self.snapshots[nodeID] =
          channels.isEmpty
          ? nil
          : RoutingFilePlaybackMeterSnapshot(channels: channels)
      }
    }
  }

  func frameBuffer(for nodeID: UUID) -> AudioRealtimeFrameBuffer? {
    switch states[nodeID] {
    case .streaming, .completed:
      runningSessions[nodeID]?.session.frameBuffer
    case .idle, .preparing, .failed, .none:
      nil
    }
  }

  func reconcile(requirements: [UUID: RoutingFilePlaybackRequirement]) {
    let knownNodeIDs = Set(requirements.keys)
      .union(states.keys)
      .union(runningSessions.keys)
      .union(lifecycleTasks.keys)
    for nodeID in knownNodeIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
      apply(requirements[nodeID], to: nodeID)
    }
  }

  /// Clears a latched failure so the next reconciliation starts the node again.
  func retry(nodeID: UUID) {
    guard case .failed = state(for: nodeID) else { return }
    states[nodeID] = .idle
  }

  func stopAll() {
    reconcile(requirements: [:])
  }

  private func apply(_ requirement: RoutingFilePlaybackRequirement?, to nodeID: UUID) {
    if desiredRequirements[nodeID] == requirement {
      // Retiring an in-flight lifecycle here would discard the session it is about to publish,
      // and publishing `preparing` reenters this method, so playback would never start.
      guard lifecycleTasks[nodeID] == nil else { return }
      if case .ready(let request) = requirement,
        runningSessions[nodeID]?.request == request
      {
        return
      }
      if requirement == nil, runningSessions[nodeID] == nil {
        states[nodeID] = .idle
        return
      }
      // Without this a start that cannot succeed restarts on every reconciliation.
      if case .failed = state(for: nodeID) { return }
    }
    desiredRequirements[nodeID] = requirement
    let generation = (generations[nodeID] ?? 0) &+ 1
    generations[nodeID] = generation
    pendingEvents[nodeID] = nil
    let previousTask = lifecycleTasks[nodeID]
    lifecycleTasks[nodeID] = Task { @MainActor [weak self] in
      await previousTask?.value
      guard let self, generations[nodeID] == generation else { return }
      snapshots[nodeID] = nil
      if let running = runningSessions.removeValue(forKey: nodeID) {
        await running.session.stop()
      }
      guard generations[nodeID] == generation else { return }
      await start(requirement, nodeID: nodeID, generation: generation)
      if generations[nodeID] == generation {
        lifecycleTasks[nodeID] = nil
      }
    }
  }

  private func start(
    _ requirement: RoutingFilePlaybackRequirement?,
    nodeID: UUID,
    generation: UInt64
  ) async {
    switch requirement {
    case .none:
      states[nodeID] = .idle
    case .blocked(let failure):
      states[nodeID] = .failed(failure)
    case .ready(let request):
      states[nodeID] = .preparing
      let eventHandler: AudioFileFrameStream.EventHandler = { [weak self] event in
        Task { @MainActor [weak self] in
          self?.receive(event, nodeID: nodeID, generation: generation)
        }
      }
      do {
        let session = try await starter.start(request: request, eventHandler: eventHandler)
        guard generations[nodeID] == generation else {
          await session.stop()
          return
        }
        runningSessions[nodeID] = RunningSession(request: request, session: session)
        observeMeter(of: session, nodeID: nodeID)
        states[nodeID] = .streaming(session.sourceDescription)
        if let pending = pendingEvents.removeValue(forKey: nodeID),
          pending.0 == generation
        {
          receive(pending.1, nodeID: nodeID, generation: generation)
        }
      } catch {
        guard generations[nodeID] == generation else { return }
        states[nodeID] = .failed(RoutingNodeFailure(error))
      }
    }
  }

  private func receive(
    _ event: AudioFileFrameStreamEvent,
    nodeID: UUID,
    generation: UInt64
  ) {
    guard generations[nodeID] == generation else {
      return
    }
    guard let running = runningSessions[nodeID] else {
      pendingEvents[nodeID] = (generation, event)
      return
    }
    switch event {
    case .completed:
      states[nodeID] = .completed(running.session.sourceDescription)
    case .failed(let error):
      states[nodeID] = .failed(RoutingNodeFailure(error))
    }
  }
}

enum RoutingFilePlaybackRequirementResolver {
  @MainActor
  static func resolve(
    workflows: [RoutingWorkflowModel],
    catalogSnapshot: AudioCatalogSnapshot?
  ) -> [UUID: RoutingFilePlaybackRequirement] {
    let sampleRates = Dictionary(
      uniqueKeysWithValues: (catalogSnapshot?.devices ?? []).map {
        ($0.id, $0.nominalSampleRate)
      }
    )
    var requests: [UUID: RoutingFilePlaybackRequest] = [:]
    var blocked: [UUID: RoutingNodeFailure] = [:]

    for workflow in workflows where workflow.isRunning {
      let workspace = workflow.workspace
      let activeEdges = workspace.edges.filter(workspace.isEdgeActive)
      let incomingEdges = Dictionary(grouping: activeEdges, by: { $0.target.nodeID })
      for outputNode in workspace.nodes {
        let sampleRate: Double
        switch outputNode.value {
        case .outputAudio(let selection, _):
          guard let selection,
            let deviceSampleRate = sampleRates[selection.id],
            deviceSampleRate.isFinite,
            deviceSampleRate > 0
          else { continue }
          sampleRate = deviceSampleRate
        case .networkSend(let configuration):
          sampleRate = configuration.sampleRate
        default:
          continue
        }
        let reachable = reachableNodeIDs(from: outputNode.id, incomingEdges: incomingEdges)
        for node in workspace.nodes where reachable.contains(node.id) {
          guard case .filePlayback(let configuration) = node.value,
            let file = configuration.selection
          else {
            continue
          }
          let request = RoutingFilePlaybackRequest(
            url: file.url,
            sampleRate: sampleRate,
            loopMode: configuration.loopMode
          )
          if let existing = requests[node.id], existing != request {
            blocked[node.id] = RoutingNodeFailure(
              summary: "Clock conflict",
              message:
                "One file source cannot feed output devices with different clocks. Add a clocked fan-out or sample-rate converter."
            )
          } else {
            requests[node.id] = request
          }
        }
      }
    }

    return requests.reduce(into: [:]) { result, pair in
      result[pair.key] =
        blocked[pair.key].map(RoutingFilePlaybackRequirement.blocked)
        ?? .ready(pair.value)
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

/// What a file playback node currently sounds like, in the shape everything that draws audio reads.
struct RoutingFilePlaybackMeterSnapshot: RoutingAudioMeterSnapshot {
  let channels: [AudioChannelMeterSnapshot]
}
