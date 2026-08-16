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
  case failed(String)
}

struct RoutingFilePlaybackRequest: Equatable, Sendable {
  let url: URL
  let sampleRate: Double
  let loopMode: RoutingFilePlaybackLoopMode
}

enum RoutingFilePlaybackRequirement: Equatable, Sendable {
  case ready(RoutingFilePlaybackRequest)
  case blocked(String)
}

protocol RoutingFilePlaybackSession: AnyObject, Sendable {
  var sourceDescription: AudioFileDescription { get }
  var frameBuffer: AudioRealtimeFrameBuffer { get }

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

  func stopAll() {
    reconcile(requirements: [:])
  }

  private func apply(_ requirement: RoutingFilePlaybackRequirement?, to nodeID: UUID) {
    if desiredRequirements[nodeID] == requirement {
      // An in-flight lifecycle already converges on this requirement. Restarting it here would
      // retire its generation, and publishing the resulting state change reenters this method,
      // so the session would never reach the graph.
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
    }
    desiredRequirements[nodeID] = requirement
    let generation = (generations[nodeID] ?? 0) &+ 1
    generations[nodeID] = generation
    pendingEvents[nodeID] = nil
    let previousTask = lifecycleTasks[nodeID]
    lifecycleTasks[nodeID] = Task { @MainActor [weak self] in
      await previousTask?.value
      guard let self, generations[nodeID] == generation else { return }
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
    case .blocked(let message):
      states[nodeID] = .failed(message)
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
        states[nodeID] = .streaming(session.sourceDescription)
        if let pending = pendingEvents.removeValue(forKey: nodeID),
          pending.0 == generation
        {
          receive(pending.1, nodeID: nodeID, generation: generation)
        }
      } catch {
        guard generations[nodeID] == generation else { return }
        desiredRequirements[nodeID] = nil
        states[nodeID] = .failed(error.localizedDescription)
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
      states[nodeID] = .failed(error.localizedDescription)
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
    var blocked: [UUID: String] = [:]

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
            blocked[node.id] =
              "One file source cannot feed output devices with different clocks. Add a clocked fan-out or sample-rate converter."
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
