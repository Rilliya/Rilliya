import AppKit
import Foundation

@MainActor
protocol RunningApplicationProviding: Sendable {
  func runningApplications() -> [RunningApplicationDescriptor]
}

struct NSWorkspaceRunningApplicationProvider: RunningApplicationProviding {
  @MainActor
  func runningApplications() -> [RunningApplicationDescriptor] {
    NSWorkspace.shared.runningApplications.compactMap { application in
      guard !application.isTerminated else { return nil }

      let kind: InstalledApplicationKind
      switch application.activationPolicy {
      case .regular:
        kind = .regular
      case .accessory:
        kind = .accessory
      case .prohibited:
        return nil
      @unknown default:
        return nil
      }

      return RunningApplicationDescriptor(
        processIdentifier: application.processIdentifier,
        bundleURL: application.bundleURL,
        bundleIdentifier: application.bundleIdentifier,
        localizedName: application.localizedName,
        kind: kind
      )
    }
  }
}

struct InstalledApplicationRunningOverlay: Sendable {
  func snapshot(
    applications: [InstalledApplication],
    runningApplications: [RunningApplicationDescriptor]
  ) -> InstalledApplicationCatalogSnapshot {
    let applicationIDsByURL = Dictionary(
      uniqueKeysWithValues: applications.map {
        (canonicalApplicationURL($0.bundleURL), $0.id)
      }
    )
    let applicationIDsByBundleIdentifier = Dictionary(
      grouping: applications.compactMap { application in
        application.bundleIdentifier.map { ($0, application.id) }
      },
      by: \.0
    ).mapValues { $0.map(\.1) }
    var runningApplicationsByID: [InstalledApplicationID: [RunningApplicationDescriptor]] = [:]
    var unmatchedRunningApplications: [RunningApplicationDescriptor] = []

    for runningApplication in runningApplications {
      let exactID = runningApplication.bundleURL.flatMap {
        applicationIDsByURL[canonicalApplicationURL($0)]
      }
      let bundleIdentifierID = runningApplication.bundleIdentifier.flatMap { bundleIdentifier in
        let matches = applicationIDsByBundleIdentifier[bundleIdentifier] ?? []
        return matches.count == 1 ? matches[0] : nil
      }

      if let applicationID = exactID ?? bundleIdentifierID {
        runningApplicationsByID[applicationID, default: []].append(runningApplication)
      } else {
        unmatchedRunningApplications.append(runningApplication)
      }
    }

    let items = applications.map { application in
      InstalledApplicationCatalogItem(
        application: application,
        runningApplications: (runningApplicationsByID[application.id] ?? [])
          .sorted(by: stableRunningApplicationOrdering)
      )
    }
    return InstalledApplicationCatalogSnapshot(
      items: items,
      unmatchedRunningApplications: unmatchedRunningApplications.sorted(
        by: stableRunningApplicationOrdering
      )
    )
  }
}

private func stableRunningApplicationOrdering(
  _ lhs: RunningApplicationDescriptor,
  _ rhs: RunningApplicationDescriptor
) -> Bool {
  if lhs.processIdentifier != rhs.processIdentifier {
    return lhs.processIdentifier < rhs.processIdentifier
  }
  let leftIdentifier = lhs.bundleIdentifier ?? ""
  let rightIdentifier = rhs.bundleIdentifier ?? ""
  if leftIdentifier != rightIdentifier {
    return leftIdentifier < rightIdentifier
  }
  return (lhs.bundleURL?.absoluteString ?? "") < (rhs.bundleURL?.absoluteString ?? "")
}
