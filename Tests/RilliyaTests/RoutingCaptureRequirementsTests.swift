import CoreGraphics
import FlowingDayGraphCanvas
import Foundation
import RilliyaKit
import Testing

@testable import Rilliya

struct RoutingCaptureRequirementsTests {
  @Test @MainActor
  func onlyConnectedRunningApplicationSourcesRequireCapture() throws {
    let musicURL = URL(fileURLWithPath: "/Applications/Music.app")
    let processID = try #require(AudioProcessID(rawValue: 42))
    let workflow = RoutingWorkflowModel(name: "Music")
    let sourceID = workflow.workspace.addApplicationAudioNode(centeredAt: .zero)
    let visualizerID = workflow.workspace.addVisualizerNode(
      centeredAt: CGPoint(x: 400, y: 0)
    )
    workflow.workspace.selectApplication(
      RoutingApplicationSelection(
        stableID: musicURL.absoluteString,
        applicationURL: musicURL,
        bundleIdentifier: "com.apple.Music",
        displayName: "Music"
      ),
      for: sourceID
    )
    let snapshot = catalogSnapshot(
      applicationURL: musicURL,
      processIdentifiers: [88, processID.rawValue]
    )

    let beforeConnection = RoutingCaptureRequirementResolver.resolve(
      workflows: [workflow],
      catalogSnapshot: snapshot
    )
    #expect(beforeConnection == .empty)

    try connect(sourceID: sourceID, targetID: visualizerID, in: workflow.workspace)

    let afterConnection = RoutingCaptureRequirementResolver.resolve(
      workflows: [workflow],
      catalogSnapshot: snapshot
    )
    #expect(afterConnection.processIDsByNode == [sourceID: processID])
  }

  @Test @MainActor
  func identicalProcessesAcrossWorkflowsRemainSeparateConsumers() throws {
    let musicURL = URL(fileURLWithPath: "/Applications/Music.app")
    let processID = try #require(AudioProcessID(rawValue: 54))
    let workflows = [RoutingWorkflowModel(name: "A"), RoutingWorkflowModel(name: "B")]
    var sourceIDs: [UUID] = []

    for (index, workflow) in workflows.enumerated() {
      let sourceID = workflow.workspace.addApplicationAudioNode(centeredAt: .zero)
      let visualizerID = workflow.workspace.addVisualizerNode(
        centeredAt: CGPoint(x: 400, y: CGFloat(index * 200))
      )
      workflow.workspace.selectApplication(
        RoutingApplicationSelection(
          stableID: musicURL.absoluteString,
          applicationURL: musicURL,
          bundleIdentifier: "com.apple.Music",
          displayName: "Music"
        ),
        for: sourceID
      )
      try connect(sourceID: sourceID, targetID: visualizerID, in: workflow.workspace)
      sourceIDs.append(sourceID)
    }

    let requirements = RoutingCaptureRequirementResolver.resolve(
      workflows: workflows,
      catalogSnapshot: catalogSnapshot(
        applicationURL: musicURL,
        processIdentifiers: [processID.rawValue]
      )
    )

    #expect(requirements.processIDsByNode.count == 2)
    #expect(Set(requirements.processIDsByNode.keys) == Set(sourceIDs))
    #expect(Set(requirements.processIDsByNode.values) == [processID])
  }

  @Test @MainActor
  func connectedInputDeviceRequiresCaptureWithoutAnApplicationCatalog() throws {
    let deviceID = try #require(AudioDeviceID(rawValue: "test.virtual-input"))
    let workflow = RoutingWorkflowModel(name: "Input")
    let sourceID = workflow.workspace.addInputAudioNode(centeredAt: .zero)
    let visualizerID = workflow.workspace.addVisualizerNode(
      centeredAt: CGPoint(x: 400, y: 0)
    )
    workflow.workspace.selectInputDevice(
      RoutingInputDeviceSelection(id: deviceID, displayName: "Virtual Input"),
      for: sourceID
    )
    try connect(sourceID: sourceID, targetID: visualizerID, in: workflow.workspace)

    let requirements = RoutingCaptureRequirementResolver.resolve(
      workflows: [workflow],
      catalogSnapshot: nil
    )

    #expect(requirements.processIDsByNode.isEmpty)
    #expect(requirements.inputDeviceIDsByNode == [sourceID: deviceID])
  }

  @MainActor
  private func connect(
    sourceID: UUID,
    targetID: UUID,
    in workspace: RoutingWorkspaceModel
  ) throws {
    let content = try #require(workspace.canvasContent)
    let source = try #require(
      content.presentation.ports.first {
        guard case .port(let key) = $0.address.elementID else { return false }
        return key.nodeID == sourceID && $0.value.direction == .output
      }
    )
    let target = try #require(
      content.presentation.ports.first {
        guard case .port(let key) = $0.address.elementID else { return false }
        return key.nodeID == targetID && $0.value.direction == .input
      }
    )
    workspace.send(
      .connectionCompleted(
        FlowingGraphCanvasConnectionCompletionIntent(
          operation: .create(sourcePortID: source.id, targetPortID: target.id),
          basePresentationSnapshotID: content.presentation.snapshotID,
          baseLayoutInputID: content.id
        )
      )
    )
  }

  private func catalogSnapshot(
    applicationURL: URL,
    processIdentifiers: [Int32]
  ) -> InstalledApplicationCatalogSnapshot {
    let application = InstalledApplication(
      id: InstalledApplicationID(
        fileResourceIdentifier: nil,
        canonicalURL: applicationURL
      ),
      bundleURL: applicationURL,
      bundleIdentifier: "com.apple.Music",
      displayName: "Music",
      kind: .regular,
      discoverySources: [.standardApplicationDirectory]
    )
    return InstalledApplicationCatalogSnapshot(
      items: [
        InstalledApplicationCatalogItem(
          application: application,
          runningApplications: processIdentifiers.map { processIdentifier in
            RunningApplicationDescriptor(
              processIdentifier: processIdentifier,
              bundleURL: applicationURL,
              bundleIdentifier: "com.apple.Music",
              localizedName: "Music",
              kind: .regular
            )
          }
        )
      ],
      unmatchedRunningApplications: []
    )
  }
}
