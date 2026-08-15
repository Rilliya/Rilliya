import Foundation
import Observation
import RilliyaKit

protocol AudioCatalogLoading: Sendable {
  func snapshot() async throws -> AudioCatalogSnapshot
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
  @ObservationIgnored private let pollingInterval: Duration
  @ObservationIgnored private var observationTask: Task<Void, Never>?
  @ObservationIgnored private var generation: UInt = 0

  init(
    loader: any AudioCatalogLoading = SystemAudioCatalogLoader(),
    pollingInterval: Duration = .seconds(1)
  ) {
    self.loader = loader
    self.pollingInterval = pollingInterval
  }

  func start() {
    guard observationTask == nil else { return }

    generation &+= 1
    let currentGeneration = generation
    let loader = loader
    let pollingInterval = pollingInterval
    state.beginLoading()

    observationTask = Task { [weak self] in
      while !Task.isCancelled {
        do {
          let snapshot = try await loader.snapshot()
          guard let self, generation == currentGeneration else { return }
          state.receive(snapshot)
        } catch is CancellationError {
          guard let self, generation == currentGeneration else { return }
          state.cancelLoading()
          observationTask = nil
          return
        } catch {
          guard let self, generation == currentGeneration else { return }
          state.fail(with: error)
          observationTask = nil
          return
        }

        do {
          try await Task.sleep(for: pollingInterval)
        } catch {
          return
        }
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
