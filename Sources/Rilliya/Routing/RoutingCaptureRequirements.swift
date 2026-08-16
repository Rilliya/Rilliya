import Foundation
import RilliyaCapture
import RilliyaCore
import RilliyaVirtualAudio

struct RoutingCaptureRequirements: Equatable {
  let processIDsByNode: [UUID: AudioProcessID]
  let inputDeviceIDsByNode: [UUID: AudioDeviceID]
  let outputCaptureDeviceIDsByNode: [UUID: AudioDeviceID]
  let muteBehaviorsByProcess: [AudioProcessID: ProcessOutputCaptureMuteBehavior]

  init(
    processIDsByNode: [UUID: AudioProcessID],
    inputDeviceIDsByNode: [UUID: AudioDeviceID] = [:],
    outputCaptureDeviceIDsByNode: [UUID: AudioDeviceID] = [:],
    muteBehaviorsByProcess: [AudioProcessID: ProcessOutputCaptureMuteBehavior] = [:]
  ) {
    self.processIDsByNode = processIDsByNode
    self.inputDeviceIDsByNode = inputDeviceIDsByNode
    self.outputCaptureDeviceIDsByNode = outputCaptureDeviceIDsByNode
    self.muteBehaviorsByProcess = muteBehaviorsByProcess
  }

  static let empty = RoutingCaptureRequirements(
    processIDsByNode: [:],
    inputDeviceIDsByNode: [:],
    outputCaptureDeviceIDsByNode: [:]
  )
}

enum RoutingCaptureRequirementResolver {
  @MainActor
  static func resolve(
    workflows: [RoutingWorkflowModel],
    catalogSnapshot: InstalledApplicationCatalogSnapshot?,
    audioCatalogSnapshot: AudioCatalogSnapshot? = nil,
    virtualAudioCatalog: VirtualAudioEndpointCatalog = .empty
  ) -> RoutingCaptureRequirements {
    let catalogByURL = Dictionary(
      (catalogSnapshot?.items ?? []).map { item in
        (canonicalApplicationURL(item.application.bundleURL), item)
      },
      uniquingKeysWith: { first, _ in first }
    )
    var requirements: [UUID: AudioProcessID] = [:]
    var inputRequirements: [UUID: AudioDeviceID] = [:]
    var outputCaptureRequirements: [UUID: AudioDeviceID] = [:]
    var reroutedProcessIDs = Set<AudioProcessID>()
    let liveOutputDevices = Dictionary(
      uniqueKeysWithValues: (audioCatalogSnapshot?.outputDevices ?? []).filter(\.isAlive).map {
        ($0.id, $0)
      }
    )
    let defaultOutputDeviceID = audioCatalogSnapshot?.outputDevices.first {
      $0.isAlive && $0.output?.isDefault == true
    }?.id

    for workflow in workflows where workflow.isRunning {
      let workspace = workflow.workspace
      let routedSourceIDs = workspace.captureSourceNodeIDs
      let reroutedSourceIDs = workspace.audioSourceNodeIDsFeedingOutputAudio
      for node in workspace.nodes where routedSourceIDs.contains(node.id) {
        if case .systemOutput(let selection, _) = node.value {
          switch selection {
          case .systemDefault:
            if let defaultOutputDeviceID {
              outputCaptureRequirements[node.id] = defaultOutputDeviceID
            }
          case .device(let device):
            if liveOutputDevices[device.id] != nil {
              outputCaptureRequirements[node.id] = device.id
            }
          case nil:
            break
          }
          continue
        }
        if case .virtualOutput(let selection, _) = node.value {
          if let selection,
            let endpoint = virtualAudioCatalog.endpoint(id: selection.id),
            endpoint.configuration.direction == .output,
            let bridgeDeviceID = AudioDeviceID(rawValue: endpoint.deviceUIDs.hostBridge)
          {
            inputRequirements[node.id] = bridgeDeviceID
          }
          continue
        }
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
      outputCaptureDeviceIDsByNode: outputCaptureRequirements,
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
