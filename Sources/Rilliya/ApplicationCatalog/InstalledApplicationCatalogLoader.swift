import Foundation

protocol InstalledApplicationCatalogLoading: Sendable {
  func snapshot() async throws -> InstalledApplicationCatalogSnapshot
}

struct SystemInstalledApplicationCatalogLoader: InstalledApplicationCatalogLoading {
  private let discoverer: any ApplicationCandidateDiscovering
  private let metadataReader: any ApplicationBundleMetadataReading
  private let runningApplicationProvider: any RunningApplicationProviding

  init(
    discoverer: any ApplicationCandidateDiscovering = StandardApplicationDirectoryDiscoverer(),
    metadataReader: any ApplicationBundleMetadataReading = SystemApplicationBundleMetadataReader(),
    runningApplicationProvider: any RunningApplicationProviding =
      NSWorkspaceRunningApplicationProvider()
  ) {
    self.discoverer = discoverer
    self.metadataReader = metadataReader
    self.runningApplicationProvider = runningApplicationProvider
  }

  func snapshot() async throws -> InstalledApplicationCatalogSnapshot {
    let discoverer = discoverer
    let metadataReader = metadataReader
    let discoveryTask = Task.detached(priority: .userInitiated) {
      let candidates = try discoverer.candidates()
      try Task.checkCancellation()
      return InstalledApplicationBuilder(metadataReader: metadataReader)
        .applications(from: candidates)
    }
    let applications = try await withTaskCancellationHandler {
      try await discoveryTask.value
    } onCancel: {
      discoveryTask.cancel()
    }
    try Task.checkCancellation()

    let runningApplications = await runningApplicationProvider.runningApplications()
    try Task.checkCancellation()
    return InstalledApplicationRunningOverlay().snapshot(
      applications: applications,
      runningApplications: runningApplications
    )
  }
}
