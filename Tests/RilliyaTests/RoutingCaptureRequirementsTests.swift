import CoreGraphics
import FlowingDayGraphCanvas
import Foundation
import RilliyaCapture
import RilliyaCore
import RilliyaVirtualAudio
import Testing

@testable import Rilliya

struct RoutingCaptureRequirementsTests {
  @Test @MainActor
  func onlyConnectedRunningApplicationSourcesRequireCapture() throws {
    let musicURL = URL(fileURLWithPath: "/Applications/Music.app")
    let processID = try #require(AudioProcessID(rawValue: 42))
    let workflow = RoutingWorkflowModel(name: "Music")
    workflow.run()
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
    for workflow in workflows {
      workflow.run()
    }
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
    workflow.run()
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

  @Test @MainActor
  func identicalInputDevicesAcrossWorkflowsRemainSeparateSharedConsumers() throws {
    let deviceID = try #require(AudioDeviceID(rawValue: "test.shared-microphone"))
    let workflows = [RoutingWorkflowModel(name: "Voice"), RoutingWorkflowModel(name: "Meter")]
    var sourceIDs: [UUID] = []

    for workflow in workflows {
      workflow.run()
      let sourceID = workflow.workspace.addInputAudioNode(centeredAt: .zero)
      let visualizerID = workflow.workspace.addVisualizerNode(
        centeredAt: CGPoint(x: 400, y: 0)
      )
      workflow.workspace.selectInputDevice(
        RoutingInputDeviceSelection(id: deviceID, displayName: "Shared Microphone"),
        for: sourceID
      )
      try connect(sourceID: sourceID, targetID: visualizerID, in: workflow.workspace)
      sourceIDs.append(sourceID)
    }

    let requirements = RoutingCaptureRequirementResolver.resolve(
      workflows: workflows,
      catalogSnapshot: nil
    )

    #expect(requirements.inputDeviceIDsByNode.count == 2)
    #expect(Set(requirements.inputDeviceIDsByNode.keys) == Set(sourceIDs))
    #expect(Set(requirements.inputDeviceIDsByNode.values) == [deviceID])
  }

  @Test @MainActor
  func virtualOutputUsesItsStableHiddenReaderDeviceOnlyWhileRoutedAndRunning() throws {
    let endpointID = VirtualAudioEndpointID(
      rawValue: try #require(UUID(uuidString: "769B836F-B771-4C26-899D-3140893C9DC5"))
    )
    let endpoint = VirtualAudioEndpoint(
      id: endpointID,
      configuration: try VirtualAudioEndpointConfiguration(
        name: "Remote Mac Output",
        direction: .output
      )
    )
    let catalog = try VirtualAudioEndpointCatalog(revision: 4, endpoints: [endpoint])
    let bridgeDeviceID = try #require(AudioDeviceID(rawValue: endpoint.deviceUIDs.hostBridge))
    let workflow = RoutingWorkflowModel(name: "Virtual Output")
    let sourceID = workflow.workspace.addVirtualOutputNode(centeredAt: .zero)
    let visualizerID = workflow.workspace.addVisualizerNode(
      centeredAt: CGPoint(x: 400, y: 0)
    )
    workflow.workspace.selectVirtualOutput(
      RoutingVirtualAudioEndpointSelection(
        id: endpoint.id,
        displayName: endpoint.configuration.name
      ),
      for: sourceID
    )
    try connect(sourceID: sourceID, targetID: visualizerID, in: workflow.workspace)

    let paused = RoutingCaptureRequirementResolver.resolve(
      workflows: [workflow],
      catalogSnapshot: nil,
      virtualAudioCatalog: catalog
    )
    #expect(paused.inputDeviceIDsByNode.isEmpty)

    workflow.run()
    let running = RoutingCaptureRequirementResolver.resolve(
      workflows: [workflow],
      catalogSnapshot: nil,
      virtualAudioCatalog: catalog
    )

    #expect(running.inputDeviceIDsByNode == [sourceID: bridgeDeviceID])

    let missing = RoutingCaptureRequirementResolver.resolve(
      workflows: [workflow],
      catalogSnapshot: nil,
      virtualAudioCatalog: .empty
    )
    #expect(missing.inputDeviceIDsByNode.isEmpty)
  }

  @Test @MainActor
  func processTapMutesOrdinaryPlaybackOnlyWhenItsGraphReachesAnOutputDevice() throws {
    let musicURL = URL(fileURLWithPath: "/Applications/Music.app")
    let processID = try #require(AudioProcessID(rawValue: 72))
    let outputDeviceID = try #require(AudioDeviceID(rawValue: "test.output"))
    let workflow = RoutingWorkflowModel(name: "Reroute")
    workflow.run()
    let sourceID = workflow.workspace.addApplicationAudioNode(centeredAt: .zero)
    let outputID = workflow.workspace.addOutputAudioNode(centeredAt: CGPoint(x: 400, y: 0))
    workflow.workspace.selectApplication(
      RoutingApplicationSelection(
        stableID: musicURL.absoluteString,
        applicationURL: musicURL,
        bundleIdentifier: "com.apple.Music",
        displayName: "Music"
      ),
      for: sourceID
    )
    workflow.workspace.selectOutputDevice(
      RoutingOutputDeviceSelection(id: outputDeviceID, displayName: "Test Output"),
      for: outputID
    )
    try connect(sourceID: sourceID, targetID: outputID, in: workflow.workspace)

    let requirements = RoutingCaptureRequirementResolver.resolve(
      workflows: [workflow],
      catalogSnapshot: catalogSnapshot(
        applicationURL: musicURL,
        processIdentifiers: [processID.rawValue]
      )
    )

    #expect(requirements.muteBehaviorsByProcess[processID] == .mutedWhileTapped)
  }

  @Test @MainActor
  func pausedWorkflowsDoNotRequestCaptureWhileOtherConsumersRemainActive() throws {
    let musicURL = URL(fileURLWithPath: "/Applications/Music.app")
    let processID = try #require(AudioProcessID(rawValue: 73))
    let running = RoutingWorkflowModel(name: "Running")
    let paused = RoutingWorkflowModel(name: "Paused")
    let workflows = [running, paused]
    var sourceIDs: [UUID] = []

    for workflow in workflows {
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
      try connect(sourceID: sourceID, targetID: visualizerID, in: workflow.workspace)
      sourceIDs.append(sourceID)
    }
    running.run()

    let requirements = RoutingCaptureRequirementResolver.resolve(
      workflows: workflows,
      catalogSnapshot: catalogSnapshot(
        applicationURL: musicURL,
        processIdentifiers: [processID.rawValue]
      )
    )

    #expect(requirements.processIDsByNode == [sourceIDs[0]: processID])

    running.pause()
    paused.run()
    let switchedRequirements = RoutingCaptureRequirementResolver.resolve(
      workflows: workflows,
      catalogSnapshot: catalogSnapshot(
        applicationURL: musicURL,
        processIdentifiers: [processID.rawValue]
      )
    )

    #expect(switchedRequirements.processIDsByNode == [sourceIDs[1]: processID])
  }

  @Test @MainActor
  func systemDefaultOutputSelectionFollowsCatalogChangesWithoutMutatingTheNode() throws {
    let firstDeviceID = try #require(AudioDeviceID(rawValue: "test.output.first"))
    let secondDeviceID = try #require(AudioDeviceID(rawValue: "test.output.second"))
    let workflow = RoutingWorkflowModel(name: "System Output")
    workflow.run()
    let sourceID = workflow.workspace.addSystemOutputNode(centeredAt: .zero)
    let visualizerID = workflow.workspace.addVisualizerNode(
      centeredAt: CGPoint(x: 400, y: 0)
    )
    workflow.workspace.selectSystemOutput(.systemDefault, for: sourceID)
    try connect(sourceID: sourceID, targetID: visualizerID, in: workflow.workspace)

    let firstRequirements = RoutingCaptureRequirementResolver.resolve(
      workflows: [workflow],
      catalogSnapshot: nil,
      audioCatalogSnapshot: try outputCatalog(
        firstDeviceID: firstDeviceID,
        secondDeviceID: secondDeviceID,
        defaultDeviceID: firstDeviceID
      )
    )
    let secondRequirements = RoutingCaptureRequirementResolver.resolve(
      workflows: [workflow],
      catalogSnapshot: nil,
      audioCatalogSnapshot: try outputCatalog(
        firstDeviceID: firstDeviceID,
        secondDeviceID: secondDeviceID,
        defaultDeviceID: secondDeviceID
      )
    )

    #expect(firstRequirements.outputCaptureDeviceIDsByNode == [sourceID: firstDeviceID])
    #expect(secondRequirements.outputCaptureDeviceIDsByNode == [sourceID: secondDeviceID])
    #expect(workflow.workspace.node(id: sourceID)?.value.outputCaptureSelection == .systemDefault)
    #expect(firstRequirements.muteBehaviorsByProcess.isEmpty)
  }

  @Test @MainActor
  func pinnedOutputCaptureIgnoresDefaultChangesAndUnavailableDevicesAreNotOpened() throws {
    let pinnedDeviceID = try #require(AudioDeviceID(rawValue: "test.output.pinned"))
    let defaultDeviceID = try #require(AudioDeviceID(rawValue: "test.output.default"))
    let workflow = RoutingWorkflowModel(name: "Pinned Output")
    workflow.run()
    let sourceID = workflow.workspace.addSystemOutputNode(centeredAt: .zero)
    let visualizerID = workflow.workspace.addVisualizerNode(
      centeredAt: CGPoint(x: 400, y: 0)
    )
    workflow.workspace.selectSystemOutput(
      .device(RoutingOutputDeviceSelection(id: pinnedDeviceID, displayName: "Pinned")),
      for: sourceID
    )
    try connect(sourceID: sourceID, targetID: visualizerID, in: workflow.workspace)

    let available = RoutingCaptureRequirementResolver.resolve(
      workflows: [workflow],
      catalogSnapshot: nil,
      audioCatalogSnapshot: try outputCatalog(
        firstDeviceID: pinnedDeviceID,
        secondDeviceID: defaultDeviceID,
        defaultDeviceID: defaultDeviceID
      )
    )
    #expect(available.outputCaptureDeviceIDsByNode == [sourceID: pinnedDeviceID])

    let unavailable = RoutingCaptureRequirementResolver.resolve(
      workflows: [workflow],
      catalogSnapshot: nil,
      audioCatalogSnapshot: AudioCatalogSnapshot(
        processes: [],
        devices: [try outputDevice(id: pinnedDeviceID, isDefault: false, isAlive: false)]
      )
    )
    #expect(unavailable.outputCaptureDeviceIDsByNode.isEmpty)
  }

  @Test @MainActor
  func systemDefaultOutputUsesTheCatalogOrderWhenMultipleDevicesAreFlaggedDefault() throws {
    let firstDeviceID = try #require(AudioDeviceID(rawValue: "test.output.ordered-first"))
    let secondDeviceID = try #require(AudioDeviceID(rawValue: "test.output.ordered-second"))
    let workflow = RoutingWorkflowModel(name: "Ordered Default")
    workflow.run()
    let sourceID = workflow.workspace.addSystemOutputNode(centeredAt: .zero)
    let visualizerID = workflow.workspace.addVisualizerNode(
      centeredAt: CGPoint(x: 400, y: 0)
    )
    workflow.workspace.selectSystemOutput(.systemDefault, for: sourceID)
    try connect(sourceID: sourceID, targetID: visualizerID, in: workflow.workspace)

    let requirements = RoutingCaptureRequirementResolver.resolve(
      workflows: [workflow],
      catalogSnapshot: nil,
      audioCatalogSnapshot: AudioCatalogSnapshot(
        processes: [],
        devices: [
          try outputDevice(id: firstDeviceID, isDefault: true, isAlive: true),
          try outputDevice(id: secondDeviceID, isDefault: true, isAlive: true),
        ]
      )
    )

    #expect(requirements.outputCaptureDeviceIDsByNode == [sourceID: firstDeviceID])
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

  private func outputCatalog(
    firstDeviceID: AudioDeviceID,
    secondDeviceID: AudioDeviceID,
    defaultDeviceID: AudioDeviceID
  ) throws -> AudioCatalogSnapshot {
    AudioCatalogSnapshot(
      processes: [],
      devices: [
        try outputDevice(
          id: firstDeviceID,
          isDefault: firstDeviceID == defaultDeviceID,
          isAlive: true
        ),
        try outputDevice(
          id: secondDeviceID,
          isDefault: secondDeviceID == defaultDeviceID,
          isAlive: true
        ),
      ]
    )
  }

  private func outputDevice(
    id: AudioDeviceID,
    isDefault: Bool,
    isAlive: Bool
  ) throws -> AudioDevice {
    let channelID = AudioChannelID(
      ownerID: .destination(.deviceOutput(id)),
      index: try #require(AudioChannelIndex(rawValue: 0))
    )
    return AudioDevice(
      id: id,
      name: id.rawValue,
      transportType: 0,
      nominalSampleRate: 48_000,
      isAlive: isAlive,
      isRunning: true,
      input: nil,
      output: AudioDeviceEndpoint(
        direction: .output,
        isDefault: isDefault,
        channels: [AudioChannel(id: channelID)],
        streams: []
      )
    )
  }
}
