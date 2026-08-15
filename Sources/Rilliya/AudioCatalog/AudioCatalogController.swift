import Foundation
import Observation
import RilliyaKit

protocol AudioCatalogLoading: Sendable {
  func snapshot() async throws -> AudioCatalogSnapshot
  func updates() -> AsyncThrowingStream<AudioCatalogSnapshot, any Error>
}

extension AudioCatalogLoading {
  func updates() -> AsyncThrowingStream<AudioCatalogSnapshot, any Error> {
    let loader = self
    return AsyncThrowingStream { continuation in
      let task = Task.detached(priority: .utility) {
        do {
          continuation.yield(try await loader.snapshot())
          continuation.finish()
        } catch is CancellationError {
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }
}

struct SystemAudioCatalogLoader: AudioCatalogLoading {
  private let discovery: AudioCatalogDiscovery

  init(discovery: AudioCatalogDiscovery = AudioCatalogDiscovery()) {
    self.discovery = discovery
  }

  func snapshot() async throws -> AudioCatalogSnapshot {
    let task = Task.detached(priority: .userInitiated) {
      try discovery.snapshot()
    }
    let snapshot = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
    try Task.checkCancellation()
    return snapshot
  }

  func updates() -> AsyncThrowingStream<AudioCatalogSnapshot, any Error> {
    discovery.updates()
  }
}

struct AudioCatalogViewState: Equatable {
  private(set) var snapshot: AudioCatalogSnapshot?
  private(set) var rootErrorMessage: String?
  private(set) var isLoading = false

  var isInitialLoad: Bool {
    isLoading && snapshot == nil
  }

  mutating func beginLoading() {
    isLoading = true
    rootErrorMessage = nil
  }

  mutating func receive(_ snapshot: AudioCatalogSnapshot) {
    self.snapshot = snapshot
    rootErrorMessage = nil
    isLoading = false
  }

  mutating func fail(with error: any Error) {
    rootErrorMessage = error.localizedDescription
    isLoading = false
  }

  mutating func cancelLoading() {
    isLoading = false
  }
}

@MainActor
@Observable
final class AudioCatalogController {
  private(set) var state = AudioCatalogViewState()

  @ObservationIgnored private let loader: any AudioCatalogLoading
  @ObservationIgnored private var observationTask: Task<Void, Never>?
  @ObservationIgnored private var generation: UInt = 0

  init(loader: any AudioCatalogLoading = SystemAudioCatalogLoader()) {
    self.loader = loader
  }

  func start() {
    guard observationTask == nil else { return }

    generation &+= 1
    let currentGeneration = generation
    let loader = loader
    state.beginLoading()

    observationTask = Task { [weak self] in
      do {
        for try await snapshot in loader.updates() {
          guard let self, generation == currentGeneration else { return }
          state.receive(snapshot)
        }
        guard let self, generation == currentGeneration else { return }
        observationTask = nil
      } catch is CancellationError {
        guard let self, generation == currentGeneration else { return }
        state.cancelLoading()
        observationTask = nil
      } catch {
        guard let self, generation == currentGeneration else { return }
        state.fail(with: error)
        observationTask = nil
      }
    }
  }

  func refresh() {
    stop()
    start()
  }

  func stop() {
    generation &+= 1
    observationTask?.cancel()
    observationTask = nil
  }

  func loadOnce() async {
    state.beginLoading()
    do {
      state.receive(try await loader.snapshot())
    } catch is CancellationError {
      state.cancelLoading()
    } catch {
      state.fail(with: error)
    }
  }

  deinit {
    observationTask?.cancel()
  }
}
