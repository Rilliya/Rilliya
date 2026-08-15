import Foundation
import RilliyaKit

struct RoutingCaptureRequirements: Equatable {
  let processIDsByNode: [UUID: AudioProcessID]
  let inputDeviceIDsByNode: [UUID: AudioDeviceID]

  init(
    processIDsByNode: [UUID: AudioProcessID],
    inputDeviceIDsByNode: [UUID: AudioDeviceID] = [:]
  ) {
    self.processIDsByNode = processIDsByNode
    self.inputDeviceIDsByNode = inputDeviceIDsByNode
  }

  static let empty = RoutingCaptureRequirements(
    processIDsByNode: [:],
    inputDeviceIDsByNode: [:]
  )
}

enum RoutingCaptureRequirementResolver {
  @MainActor
  static func resolve(
    workflows: [RoutingWorkflowModel],
    catalogSnapshot: InstalledApplicationCatalogSnapshot?
  ) -> RoutingCaptureRequirements {
    let catalogByURL = Dictionary(
      (catalogSnapshot?.items ?? []).map { item in
        (canonicalApplicationURL(item.application.bundleURL), item)
      },
      uniquingKeysWith: { first, _ in first }
    )
    var requirements: [UUID: AudioProcessID] = [:]
    var inputRequirements: [UUID: AudioDeviceID] = [:]

    for workflow in workflows {
      let workspace = workflow.workspace
      let routedSourceIDs = workspace.captureSourceNodeIDs
      for node in workspace.nodes where routedSourceIDs.contains(node.id) {
        if let inputDeviceID = node.value.inputDeviceSelection?.id {
          inputRequirements[node.id] = inputDeviceID
          continue
        }
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

    return RoutingCaptureRequirements(
      processIDsByNode: requirements,
      inputDeviceIDsByNode: inputRequirements
    )
  }
}
