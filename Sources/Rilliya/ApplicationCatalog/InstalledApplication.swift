import Foundation

struct InstalledApplicationID: Hashable, Sendable {
  fileprivate enum Storage: Hashable, Sendable {
    case fileResource(Data)
    case canonicalURL(String)
  }

  fileprivate let storage: Storage

  init(fileResourceIdentifier: Data?, canonicalURL: URL) {
    if let fileResourceIdentifier {
      storage = .fileResource(fileResourceIdentifier)
    } else {
      storage = .canonicalURL(canonicalURL.absoluteString)
    }
  }
}

enum InstalledApplicationKind: Equatable, Sendable {
  case regular
  case accessory
}

enum InstalledApplicationDiscoverySource: Hashable, Sendable {
  case standardApplicationDirectory
}

struct InstalledApplication: Identifiable, Equatable, Sendable {
  let id: InstalledApplicationID
  let bundleURL: URL
  let bundleIdentifier: String?
  let displayName: String
  let kind: InstalledApplicationKind
  let discoverySources: Set<InstalledApplicationDiscoverySource>
}

struct RunningApplicationDescriptor: Equatable, Sendable {
  let processIdentifier: Int32
  let bundleURL: URL?
  let bundleIdentifier: String?
  let localizedName: String?
  let kind: InstalledApplicationKind
}

struct InstalledApplicationCatalogItem: Equatable, Sendable {
  let application: InstalledApplication
  let runningApplications: [RunningApplicationDescriptor]

  var isRunning: Bool {
    !runningApplications.isEmpty
  }
}

struct InstalledApplicationCatalogSnapshot: Equatable, Sendable {
  let items: [InstalledApplicationCatalogItem]
  let unmatchedRunningApplications: [RunningApplicationDescriptor]
}
