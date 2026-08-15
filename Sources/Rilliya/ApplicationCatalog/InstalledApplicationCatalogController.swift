import Foundation
import Observation

struct InstalledApplicationCatalogViewState: Equatable {
  private(set) var snapshot: InstalledApplicationCatalogSnapshot?
  private(set) var rootErrorMessage: String?
  private(set) var isLoading = false

  mutating func beginLoading() {
    isLoading = true
    rootErrorMessage = nil
  }

  mutating func receive(_ snapshot: InstalledApplicationCatalogSnapshot) {
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
final class InstalledApplicationCatalogController {
  private(set) var state = InstalledApplicationCatalogViewState()

  @ObservationIgnored private let loader: any InstalledApplicationCatalogLoading
  @ObservationIgnored private var refreshTask: Task<InstalledApplicationCatalogSnapshot, any Error>?
  @ObservationIgnored private var generation: UInt = 0

  init(loader: any InstalledApplicationCatalogLoading = SystemInstalledApplicationCatalogLoader()) {
    self.loader = loader
  }

  func refresh() async {
    generation &+= 1
    let currentGeneration = generation
    refreshTask?.cancel()
    state.beginLoading()

    let loader = loader
    let task = Task {
      try await loader.snapshot()
    }
    refreshTask = task

    do {
      let snapshot = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      try Task.checkCancellation()
      guard generation == currentGeneration, !task.isCancelled else { return }
      state.receive(snapshot)
      refreshTask = nil
    } catch is CancellationError {
      guard generation == currentGeneration else { return }
      state.cancelLoading()
      refreshTask = nil
    } catch {
      guard generation == currentGeneration else { return }
      state.fail(with: error)
      refreshTask = nil
    }
  }

  func cancelRefresh() {
    generation &+= 1
    refreshTask?.cancel()
    refreshTask = nil
    state.cancelLoading()
  }

  deinit {
    refreshTask?.cancel()
  }
}
