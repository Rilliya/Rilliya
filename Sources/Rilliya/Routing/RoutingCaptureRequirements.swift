import Foundation
import RilliyaKit

struct RoutingCaptureRequirements: Equatable {
  let processIDsByNode: [UUID: AudioProcessID]
  let inputDeviceIDsByNode: [UUID: AudioDeviceID]
  let muteBehaviorsByProcess: [AudioProcessID: ProcessOutputCaptureMuteBehavior]

  init(
    processIDsByNode: [UUID: AudioProcessID],
    inputDeviceIDsByNode: [UUID: AudioDeviceID] = [:],
    muteBehaviorsByProcess: [AudioProcessID: ProcessOutputCaptureMuteBehavior] = [:]
  ) {
    self.processIDsByNode = processIDsByNode
    self.inputDeviceIDsByNode = inputDeviceIDsByNode
    self.muteBehaviorsByProcess = muteBehaviorsByProcess
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
    var reroutedProcessIDs = Set<AudioProcessID>()

    for workflow in workflows {
      let workspace = workflow.workspace
      let routedSourceIDs = workspace.captureSourceNodeIDs
      let reroutedSourceIDs = workspace.audioSourceNodeIDsFeedingOutputAudio
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
        if reroutedSourceIDs.contains(node.id) {
          reroutedProcessIDs.insert(processID)
        }
      }
    }

    return RoutingCaptureRequirements(
      processIDsByNode: requirements,
      inputDeviceIDsByNode: inputRequirements,
      muteBehaviorsByProcess: Dictionary(
        uniqueKeysWithValues: Set(requirements.values).map { processID in
          (
            processID,
            reroutedProcessIDs.contains(processID) ? .mutedWhileTapped : .unmuted
          )
        }
      )
    )
  }
}
