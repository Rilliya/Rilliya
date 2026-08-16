import Foundation
import RilliyaFilePlayback
import RilliyaRealtime
import Testing

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
    #expect(controller.frameBuffer(for: nodeID) != nil)
    #expect(await starter.currentStartCount() == 1)

    controller.reconcile(requirements: [nodeID: .ready(request)])
    #expect(await starter.currentStartCount() == 1)
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
}

private actor FakeRoutingFilePlaybackStarter: RoutingFilePlaybackStarting {
  struct Counts: Equatable, Sendable {
    let starts: Int
    let stops: Int
  }

  private(set) var startCount = 0
  private(set) var stopCount = 0
  private let completesBeforeReturning: Bool

  init(completesBeforeReturning: Bool = false) {
    self.completesBeforeReturning = completesBeforeReturning
  }

  func start(
    request: RoutingFilePlaybackRequest,
    eventHandler: @escaping AudioFileFrameStream.EventHandler
  ) async throws -> any RoutingFilePlaybackSession {
    startCount += 1
    let description = try AudioFileDescription(
      sampleRate: request.sampleRate,
      channelCount: 1,
      frameCount: 4
    )
    let buffer = try AudioRealtimeFrameBuffer(
      format: AudioProcessingFormat(sampleRate: request.sampleRate, channelCount: 1),
      capacityFrameCount: 8
    )
    if completesBeforeReturning {
      eventHandler(.completed)
    }
    return FakeRoutingFilePlaybackSession(
      sourceDescription: description,
      frameBuffer: buffer
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
  nonisolated let frameBuffer: AudioRealtimeFrameBuffer

  private let stopHandler: @Sendable () async -> Void
  private var isStopped = false

  init(
    sourceDescription: AudioFileDescription,
    frameBuffer: AudioRealtimeFrameBuffer,
    stopHandler: @escaping @Sendable () async -> Void
  ) {
    self.sourceDescription = sourceDescription
    self.frameBuffer = frameBuffer
    self.stopHandler = stopHandler
  }

  func stop() async {
    guard !isStopped else { return }
    isStopped = true
    await stopHandler()
  }
}
