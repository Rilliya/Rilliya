import CoreGraphics
import FlowingDayCanvas
import FlowingDayGraphCanvas
import Foundation
import RilliyaCapture
import RilliyaCore
import RilliyaDSP
import Testing

@testable import Rilliya

@MainActor
struct RoutingWorkflowPersistenceTests {
  @Test
  func noiseGateConfigurationRoundTripsThroughTheWorkflowValueCodec() throws {
    let configuration = RoutingNoiseGateConfiguration(
      thresholdDecibels: -34,
      hysteresisDecibels: 8,
      attackSeconds: 0.01,
      holdSeconds: 0.08,
      releaseSeconds: 0.2,
      reductionDecibels: 54
    )
    let value = RoutingNodeValue.noiseGate(configuration: configuration)

    let encoded = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(RoutingNodeValue.self, from: encoded)

    #expect(decoded == value)
  }

  @Test
  func compressorConfigurationRoundTripsThroughTheWorkflowValueCodec() throws {
    let value = RoutingNodeValue.compressor(
      configuration: RoutingCompressorConfiguration(
        thresholdDecibels: -26,
        ratio: 5,
        kneeDecibels: 9,
        attackSeconds: 0.03,
        releaseSeconds: 0.28,
        makeupGainDecibels: 2
      )
    )

    let encoded = try JSONEncoder().encode(value)
    let decoded = try JSONDecoder().decode(RoutingNodeValue.self, from: encoded)

    #expect(decoded == value)
  }

  @Test
  func restorationRejectsAnExcessiveWorkflowCountBeforeBuildingGraphs() throws {
    let workflows = (0...256).map { RoutingWorkflowModel(name: "Flow \($0 + 1)") }
    let library = RoutingWorkflowLibrary(
      workflows: workflows,
      selectedWorkflowID: workflows[0].id
    )
    let snapshot = RoutingWorkflowLibrarySnapshot(library: library)

    #expect(throws: RoutingWorkflowPersistenceError.graphTooLarge) {
      try snapshot.makeLibrary()
    }
  }

  @Test
  func gainAndChannelRouterConfigurationsRoundTripThroughTheWorkflowValueCodec() throws {
    let values: [RoutingNodeValue] = [
      .gain(
        configuration: RoutingGainConfiguration(
          gainDecibels: -18,
          isMuted: true,
          isPolarityInverted: true
        )
      ),
      .channelRouter(
        configuration: RoutingChannelRouterConfiguration(
          inputChannelCount: 4,
          outputSources: [3, 1, 1, nil]
        )
      ),
    ]

    for value in values {
      let encoded = try JSONEncoder().encode(value)
      let decoded = try JSONDecoder().decode(RoutingNodeValue.self, from: encoded)
      #expect(decoded == value)
    }
  }

  @Test
  func storeRoundTripRestoresGraphsSelectionViewportAndWorkflowOverrides() async throws {
    let fixture = try makeFixture()
    let store = RoutingWorkflowPersistenceStore(fileURL: fixture.fileURL)
    defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

    try await store.save(fixture.snapshot)
    let loadedSnapshot = try #require(try await store.load())
    let restoredLibrary = try loadedSnapshot.makeLibrary()

    #expect(loadedSnapshot == fixture.snapshot)
    #expect(restoredLibrary.selectedWorkflowID == fixture.selectedWorkflowID)
    #expect(restoredLibrary.workflows.count == 2)

    let restoredFirst = try #require(
      restoredLibrary.workflows.first { $0.id == fixture.firstWorkflowID }
    )
    #expect(restoredFirst.name == "Music Monitor")
    #expect(restoredFirst.miniMapVisibilityOverride == false)
    #expect(restoredFirst.runsAutomaticallyOnLaunch)
    #expect(restoredFirst.isRunning)
    #expect(restoredFirst.workspace.nodes.count == 2)
    #expect(restoredFirst.workspace.edges.count == 1)
    #expect(restoredFirst.workspace.edges[0].isEnabled)
    #expect(
      restoredFirst.workspace.nodes.first { $0.id == fixture.sourceID }?
        .audioChannelControls[0]
        == RoutingAudioChannelControl(gainDecibels: -8, isMuted: true)
    )
    #expect(
      restoredFirst.workspace.nodes.first { $0.id == fixture.sourceID }?
        .accentOverride == .rose
    )
    #expect(restoredFirst.canvasSession.viewport.transform.zoom == 1.4)
    #expect(restoredFirst.canvasSession.viewport.transform.offset.width == 48)
    #expect(restoredFirst.canvasSession.viewport.transform.offset.height == -32)

    let restoredInput = try #require(
      restoredLibrary.selectedWorkflow.workspace.nodes.first?.value.inputDeviceSelection
    )
    #expect(restoredInput.id.rawValue == "example.input")
    #expect(restoredInput.displayName == "Studio Input")
    let restoredMixer = try #require(
      restoredLibrary.selectedWorkflow.workspace.node(id: fixture.mixerID)
    )
    #expect(
      restoredMixer.value
        == .audioMixer(configuration: RoutingAudioMixerConfiguration(channelCount: 4))
    )
    #expect(restoredMixer.audioChannelControl(at: 2).isMuted)
    let restoredDelay = try #require(
      restoredLibrary.selectedWorkflow.workspace.node(id: fixture.delayID)
    )
    #expect(
      restoredDelay.value
        == .delay(
          configuration: RoutingDelayConfiguration(
            delaySeconds: 0.375,
            feedback: 0.4,
            dryWetMix: 0.65
          )
        )
    )
    #expect(!restoredLibrary.selectedWorkflow.runsAutomaticallyOnLaunch)
    #expect(!restoredLibrary.selectedWorkflow.isRunning)
  }

  @Test
  func corruptPrimaryDocumentFallsBackToLastValidBackup() async throws {
    let fixture = try makeFixture()
    let store = RoutingWorkflowPersistenceStore(fileURL: fixture.fileURL)
    defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }

    try await store.save(fixture.snapshot)
    let newerLibrary = try fixture.snapshot.makeLibrary()
    newerLibrary.selectedWorkflow.rename(to: "Newer Name")
    let newerSnapshot = RoutingWorkflowLibrarySnapshot(library: newerLibrary)
    try await store.save(newerSnapshot)
    try Data("not-json".utf8).write(to: fixture.fileURL, options: .atomic)

    let recovered = try #require(try await store.load())

    #expect(recovered == fixture.snapshot)
  }

  @Test
  func legacyWorkflowsWithoutAutomaticLaunchRestorePaused() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directoryURL) }
    let encoded = try JSONEncoder().encode(fixture.snapshot)
    var object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    var workflows = try #require(object["workflows"] as? [[String: Any]])
    for index in workflows.indices {
      workflows[index].removeValue(forKey: "runsAutomaticallyOnLaunch")
    }
    object["workflows"] = workflows
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(
      RoutingWorkflowLibrarySnapshot.self,
      from: legacyData
    )
    let library = try decoded.makeLibrary()

    #expect(library.workflows.allSatisfy { !$0.runsAutomaticallyOnLaunch })
    #expect(library.workflows.allSatisfy { !$0.isRunning })
  }

  private func makeFixture() throws -> Fixture {
    let directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("RilliyaWorkflowPersistence-\(UUID().uuidString)")
    let fileURL = directoryURL.appendingPathComponent("workflows.json")
    let firstWorkflowID = UUID()
    let sourceID = UUID()
    let visualizerID = UUID()
    let outputPort = RoutingGraphPortID(direction: .output, channel: .all)
    let inputPort = RoutingGraphPortID(direction: .input, channel: .all)
    let applicationURL = URL(fileURLWithPath: "/Applications/Music.app")
    let source = RoutingWorkspaceNode(
      id: sourceID,
      value: .applicationAudio(
        selection: RoutingApplicationSelection(
          stableID: applicationURL.absoluteString,
          applicationURL: applicationURL,
          bundleIdentifier: "com.apple.Music",
          displayName: "Music"
        ),
        channelPresentation: .aggregate
      ),
      frame: CGRect(x: 80, y: 120, width: 252, height: 80),
      audioChannelControls: [
        0: RoutingAudioChannelControl(gainDecibels: -8, isMuted: true)
      ],
      accentOverride: .rose
    )
    let visualizer = RoutingWorkspaceNode(
      id: visualizerID,
      value: .visualizer(configuration: .initial),
      frame: CGRect(x: 420, y: 120, width: 252, height: 128)
    )
    let edge = RoutingWorkspaceEdge(
      id: UUID(),
      source: RoutingWorkspacePortAddress(nodeID: sourceID, portID: outputPort),
      target: RoutingWorkspacePortAddress(nodeID: visualizerID, portID: inputPort)
    )
    let firstWorkspace = try RoutingWorkspaceModel(
      restoringID: firstWorkflowID,
      nodes: [source, visualizer],
      edges: [edge]
    )
    let firstWorkflow = RoutingWorkflowModel(
      id: firstWorkflowID,
      name: "Music Monitor",
      workspace: firstWorkspace,
      miniMapVisibilityOverride: false,
      runsAutomaticallyOnLaunch: true,
      canvasSession: FlowingGraphCanvasSessionState(
        viewport: FlowingCanvasViewport(
          transform: FlowingCanvasTransform(
            zoom: 1.4,
            offset: CGSize(width: 48, height: -32)
          )
        )
      )
    )

    let secondWorkflowID = UUID()
    let secondWorkspace = RoutingWorkspaceModel(id: secondWorkflowID)
    let inputID = secondWorkspace.addInputAudioNode(centeredAt: .zero)
    secondWorkspace.selectInputDevice(
      RoutingInputDeviceSelection(
        id: try #require(AudioDeviceID(rawValue: "example.input")),
        displayName: "Studio Input"
      ),
      for: inputID
    )
    let mixerID = secondWorkspace.addAudioMixerNode(centeredAt: CGPoint(x: 360, y: 0))
    secondWorkspace.configureAudioMixer(
      RoutingAudioMixerConfiguration(channelCount: 4),
      for: mixerID
    )
    secondWorkspace.setAudioChannelMuted(true, nodeID: mixerID, channelIndex: 2)
    let delayID = secondWorkspace.addDelayNode(centeredAt: CGPoint(x: 720, y: 0))
    secondWorkspace.configureDelay(
      RoutingDelayConfiguration(
        delaySeconds: 0.375,
        feedback: 0.4,
        dryWetMix: 0.65
      ),
      for: delayID
    )
    let secondWorkflow = RoutingWorkflowModel(
      id: secondWorkflowID,
      name: "Input Lab",
      workspace: secondWorkspace,
      miniMapVisibilityOverride: true
    )
    let library = RoutingWorkflowLibrary(
      workflows: [firstWorkflow, secondWorkflow],
      selectedWorkflowID: secondWorkflowID
    )
    return Fixture(
      directoryURL: directoryURL,
      fileURL: fileURL,
      snapshot: RoutingWorkflowLibrarySnapshot(library: library),
      firstWorkflowID: firstWorkflowID,
      sourceID: sourceID,
      mixerID: mixerID,
      delayID: delayID,
      selectedWorkflowID: secondWorkflowID
    )
  }
}

private struct Fixture {
  let directoryURL: URL
  let fileURL: URL
  let snapshot: RoutingWorkflowLibrarySnapshot
  let firstWorkflowID: UUID
  let sourceID: UUID
  let mixerID: UUID
  let delayID: UUID
  let selectedWorkflowID: UUID
}
