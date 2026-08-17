import Foundation
import RilliyaFilePlayback
import RilliyaRealtime
import Testing
import os.lock
@testable import Rilliya

struct RoutingFilePlaybackControllerTests {
  @Test @MainActor
  func completedEventCannotRacePreparedSessionPublication() async throws {
    let starter = FakeRoutingFilePlaybackStarter(completesBeforeReturning: true)
    let controller = RoutingFilePlaybackController(starter: starter)
    let nodeID = UUID()
    let request = RoutingFilePlaybackRequest(
      url: URL(fileURLWithPath: "/tmp/test.caf"),
      sampleRate: 48_000,
      loopMode: .once
    )

    controller.reconcile(requirements: [nodeID: .ready(request)])

    #expect(
      await eventually {
        if case .completed = controller.state(for: nodeID) { return true }
        return false
      }
    )
    #expect(try controller.captureSource(for: nodeID) != nil)
    #expect(await starter.currentStartCount() == 1)

    controller.reconcile(requirements: [nodeID: .ready(request)])
    #expect(await starter.currentStartCount() == 1)
  }

  /// Publishing `preparing` reenters reconciliation, so an unchanged requirement must not retire
  /// the lifecycle that is still starting; otherwise playback never reaches the graph.
  @Test @MainActor
  func reconcilingAnUnchangedRequirementDuringStartupKeepsTheSession() async throws {
    let starter = FakeRoutingFilePlaybackStarter(suspendsUntilReleased: true)
    let controller = RoutingFilePlaybackController(starter: starter)
    let nodeID = UUID()
    let request = RoutingFilePlaybackRequest(
      url: URL(fileURLWithPath: "/tmp/source.wav"),
      sampleRate: 48_000,
      loopMode: .infinite
    )

    controller.reconcile(requirements: [nodeID: .ready(request)])
    #expect(await eventually { await starter.currentStartCount() == 1 })
    for _ in 0..<FilePlaybackTestConstants.reconcileAttempts {
      controller.reconcile(requirements: [nodeID: .ready(request)])
    }
    await starter.release()

    #expect(await eventually { (try? controller.captureSource(for: nodeID)) ?? nil != nil })
    #expect(await starter.currentStartCount() == 1)
    #expect(await starter.currentStopCount() == 0)
  }

  /// Reconciliation reruns whenever any observed audio state changes, so a failure that restarts
  /// on an unchanged requirement spins the node between preparing and failed.
  @Test @MainActor
  func aFailedStartDoesNotRestartOnAnUnchangedRequirement() async throws {
    let starter = FakeRoutingFilePlaybackStarter(failsWith: FilePlaybackTestError.unreadable)
    let controller = RoutingFilePlaybackController(starter: starter)
    let nodeID = UUID()
    let request = RoutingFilePlaybackRequest(
      url: URL(fileURLWithPath: "/tmp/missing.wav"),
      sampleRate: 48_000,
      loopMode: .infinite
    )

    controller.reconcile(requirements: [nodeID: .ready(request)])
    #expect(await eventually { controller.state(for: nodeID).isFailed })
    #expect(await starter.currentStartCount() == 1)

    for _ in 0..<FilePlaybackTestConstants.reconcileAttempts {
      controller.reconcile(requirements: [nodeID: .ready(request)])
      await Task.yield()
    }
    #expect(controller.state(for: nodeID).isFailed)
    #expect(await starter.currentStartCount() == 1)

    controller.retry(nodeID: nodeID)
    controller.reconcile(requirements: [nodeID: .ready(request)])
    #expect(await eventually { await starter.currentStartCount() == 2 })
  }

  @Test @MainActor
  func networkSendResolvesAFilePlaybackSourceAtItsOwnSampleRate() throws {
    let playbackID = UUID()
    let sendID = UUID()
    let url = URL(fileURLWithPath: "/tmp/source.m4a")
    let workspace = try RoutingWorkspaceModel(
      restoringID: UUID(),
      nodes: [
        RoutingWorkspaceNode(
          id: playbackID,
          value: .filePlayback(
            configuration: RoutingFilePlaybackConfiguration(
              selection: RoutingAudioFileSelection(
                url: url,
                displayName: "Source",
                channelCount: 2,
                nativeSampleRate: 44_100
              ),
              loopMode: .infinite
            )
          ),
          frame: CGRect(x: 0, y: 0, width: 252, height: 128)
        ),
        RoutingWorkspaceNode(
          id: sendID,
          value: .networkSend(
            configuration: RoutingNetworkSendConfiguration(
              host: "10.0.0.2",
              port: 48_620,
              sampleRate: 48_000,
              channelCount: 2
            )
          ),
          frame: CGRect(x: 500, y: 0, width: 252, height: 128)
        ),
      ],
      edges: [
        RoutingWorkspaceEdge(
          id: UUID(),
          source: RoutingWorkspacePortAddress(
            nodeID: playbackID,
            portID: RoutingGraphPortID(direction: .output, channel: .all)
          ),
          target: RoutingWorkspacePortAddress(
            nodeID: sendID,
            portID: RoutingGraphPortID(direction: .input, channel: .all)
          )
        )
      ]
    )
    let workflow = RoutingWorkflowModel(
      name: "Flow",
      workspace: workspace,
      isRunning: true
    )

    let requirements = RoutingFilePlaybackRequirementResolver.resolve(
      workflows: [workflow],
      catalogSnapshot: nil
    )

    #expect(
      requirements[playbackID]
        == .ready(
          RoutingFilePlaybackRequest(url: url, sampleRate: 48_000, loopMode: .infinite)
        )
    )
  }

  @Test @MainActor
  func replacementWaitsForPreviousSessionTeardown() async throws {
    let starter = FakeRoutingFilePlaybackStarter()
    let controller = RoutingFilePlaybackController(starter: starter)
    let nodeID = UUID()
    let first = RoutingFilePlaybackRequest(
      url: URL(fileURLWithPath: "/tmp/first.caf"),
      sampleRate: 48_000,
      loopMode: .infinite
    )
    let second = RoutingFilePlaybackRequest(
      url: URL(fileURLWithPath: "/tmp/second.caf"),
      sampleRate: 44_100,
      loopMode: .playCount(2)
    )

    controller.reconcile(requirements: [nodeID: .ready(first)])
    #expect(await eventually { await starter.currentStartCount() == 1 })
    controller.reconcile(requirements: [nodeID: .ready(second)])

    #expect(
      await eventually {
        await starter.counts() == FakeRoutingFilePlaybackStarter.Counts(starts: 2, stops: 1)
      }
    )
    guard case .streaming = controller.state(for: nodeID) else {
      Issue.record("The replacement file stream did not become active.")
      return
    }

    controller.stopAll()
    #expect(await eventually { await starter.currentStopCount() == 2 })
    #expect(controller.state(for: nodeID) == .idle)
  }

  @MainActor
  private func eventually(
    _ predicate: @MainActor () async -> Bool
  ) async -> Bool {
    for _ in 0..<200 where !(await predicate()) {
      await Task.yield()
    }
    return await predicate()
  }
  /// One file reaching several destinations, which is what the canvas lets a reader draw.
  ///
  /// A file source used to hand every destination the same queue, so whichever read first took the
  /// audio and the second could only be refused.
  @Test @MainActor
  func destinationsOfOneFileEachGetTheirOwnQueue() async throws {
    let nodeID = UUID()
    let controller = RoutingFilePlaybackController(starter: FakeRoutingFilePlaybackStarter())
    controller.reconcile(
      requirements: [
        nodeID: .ready(
          RoutingFilePlaybackRequest(
            url: URL(fileURLWithPath: "/tmp/test.caf"),
            sampleRate: 48_000,
            loopMode: .once
          )
        )
      ]
    )
    #expect(await eventually { (try? controller.captureSource(for: nodeID)) ?? nil != nil })

    let one = try #require(try controller.captureSource(for: nodeID))
    let other = try #require(try controller.captureSource(for: nodeID))
    #expect(one.identity != other.identity, "two destinations were handed the same queue")

    // A file owes each destination the same sequence, so a backlog is audio still owed and
    // trimming it would skip the file rather than catch anything up.
    #expect(one.discardOldestFrames(keepingLatest: 0) == 0)
  }

  /// A graph rebuild must not spend a destination, or playback stops after a few of them.
  @Test @MainActor
  func repeatedRebuildsDoNotSpendFileDestinations() async throws {
    let nodeID = UUID()
    let consumer = UUID()
    let controller = RoutingFilePlaybackController(starter: FakeRoutingFilePlaybackStarter())
    controller.reconcile(
      requirements: [
        nodeID: .ready(
          RoutingFilePlaybackRequest(
            url: URL(fileURLWithPath: "/tmp/test.caf"),
            sampleRate: 48_000,
            loopMode: .once
          )
        )
      ]
    )
    #expect(await eventually { (try? controller.captureSource(for: nodeID)) ?? nil != nil })

    var cache = RoutingCaptureCursorCache()
    var identities: Set<ObjectIdentifier> = []
    for _ in 0..<50 {
      var activeKeys = Set<RoutingCaptureCursorKey>()
      var failure: RoutingNodeFailure?
      let source = cache.resolvedSource(
        for: nodeID,
        consumerID: consumer,
        provider: controller,
        activeKeys: &activeKeys,
        failure: &failure
      )
      #expect(failure == nil, "a rebuild ran out of destinations")
      identities.insert(try #require(source).identity)
      cache.retain(activeKeys)
    }
    #expect(identities.count == 1, "one consumer was handed \(identities.count) destinations")
  }

}

private actor FakeRoutingFilePlaybackStarter: RoutingFilePlaybackStarting {
  struct Counts: Equatable, Sendable {
    let starts: Int
    let stops: Int
  }

  private(set) var startCount = 0
  private(set) var stopCount = 0
  private let completesBeforeReturning: Bool
  private let suspendsUntilReleased: Bool
  private let failure: (any Error)?
  private var suspendedStarts: [CheckedContinuation<Void, Never>] = []

  init(
    completesBeforeReturning: Bool = false,
    suspendsUntilReleased: Bool = false,
    failsWith failure: (any Error)? = nil
  ) {
    self.completesBeforeReturning = completesBeforeReturning
    self.suspendsUntilReleased = suspendsUntilReleased
    self.failure = failure
  }

  func release() {
    let suspended = suspendedStarts
    suspendedStarts.removeAll()
    for continuation in suspended { continuation.resume() }
  }

  func start(
    request: RoutingFilePlaybackRequest,
    waveformUpdatesPerSecond: Int,
    eventHandler: @escaping AudioFileFrameStream.EventHandler
  ) async throws -> any RoutingFilePlaybackSession {
    startCount += 1
    if suspendsUntilReleased {
      await withCheckedContinuation { suspendedStarts.append($0) }
    }
    if let failure { throw failure }
    let description = try AudioFileDescription(
      sampleRate: request.sampleRate,
      channelCount: 1,
      frameCount: 4
    )
    let distributor = try AudioRealtimeFrameDistributor(
      format: AudioProcessingFormat(sampleRate: request.sampleRate, channelCount: 1),
      capacityFrameCount: 8,
      maximumSubscriberCount: 4
    )
    if completesBeforeReturning {
      eventHandler(.completed)
    }
    return FakeRoutingFilePlaybackSession(
      sourceDescription: description,
      distributor: distributor
    ) { [self] in
      await recordStop()
    }
  }

  func currentStartCount() -> Int { startCount }

  func currentStopCount() -> Int { stopCount }

  func counts() -> Counts { Counts(starts: startCount, stops: stopCount) }

  private func recordStop() {
    stopCount += 1
  }
}

private actor FakeRoutingFilePlaybackSession: RoutingFilePlaybackSession {
  nonisolated let sourceDescription: AudioFileDescription
  nonisolated let distributor: AudioRealtimeFrameDistributor
  /// What a fake file sounds like, which the tests here do not exercise.
  nonisolated let meterChannels: [AudioChannelMeterSnapshot] = []
  private let handler = OSAllocatedUnfairLock<
    (@Sendable ([AudioChannelMeterSnapshot]) -> Void)?
  >(initialState: nil)

  nonisolated func subscribe() throws -> AudioRealtimeFrameSubscription {
    try distributor.subscribe()
  }

  nonisolated func meterSnapshot() -> [AudioChannelMeterSnapshot] { meterChannels }

  nonisolated func onMeter(_ handler: (@Sendable ([AudioChannelMeterSnapshot]) -> Void)?) {
    self.handler.withLock { $0 = handler }
  }

  /// Pretends a new interval arrived, as a playing file's meter would.
  nonisolated func publish(_ channels: [AudioChannelMeterSnapshot]) {
    handler.withLock { $0 }?(channels)
  }

  private let stopHandler: @Sendable () async -> Void
  private var isStopped = false

  init(
    sourceDescription: AudioFileDescription,
    distributor: AudioRealtimeFrameDistributor,
    stopHandler: @escaping @Sendable () async -> Void
  ) {
    self.sourceDescription = sourceDescription
    self.distributor = distributor
    self.stopHandler = stopHandler
  }

  func stop() async {
    guard !isStopped else { return }
    isStopped = true
    await stopHandler()
  }
}

private enum FilePlaybackTestConstants {
  static let reconcileAttempts = 5
}

private enum FilePlaybackTestError: Error, LocalizedError {
  case unreadable

  var errorDescription: String? { "The audio file cannot be read." }
}

extension RoutingFilePlaybackState {
  fileprivate var isFailed: Bool {
    guard case .failed = self else { return false }
    return true
  }
}
