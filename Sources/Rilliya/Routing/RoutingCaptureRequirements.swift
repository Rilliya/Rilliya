import Foundation
import RilliyaKit

struct RoutingCaptureRequirements: Equatable {
  let processIDsByNode: [UUID: AudioProcessID]

  static let empty = RoutingCaptureRequirements(processIDsByNode: [:])
}

enum RoutingCaptureRequirementResolver {
  @MainActor
  static func resolve(
    workflows: [RoutingWorkflowModel],
    catalogSnapshot: InstalledApplicationCatalogSnapshot?
  ) -> RoutingCaptureRequirements {
    guard let catalogSnapshot else { return .empty }
    let catalogByURL = Dictionary(
      catalogSnapshot.items.map { item in
        (canonicalApplicationURL(item.application.bundleURL), item)
      },
      uniquingKeysWith: { first, _ in first }
    )
    var requirements: [UUID: AudioProcessID] = [:]

    for workflow in workflows {
      let workspace = workflow.workspace
      let routedSourceIDs = Set(workspace.edges.map(\.source.nodeID))
      for node in workspace.nodes where routedSourceIDs.contains(node.id) {
        guard let selection = node.value.applicationSelection,
          let item = catalogByURL[canonicalApplicationURL(selection.applicationURL)],
          let processIdentifier = item.runningApplications.map(\.processIdentifier).min(),
          let processID = AudioProcessID(rawValue: processIdentifier)
        else {
          continue
        }
        requirements[node.id] = processID
      }
    }

    return RoutingCaptureRequirements(processIDsByNode: requirements)
  }
}
