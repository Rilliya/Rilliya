import Foundation

struct ApplicationFileCandidate: Equatable, Sendable {
  let url: URL
  let localizedName: String?
  let fileResourceIdentifier: Data?
  let isApplication: Bool
  let discoverySource: InstalledApplicationDiscoverySource
}

struct ApplicationBundleMetadata: Equatable, Sendable {
  let bundleIdentifier: String?
  let localizedDisplayName: String?
  let bundleName: String?
  let packageType: String?
  let isBackgroundOnly: Bool
  let isUserInterfaceElement: Bool
}

protocol ApplicationCandidateDiscovering: Sendable {
  func candidates() throws -> [ApplicationFileCandidate]
}

protocol ApplicationBundleMetadataReading: Sendable {
  func metadata(for applicationURL: URL) -> ApplicationBundleMetadata?
}

struct StandardApplicationDirectoryDiscoverer: ApplicationCandidateDiscovering {
  func candidates() throws -> [ApplicationFileCandidate] {
    let fileManager = FileManager.default
    let resourceKeys: [URLResourceKey] = [
      .fileResourceIdentifierKey,
      .isApplicationKey,
      .localizedNameKey,
    ]
    let roots = standardApplicationDirectoryURLs(fileManager: fileManager)
    var candidates: [ApplicationFileCandidate] = []

    for root in roots {
      try Task.checkCancellation()
      guard
        let enumerator = fileManager.enumerator(
          at: root,
          includingPropertiesForKeys: resourceKeys,
          options: [.skipsPackageDescendants, .skipsHiddenFiles],
          errorHandler: { _, _ in true }
        )
      else {
        continue
      }

      for case let url as URL in enumerator {
        try Task.checkCancellation()
        if let candidate = applicationFileCandidate(
          at: url,
          discoverySource: .standardApplicationDirectory,
          resourceKeys: Set(resourceKeys)
        ) {
          candidates.append(candidate)
        }
      }
    }

    return candidates
  }
}

func standardApplicationDirectoryURLs(fileManager: FileManager = .default) -> [URL] {
  let domains: FileManager.SearchPathDomainMask = [
    .userDomainMask,
    .localDomainMask,
    .systemDomainMask,
  ]
  return fileManager.urls(for: .applicationDirectory, in: domains)
    .map(canonicalApplicationURL)
    .uniqued()
    .sorted { $0.absoluteString < $1.absoluteString }
}

func applicationFileCandidate(
  at discoveredURL: URL,
  discoverySource: InstalledApplicationDiscoverySource,
  resourceKeys: Set<URLResourceKey> = [
    .fileResourceIdentifierKey,
    .isApplicationKey,
    .localizedNameKey,
  ]
) -> ApplicationFileCandidate? {
  let canonicalURL = canonicalApplicationURL(discoveredURL)
  guard let values = try? canonicalURL.resourceValues(forKeys: resourceKeys),
    values.isApplication == true
  else {
    return nil
  }
  return ApplicationFileCandidate(
    url: canonicalURL,
    localizedName: values.localizedName,
    fileResourceIdentifier: encodedFileResourceIdentifier(
      values.fileResourceIdentifier
    ),
    isApplication: true,
    discoverySource: discoverySource
  )
}

struct SystemApplicationBundleMetadataReader: ApplicationBundleMetadataReading {
  func metadata(for applicationURL: URL) -> ApplicationBundleMetadata? {
    guard let bundle = Bundle(url: applicationURL) else { return nil }

    let localizedInfo = bundle.localizedInfoDictionary
    let info = bundle.infoDictionary
    return ApplicationBundleMetadata(
      bundleIdentifier: nonEmpty(bundle.bundleIdentifier),
      localizedDisplayName: localizedInfo?["CFBundleDisplayName"] as? String,
      bundleName: (localizedInfo?["CFBundleName"] as? String)
        ?? (info?["CFBundleName"] as? String),
      packageType: info?["CFBundlePackageType"] as? String,
      isBackgroundOnly: booleanValue(info?["LSBackgroundOnly"]),
      isUserInterfaceElement: booleanValue(info?["LSUIElement"])
    )
  }
}

struct InstalledApplicationBuilder: Sendable {
  let metadataReader: any ApplicationBundleMetadataReading

  func applications(from candidates: [ApplicationFileCandidate]) -> [InstalledApplication] {
    var applicationsByID: [InstalledApplicationID: InstalledApplication] = [:]
    let orderedCandidates = candidates.sorted {
      canonicalApplicationURL($0.url).absoluteString
        < canonicalApplicationURL($1.url).absoluteString
    }

    for candidate in orderedCandidates where candidate.isApplication {
      let canonicalURL = canonicalApplicationURL(candidate.url)
      guard let metadata = metadataReader.metadata(for: canonicalURL) else { continue }
      guard metadata.packageType == nil || metadata.packageType == "APPL" else { continue }
      guard !metadata.isBackgroundOnly else { continue }

      let id = InstalledApplicationID(
        fileResourceIdentifier: candidate.fileResourceIdentifier,
        canonicalURL: canonicalURL
      )
      let application = InstalledApplication(
        id: id,
        bundleURL: canonicalURL,
        bundleIdentifier: nonEmpty(metadata.bundleIdentifier),
        displayName: displayName(for: candidate, metadata: metadata),
        kind: metadata.isUserInterfaceElement ? .accessory : .regular,
        discoverySources: [candidate.discoverySource]
      )

      if let existing = applicationsByID[id] {
        applicationsByID[id] = InstalledApplication(
          id: existing.id,
          bundleURL: existing.bundleURL,
          bundleIdentifier: existing.bundleIdentifier,
          displayName: existing.displayName,
          kind: existing.kind,
          discoverySources: existing.discoverySources.union(application.discoverySources)
        )
      } else {
        applicationsByID[id] = application
      }
    }

    return applicationsByID.values.sorted(by: stableApplicationOrdering)
  }

  private func displayName(
    for candidate: ApplicationFileCandidate,
    metadata: ApplicationBundleMetadata
  ) -> String {
    let values = [
      candidate.localizedName,
      metadata.localizedDisplayName,
      metadata.bundleName,
      candidate.url.deletingPathExtension().lastPathComponent,
    ]
    return values.compactMap(nonEmpty).first ?? candidate.url.lastPathComponent
  }
}

func canonicalApplicationURL(_ url: URL) -> URL {
  url.standardizedFileURL.resolvingSymlinksInPath()
}

private func encodedFileResourceIdentifier(_ value: Any?) -> Data? {
  if let data = value as? Data {
    return data
  }
  guard let value = value as? any NSSecureCoding else { return nil }
  return try? NSKeyedArchiver.archivedData(
    withRootObject: value,
    requiringSecureCoding: true
  )
}

private func booleanValue(_ value: Any?) -> Bool {
  if let value = value as? Bool {
    return value
  }
  if let value = value as? NSNumber {
    return value.boolValue
  }
  return false
}

private func nonEmpty(_ value: String?) -> String? {
  guard let value else { return nil }
  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
  return trimmed.isEmpty ? nil : trimmed
}

private func stableApplicationOrdering(
  _ lhs: InstalledApplication,
  _ rhs: InstalledApplication
) -> Bool {
  let locale = Locale(identifier: "en_US_POSIX")
  let leftName = lhs.displayName.lowercased(with: locale)
  let rightName = rhs.displayName.lowercased(with: locale)
  if leftName != rightName {
    return leftName < rightName
  }
  if lhs.displayName != rhs.displayName {
    return lhs.displayName < rhs.displayName
  }
  let leftIdentifier = lhs.bundleIdentifier ?? ""
  let rightIdentifier = rhs.bundleIdentifier ?? ""
  if leftIdentifier != rightIdentifier {
    return leftIdentifier < rightIdentifier
  }
  return lhs.bundleURL.absoluteString < rhs.bundleURL.absoluteString
}

extension Sequence where Element: Hashable {
  fileprivate func uniqued() -> [Element] {
    var seen: Set<Element> = []
    return filter { seen.insert($0).inserted }
  }
}
