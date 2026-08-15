import CoreGraphics
import FlowingDayCanvas
import FlowingDayGraphCanvas
import Foundation
import RilliyaKit
import Testing

@testable import Rilliya

@MainActor
struct RoutingWorkflowPersistenceTests {
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
    #expect(restoredFirst.workspace.nodes.count == 2)
    #expect(restoredFirst.workspace.edges.count == 1)
    #expect(restoredFirst.workspace.edges[0].isEnabled)
    #expect(
      restoredFirst.workspace.nodes.first { $0.id == fixture.sourceID }?
        .audioChannelControls[0]
        == RoutingAudioChannelControl(gainDecibels: -8, isMuted: true)
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
      ]
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
  let selectedWorkflowID: UUID
}
