import Foundation
import Testing

@testable import Rilliya

struct InstalledApplicationCatalogTests {
  @Test
  func symlinkedApplicationIsClassifiedAfterResolvingItsTarget() throws {
    let fileManager = FileManager.default
    let fixtureRoot = fileManager.temporaryDirectory.appendingPathComponent(
      "rilliya-application-symlink-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? fileManager.removeItem(at: fixtureRoot) }

    let targetURL = fixtureRoot.appendingPathComponent("Target.app", isDirectory: true)
    let contentsURL = targetURL.appendingPathComponent("Contents", isDirectory: true)
    try fileManager.createDirectory(at: contentsURL, withIntermediateDirectories: true)
    let info: [String: Any] = [
      "CFBundleIdentifier": "example.symlink-target",
      "CFBundleName": "Target",
      "CFBundlePackageType": "APPL",
    ]
    let infoData = try PropertyListSerialization.data(
      fromPropertyList: info,
      format: .xml,
      options: 0
    )
    try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))

    let symlinkURL = fixtureRoot.appendingPathComponent("Linked.app")
    try fileManager.createSymbolicLink(at: symlinkURL, withDestinationURL: targetURL)

    let candidate = try #require(
      applicationFileCandidate(
        at: symlinkURL,
        discoverySource: .standardApplicationDirectory
      )
    )

    #expect(candidate.url == canonicalApplicationURL(targetURL))
    #expect(candidate.isApplication)
  }

  @Test
  func filteringRetainsAccessoryApplicationsAndExcludesBackgroundApplications() throws {
    let regularURL = applicationURL("Regular")
    let accessoryURL = applicationURL("Accessory")
    let backgroundURL = applicationURL("Background")
    let pluginURL = applicationURL("Plugin")
    let documentURL = URL(fileURLWithPath: "/Applications/Document.txt")
    let candidates = [
      candidate(regularURL, resourceID: "regular"),
      candidate(accessoryURL, resourceID: "accessory"),
      candidate(backgroundURL, resourceID: "background"),
      candidate(pluginURL, resourceID: "plugin"),
      candidate(documentURL, resourceID: "document", isApplication: false),
    ]
    let metadata = StubApplicationBundleMetadataReader(values: [
      regularURL: bundleMetadata(bundleIdentifier: "example.regular"),
      accessoryURL: bundleMetadata(
        bundleIdentifier: "example.accessory",
        isUserInterfaceElement: true
      ),
      backgroundURL: bundleMetadata(
        bundleIdentifier: "example.background",
        isBackgroundOnly: true
      ),
      pluginURL: bundleMetadata(bundleIdentifier: "example.plugin", packageType: "BNDL"),
      documentURL: bundleMetadata(bundleIdentifier: "example.document"),
    ])

    let applications = InstalledApplicationBuilder(metadataReader: metadata)
      .applications(from: candidates)

    #expect(applications.map(\.bundleIdentifier) == ["example.accessory", "example.regular"])
    #expect(applications.map(\.kind) == [.accessory, .regular])
  }

  @Test
  func sortingAndPhysicalDeduplicationAreStable() throws {
    let alphaURL = applicationURL("Alpha")
    let alphaAliasURL = applicationURL("Shared Alpha Alias")
    let zuluURL = applicationURL("Zulu")
    let sharedResourceID = Data("shared".utf8)
    let candidates = [
      candidate(zuluURL, resourceID: "zulu", localizedName: "zulu"),
      candidate(alphaAliasURL, resourceID: sharedResourceID, localizedName: "Alpha Alias"),
      candidate(alphaURL, resourceID: sharedResourceID, localizedName: "alpha"),
    ]
    let metadata = StubApplicationBundleMetadataReader(values: [
      alphaURL: bundleMetadata(bundleIdentifier: "example.alpha"),
      alphaAliasURL: bundleMetadata(bundleIdentifier: "example.alpha"),
      zuluURL: bundleMetadata(bundleIdentifier: "example.zulu"),
    ])
    let builder = InstalledApplicationBuilder(metadataReader: metadata)

    let first = builder.applications(from: candidates)
    let second = builder.applications(from: candidates.reversed())

    #expect(first == second)
    #expect(first.map(\.displayName) == ["alpha", "zulu"])
  }

  @Test
  func duplicateBundleIdentifiersRemainDistinctPhysicalApplications() throws {
    let firstURL = applicationURL("Player Stable")
    let secondURL = applicationURL("Player Beta")
    let metadata = StubApplicationBundleMetadataReader(values: [
      firstURL: bundleMetadata(bundleIdentifier: "example.player"),
      secondURL: bundleMetadata(bundleIdentifier: "example.player"),
    ])

    let applications = InstalledApplicationBuilder(metadataReader: metadata).applications(from: [
      candidate(firstURL, resourceID: "stable"),
      candidate(secondURL, resourceID: "beta"),
    ])

    #expect(applications.count == 2)
    #expect(Set(applications.map(\.id)).count == 2)
    #expect(Set(applications.compactMap(\.bundleIdentifier)) == ["example.player"])
  }

  @Test
  func runningOverlayPrefersExactURLsAndUsesOnlyUnambiguousBundleFallbacks() throws {
    let firstPlayer = installedApplication("Player Stable", bundleIdentifier: "example.player")
    let secondPlayer = installedApplication("Player Beta", bundleIdentifier: "example.player")
    let editor = installedApplication("Editor", bundleIdentifier: "example.editor")
    let exactPlayer = runningApplication(
      processIdentifier: 10,
      url: secondPlayer.bundleURL,
      bundleIdentifier: "example.player"
    )
    let ambiguousPlayer = runningApplication(
      processIdentifier: 11,
      url: applicationURL("Translocated Player"),
      bundleIdentifier: "example.player"
    )
    let editorFallback = runningApplication(
      processIdentifier: 12,
      url: applicationURL("Translocated Editor"),
      bundleIdentifier: "example.editor"
    )

    let snapshot = InstalledApplicationRunningOverlay().snapshot(
      applications: [firstPlayer, secondPlayer, editor],
      runningApplications: [ambiguousPlayer, editorFallback, exactPlayer]
    )

    #expect(snapshot.items.first { $0.application.id == firstPlayer.id }?.isRunning == false)
    #expect(
      snapshot.items.first { $0.application.id == secondPlayer.id }?.runningApplications
        == [exactPlayer]
    )
    #expect(
      snapshot.items.first { $0.application.id == editor.id }?.runningApplications
        == [editorFallback]
    )
    #expect(snapshot.unmatchedRunningApplications == [ambiguousPlayer])
  }

  @Test @MainActor
  func newerRefreshWinsWhenAnOlderLoaderIgnoresCancellation() async {
    let loader = ControlledInstalledApplicationCatalogLoader()
    let controller = InstalledApplicationCatalogController(loader: loader)
    let oldSnapshot = emptySnapshot(named: "Old")
    let newSnapshot = emptySnapshot(named: "New")

    let firstRefresh = Task { await controller.refresh() }
    await loader.waitForRequestCount(1)
    let secondRefresh = Task { await controller.refresh() }
    await loader.waitForRequestCount(2)
    await loader.succeedRequest(at: 1, with: newSnapshot)
    await secondRefresh.value
    await loader.succeedRequest(at: 0, with: oldSnapshot)
    await firstRefresh.value

    #expect(controller.state.snapshot == newSnapshot)
    #expect(!controller.state.isLoading)
  }

  @Test @MainActor
  func cancellingRefreshDoesNotPublishALateResult() async {
    let loader = ControlledInstalledApplicationCatalogLoader()
    let controller = InstalledApplicationCatalogController(loader: loader)
    let lateSnapshot = emptySnapshot(named: "Late")

    let refresh = Task { await controller.refresh() }
    await loader.waitForRequestCount(1)
    refresh.cancel()
    await loader.succeedRequest(at: 0, with: lateSnapshot)
    await refresh.value

    #expect(controller.state.snapshot == nil)
    #expect(controller.state.rootErrorMessage == nil)
    #expect(!controller.state.isLoading)
  }
}

private func applicationURL(_ name: String) -> URL {
  URL(fileURLWithPath: "/Applications/\(name).app")
}

private func candidate(
  _ url: URL,
  resourceID: String,
  localizedName: String? = nil,
  isApplication: Bool = true
) -> ApplicationFileCandidate {
  candidate(
    url,
    resourceID: Data(resourceID.utf8),
    localizedName: localizedName,
    isApplication: isApplication
  )
}

private func candidate(
  _ url: URL,
  resourceID: Data,
  localizedName: String? = nil,
  isApplication: Bool = true
) -> ApplicationFileCandidate {
  ApplicationFileCandidate(
    url: url,
    localizedName: localizedName,
    fileResourceIdentifier: resourceID,
    isApplication: isApplication,
    discoverySource: .standardApplicationDirectory
  )
}

private func bundleMetadata(
  bundleIdentifier: String,
  packageType: String? = "APPL",
  isBackgroundOnly: Bool = false,
  isUserInterfaceElement: Bool = false
) -> ApplicationBundleMetadata {
  ApplicationBundleMetadata(
    bundleIdentifier: bundleIdentifier,
    localizedDisplayName: nil,
    bundleName: nil,
    packageType: packageType,
    isBackgroundOnly: isBackgroundOnly,
    isUserInterfaceElement: isUserInterfaceElement
  )
}

private func installedApplication(
  _ name: String,
  bundleIdentifier: String
) -> InstalledApplication {
  let url = applicationURL(name)
  return InstalledApplication(
    id: InstalledApplicationID(
      fileResourceIdentifier: Data(name.utf8),
      canonicalURL: url
    ),
    bundleURL: url,
    bundleIdentifier: bundleIdentifier,
    displayName: name,
    kind: .regular,
    discoverySources: [.standardApplicationDirectory]
  )
}

private func runningApplication(
  processIdentifier: Int32,
  url: URL,
  bundleIdentifier: String
) -> RunningApplicationDescriptor {
  RunningApplicationDescriptor(
    processIdentifier: processIdentifier,
    bundleURL: url,
    bundleIdentifier: bundleIdentifier,
    localizedName: nil,
    kind: .regular
  )
}

private func emptySnapshot(named name: String) -> InstalledApplicationCatalogSnapshot {
  let application = installedApplication(name, bundleIdentifier: "example.\(name.lowercased())")
  return InstalledApplicationRunningOverlay().snapshot(
    applications: [application],
    runningApplications: []
  )
}

private struct StubApplicationBundleMetadataReader: ApplicationBundleMetadataReading {
  let values: [URL: ApplicationBundleMetadata]

  func metadata(for applicationURL: URL) -> ApplicationBundleMetadata? {
    values[applicationURL]
  }
}

private actor ControlledInstalledApplicationCatalogLoader: InstalledApplicationCatalogLoading {
  private var continuations: [CheckedContinuation<InstalledApplicationCatalogSnapshot, Never>?] = []

  func snapshot() async throws -> InstalledApplicationCatalogSnapshot {
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func waitForRequestCount(_ expectedCount: Int) async {
    while continuations.count < expectedCount {
      await Task.yield()
    }
  }

  func succeedRequest(
    at index: Int,
    with snapshot: InstalledApplicationCatalogSnapshot
  ) {
    continuations[index]?.resume(returning: snapshot)
    continuations[index] = nil
  }
}
