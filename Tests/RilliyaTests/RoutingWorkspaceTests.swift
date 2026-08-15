import CoreGraphics
import FlowingDayGraphCanvas
import Foundation
import RilliyaKit
import Testing

@testable import Rilliya

struct RoutingWorkspaceTests {
  @Test @MainActor
  func emptyWorkspaceBuildsValidCanvasContent() throws {
    let model = RoutingWorkspaceModel()
    let content = try #require(model.canvasContent)
    let accessibilitySnapshot = try #require(model.accessibilitySnapshot)

    #expect(model.nodes.isEmpty)
    #expect(content.presentation.nodes.isEmpty)
    #expect(content.contentBounds == RoutingCanvasMetrics.contentBounds)
    #expect(accessibilitySnapshot.items.isEmpty)
    #expect(model.buildFailureDescription == nil)
  }

  @Test
  func keyboardInsertionUsesCurrentVisibleWorldCenter() {
    let visibleWorldRect = CGRect(x: 1_200, y: -640, width: 900, height: 520)

    let firstPoint = RoutingNodeInsertion.point(
      in: visibleWorldRect,
      existingNodeCount: 0
    )
    let subsequentPoints = (1...5).map {
      RoutingNodeInsertion.point(in: visibleWorldRect, existingNodeCount: $0)
    }

    #expect(firstPoint == CGPoint(x: 1_650, y: -380))
    #expect(
      subsequentPoints == [
        CGPoint(x: 1_370, y: -380),
        CGPoint(x: 1_930, y: -380),
        CGPoint(x: 1_650, y: -224),
        CGPoint(x: 1_370, y: -224),
        CGPoint(x: 1_930, y: -224),
      ])
    let allPoints = [firstPoint] + subsequentPoints
    for firstIndex in allPoints.indices {
      for secondIndex in allPoints.indices where firstIndex < secondIndex {
        let firstFrame = nodeFrame(centeredAt: allPoints[firstIndex])
        let secondFrame = nodeFrame(centeredAt: allPoints[secondIndex])
        #expect(!firstFrame.intersects(secondFrame))
      }
    }
  }

  private func nodeFrame(centeredAt point: CGPoint) -> CGRect {
    CGRect(
      x: point.x - RoutingCanvasMetrics.baseNodeSize.width / 2,
      y: point.y - RoutingCanvasMetrics.baseNodeSize.height / 2,
      width: RoutingCanvasMetrics.baseNodeSize.width,
      height: RoutingCanvasMetrics.baseNodeSize.height
    )
  }

  @Test @MainActor
  func dropCreatesCenteredApplicationAudioPlaceholder() throws {
    let model = RoutingWorkspaceModel()
    let dropPoint = CGPoint(x: 320, y: 240)

    let nodeID = model.addApplicationAudioNode(centeredAt: dropPoint)

    let node = try #require(model.node(id: nodeID))
    #expect(node.frame.size == RoutingCanvasMetrics.baseNodeSize)
    #expect(CGPoint(x: node.frame.midX, y: node.frame.midY) == dropPoint)
    #expect(node.value.applicationSelection == nil)
    #expect(model.canvasContent?.presentation.nodes.count == 1)
    #expect(
      model.accessibilitySnapshot?.items.first?.description.value == "No application selected")
  }

  @Test @MainActor
  func peakLevelInsertionBuildsCenteredTypedNode() throws {
    let model = RoutingWorkspaceModel()
    let center = CGPoint(x: 420, y: 260)

    let nodeID = model.addPeakLevelNode(centeredAt: center)

    let node = try #require(model.node(id: nodeID))
    #expect(node.value == .peakLevel)
    #expect(CGPoint(x: node.frame.midX, y: node.frame.midY) == center)
    #expect(RoutingGraphPorts.values(for: node).count == 2)
  }

  @Test @MainActor
  func signalGeneratorInsertionBuildsOneConfigurableMonoOutput() throws {
    let model = RoutingWorkspaceModel()
    let center = CGPoint(x: 420, y: 260)

    let nodeID = model.addSignalGeneratorNode(centeredAt: center)
    var configuration = RoutingSignalGeneratorConfiguration.initial
    configuration.waveform = .pinkNoise
    configuration.amplitude = 0.4
    model.configureSignalGenerator(configuration, for: nodeID)

    let node = try #require(model.node(id: nodeID))
    #expect(node.value == .signalGenerator(configuration: configuration))
    #expect(CGPoint(x: node.frame.midX, y: node.frame.midY) == center)
    let ports = RoutingGraphPorts.values(for: node)
    #expect(ports.count == 1)
    let port = try #require(ports.first)
    #expect(port.direction == .output)
    #expect(port.audioChannel == .channel(0))
    #expect(port.signalType == .audio)
  }

  @Test @MainActor
  func delayInsertionBuildsOneTypedInputAndOutput() throws {
    let model = RoutingWorkspaceModel()
    let center = CGPoint(x: 420, y: 260)
    let nodeID = model.addDelayNode(centeredAt: center)
    let configuration = RoutingDelayConfiguration(
      delaySeconds: 0.5,
      feedback: 0.4,
      dryWetMix: 0.75
    )

    model.configureDelay(configuration, for: nodeID)

    let node = try #require(model.node(id: nodeID))
    #expect(node.value == .delay(configuration: configuration))
    #expect(CGPoint(x: node.frame.midX, y: node.frame.midY) == center)
    let ports = RoutingGraphPorts.values(for: node)
    #expect(ports.count == 2)
    #expect(ports[0].direction == .input)
    #expect(ports[0].audioChannel == .all)
    #expect(ports[0].connectionPolicy == .singleInput)
    #expect(ports[1].direction == .output)
    #expect(ports[1].audioChannel == .all)
    #expect(ports[1].connectionPolicy == .fanOut)
  }

  @Test @MainActor
  func inputAudioUsesPersistentDeviceIdentityAndRuntimeChannels() throws {
    let model = RoutingWorkspaceModel()
    let center = CGPoint(x: 420, y: 260)
    let nodeID = model.addInputAudioNode(centeredAt: center)
    let deviceID = try #require(AudioDeviceID(rawValue: "virtual-input"))
    let selection = RoutingInputDeviceSelection(id: deviceID, displayName: "Virtual Input")

    model.selectInputDevice(selection, for: nodeID)
    model.setInputDeviceChannelPresentation(.separate(channelCount: 8), for: nodeID)
    model.synchronizeInputCaptureFormats([
      nodeID: try inputCaptureFormat(deviceID: deviceID, channelCount: 2)
    ])

    let synchronizedFormat = try #require(model.runtimeCaptureFormats[nodeID])
    let synchronizedContent = try #require(model.canvasContent)
    model.selectInputDevice(selection, for: nodeID)

    let node = try #require(model.node(id: nodeID))
    #expect(node.value.inputDeviceSelection == selection)
    #expect(node.value.channelPresentation == .separate(channelCount: 2))
    #expect(model.runtimeCaptureFormats[nodeID] == synchronizedFormat)
    #expect(
      model.canvasContent?.presentation.snapshotID == synchronizedContent.presentation.snapshotID)
    #expect(CGPoint(x: node.frame.midX, y: node.frame.midY) == center)
    let ports = RoutingGraphPorts.values(for: node)
    #expect(ports.count == 2)
    #expect(ports.allSatisfy { $0.direction == .output })
  }

  @Test @MainActor
  func audioChannelControlsAreNodeLocalAndResetWhenTheSourceChanges() throws {
    let model = RoutingWorkspaceModel()
    let firstID = model.addApplicationAudioNode(centeredAt: .zero)
    let secondID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 300, y: 0))
    let firstSelection = makeSelection(name: "Music", identifier: "com.apple.Music")

    model.selectApplication(firstSelection, for: firstID)
    let graphSnapshotID = model.canvasContent?.presentation.snapshotID
    model.setAudioChannelGain(-12, nodeID: firstID, channelIndex: 0)
    model.setAudioChannelMuted(true, nodeID: firstID, channelIndex: 1)

    #expect(model.audioChannelControl(nodeID: firstID, channelIndex: 0).gainDecibels == -12)
    #expect(model.audioChannelControl(nodeID: firstID, channelIndex: 1).isMuted)
    #expect(model.node(id: secondID)?.audioChannelControls.isEmpty == true)
    #expect(model.canvasContent?.presentation.snapshotID == graphSnapshotID)

    model.selectApplication(
      makeSelection(name: "Podcasts", identifier: "com.apple.podcasts"),
      for: firstID
    )

    #expect(model.node(id: firstID)?.audioChannelControls.isEmpty == true)
  }

  @Test @MainActor
  func selectingApplicationUpdatesOnlyRequestedNode() throws {
    let model = RoutingWorkspaceModel()
    let firstID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))
    let secondID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 500, y: 300))
    let selection = makeSelection(name: "Player", identifier: "com.example.player")

    model.selectApplication(selection, for: firstID)

    #expect(model.node(id: firstID)?.value.applicationSelection == selection)
    #expect(model.node(id: secondID)?.value.applicationSelection == nil)
    #expect(model.nodes.count == 2)
    #expect(model.node(id: firstID)?.frame.height == 80)
    #expect(model.node(id: secondID)?.frame.height == RoutingCanvasMetrics.baseNodeSize.height)
  }

  @Test @MainActor
  func sequentialSelectionsRemainIndependentAcrossCanvasRebuilds() throws {
    let model = RoutingWorkspaceModel()
    let firstID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))
    let secondID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 500, y: 300))
    let firstElementID = try #require(model.elementID(for: firstID))
    let firstSelection = makeSelection(name: "Calculator", identifier: "com.apple.calculator")
    let secondSelection = makeSelection(name: "Music", identifier: "com.apple.Music")

    model.selectApplication(firstSelection, for: firstID)
    model.selectApplication(secondSelection, for: secondID)

    #expect(model.node(id: firstID)?.value.applicationSelection == firstSelection)
    #expect(model.node(id: secondID)?.value.applicationSelection == secondSelection)
    #expect(model.elementID(for: firstID) == firstElementID)
    let presentedValues: [UUID: String] = Dictionary(
      uniqueKeysWithValues: try #require(model.canvasContent).presentation.nodes.compactMap {
        node in
        guard case .node(let nodeID) = node.address.elementID,
          let name = node.value.applicationSelection?.displayName
        else {
          return nil
        }
        return (nodeID, name)
      }
    )
    #expect(presentedValues[firstID] == "Calculator")
    #expect(presentedValues[secondID] == "Music")
  }

  @Test @MainActor
  func applicationAndVisualizerExposeAggregatePortsByDefault() throws {
    let model = RoutingWorkspaceModel()
    _ = model.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))
    _ = model.addVisualizerNode(centeredAt: CGPoint(x: 500, y: 100))

    let ports = try #require(model.canvasContent).presentation.ports

    #expect(ports.count == 3)
    #expect(ports.contains { $0.value.direction == .output && $0.value.audioChannel == .all })
    #expect(ports.contains { $0.value.direction == .input && $0.value.audioChannel == .all })
    #expect(
      ports.filter { $0.value.direction == .output && $0.value.audioChannel == .all }.count
        == 2)
  }

  @Test @MainActor
  func separateChannelPresentationCreatesOnePortPerChannel() throws {
    let model = RoutingWorkspaceModel()
    let applicationID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))
    let visualizerID = model.addVisualizerNode(centeredAt: CGPoint(x: 500, y: 100))

    model.setApplicationChannelPresentation(.separate(channelCount: 3), for: applicationID)
    model.configureVisualizer(
      RoutingVisualizerConfiguration(
        mode: .separate,
        availableChannelCount: 5,
        selectedChannels: [1, 4]
      ),
      for: visualizerID
    )

    let ports = try #require(model.canvasContent).presentation.ports
    let outputChannels = ports.compactMap { port -> Int? in
      guard port.value.direction == .output,
        case .some(.channel(let index)) = port.value.audioChannel
      else {
        return nil
      }
      return index
    }
    let inputChannels = ports.compactMap { port -> Int? in
      guard port.value.direction == .input,
        case .some(.channel(let index)) = port.value.audioChannel
      else {
        return nil
      }
      return index
    }

    #expect(outputChannels.sorted() == [0, 1, 1, 2, 4])
    #expect(inputChannels.sorted() == [1, 4])
  }

  @Test @MainActor
  func completedConnectionCreatesRoutedCanvasEdge() throws {
    let model = RoutingWorkspaceModel()
    _ = model.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))
    _ = model.addVisualizerNode(centeredAt: CGPoint(x: 500, y: 100))
    let content = try #require(model.canvasContent)
    let source = try #require(
      content.presentation.ports.first { $0.value.direction == .output }
    )
    let target = try #require(
      content.presentation.ports.first { $0.value.direction == .input }
    )
    let intent = FlowingGraphCanvasConnectionCompletionIntent<RoutingCanvasSchema>(
      operation: .create(sourcePortID: source.id, targetPortID: target.id),
      basePresentationSnapshotID: content.presentation.snapshotID,
      baseLayoutInputID: content.id
    )

    model.send(.connectionCompleted(intent))

    #expect(model.edges.count == 1)
    #expect(model.canvasContent?.presentation.edges.count == 1)
  }

  @Test @MainActor
  func disabledConnectionStopsParticipatingWithoutLosingItsTopology() throws {
    let model = RoutingWorkspaceModel()
    let sourceID = model.addApplicationAudioNode(centeredAt: .zero)
    let visualizerID = model.addVisualizerNode(centeredAt: CGPoint(x: 400, y: 0))
    try connectAggregate(sourceID: sourceID, targetID: visualizerID, model: model)
    let edgeID = try #require(model.edges.first?.id)

    model.toggleEdgeEnabled(id: edgeID)

    #expect(model.edges.first?.isEnabled == false)
    #expect(model.canvasContent?.presentation.edges.first?.value.isEnabled == false)
    #expect(model.incomingEdges(for: visualizerID).isEmpty)
    #expect(model.activeIncomingEdgesByTargetNode()[visualizerID] == nil)
    #expect(!model.captureSourceNodeIDs.contains(sourceID))

    model.toggleEdgeEnabled(id: edgeID)

    #expect(model.edges.first?.isEnabled == true)
    #expect(model.incomingEdges(for: visualizerID).count == 1)
    #expect(model.activeIncomingEdgesByTargetNode()[visualizerID]?.count == 1)
    #expect(model.captureSourceNodeIDs.contains(sourceID))
  }

  @Test @MainActor
  func disabledPortSuspendsRoutesWithoutDeletingTheirTopology() throws {
    let model = RoutingWorkspaceModel()
    let sourceID = model.addApplicationAudioNode(centeredAt: .zero)
    let targetID = model.addVisualizerNode(centeredAt: CGPoint(x: 400, y: 0))
    try connectAggregate(sourceID: sourceID, targetID: targetID, model: model)
    let outputID = RoutingGraphPortID(direction: .output, channel: .all)

    model.setPortEnabled(false, nodeID: sourceID, portID: outputID)

    #expect(model.edges.count == 1)
    #expect(model.edges.first?.isEnabled == true)
    #expect(model.captureSourceNodeIDs.isEmpty)
    #expect(model.incomingEdges(for: targetID).isEmpty)
    #expect(model.canvasContent?.presentation.edges.first?.value.isActive == false)
    #expect(model.canvasContent?.presentation.edges.first?.value.isEnabled == true)

    model.setPortEnabled(true, nodeID: sourceID, portID: outputID)

    #expect(model.captureSourceNodeIDs == [sourceID])
    #expect(model.incomingEdges(for: targetID).count == 1)
    #expect(model.canvasContent?.presentation.edges.first?.value.isActive == true)
  }

  @Test @MainActor
  func removingAConnectionRebuildsTheProjectedGraph() throws {
    let model = RoutingWorkspaceModel()
    let sourceID = model.addApplicationAudioNode(centeredAt: .zero)
    let visualizerID = model.addVisualizerNode(centeredAt: CGPoint(x: 400, y: 0))
    try connectAggregate(sourceID: sourceID, targetID: visualizerID, model: model)
    let edgeID = try #require(model.edges.first?.id)

    model.removeEdges(ids: [edgeID])

    #expect(model.edges.isEmpty)
    #expect(model.canvasContent?.presentation.edges.isEmpty == true)
  }

  @Test @MainActor
  func removingNodesAlsoRemovesRoutesAndRuntimeState() throws {
    let model = RoutingWorkspaceModel()
    let sourceID = model.addApplicationAudioNode(centeredAt: .zero)
    let visualizerID = model.addVisualizerNode(centeredAt: CGPoint(x: 400, y: 0))
    try connectAggregate(sourceID: sourceID, targetID: visualizerID, model: model)
    model.synchronizeCaptureFormats([
      sourceID: try captureFormat(channelCount: 2)
    ])

    model.removeNodes(ids: [sourceID])

    #expect(model.nodes.map(\.id) == [visualizerID])
    #expect(model.edges.isEmpty)
    #expect(model.runtimeCaptureFormats[sourceID] == nil)
    #expect(model.captureSourceNodeIDs.isEmpty)
    #expect(model.canvasContent?.presentation.nodes.count == 1)
    #expect(model.canvasContent?.presentation.edges.isEmpty == true)
  }

  @Test @MainActor
  func removingUnknownNodesDoesNotRebuildTheCanvas() throws {
    let model = RoutingWorkspaceModel()
    _ = model.addVisualizerNode(centeredAt: .zero)
    let snapshotID = try #require(model.canvasContent?.presentation.snapshotID)

    model.removeNodes(ids: [UUID()])

    #expect(model.canvasContent?.presentation.snapshotID == snapshotID)
  }

  @Test @MainActor
  func peakLevelAcceptsOnlyOneEnabledInput() throws {
    let model = RoutingWorkspaceModel()
    let firstSourceID = model.addApplicationAudioNode(centeredAt: .zero)
    let secondSourceID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 0, y: 220))
    let peakID = model.addPeakLevelNode(centeredAt: CGPoint(x: 400, y: 100))

    try connectAggregate(sourceID: firstSourceID, targetID: peakID, model: model)
    try connectAggregate(sourceID: secondSourceID, targetID: peakID, model: model)

    #expect(model.edges.count == 1)
    #expect(model.captureSourceNodeIDs == [firstSourceID])
  }

  @Test @MainActor
  func audioMixerAcceptsMultipleInputsPerChannelAndFansOutItsOutputs() throws {
    let model = RoutingWorkspaceModel()
    let firstSourceID = model.addApplicationAudioNode(centeredAt: .zero)
    let secondSourceID = model.addInputAudioNode(centeredAt: CGPoint(x: 0, y: 220))
    let mixerID = model.addAudioMixerNode(centeredAt: CGPoint(x: 420, y: 100))
    model.setApplicationChannelPresentation(.separate(channelCount: 1), for: firstSourceID)
    model.setInputDeviceChannelPresentation(.separate(channelCount: 1), for: secondSourceID)

    try connectChannel(
      sourceID: firstSourceID,
      sourceChannel: 0,
      targetID: mixerID,
      targetChannel: 0,
      model: model
    )
    try connectChannel(
      sourceID: secondSourceID,
      sourceChannel: 0,
      targetID: mixerID,
      targetChannel: 0,
      model: model
    )

    #expect(model.edges.count == 2)
    #expect(model.incomingEdges(for: mixerID).count == 2)
    let ports = RoutingGraphPorts.values(for: try #require(model.node(id: mixerID)))
    #expect(
      ports.filter { $0.direction == .input }.allSatisfy {
        $0.connectionPolicy == .mixingInput
      })
    #expect(
      ports.filter { $0.direction == .output }.allSatisfy {
        $0.connectionPolicy == .fanOut
      })
  }

  @Test @MainActor
  func expandingMixerPreservesExistingRoutesAndChannelControls() throws {
    let model = RoutingWorkspaceModel()
    let sourceID = model.addApplicationAudioNode(centeredAt: .zero)
    let mixerID = model.addAudioMixerNode(centeredAt: CGPoint(x: 420, y: 0))
    model.setApplicationChannelPresentation(.separate(channelCount: 1), for: sourceID)
    try connectChannel(
      sourceID: sourceID,
      sourceChannel: 0,
      targetID: mixerID,
      targetChannel: 0,
      model: model
    )
    model.setAudioChannelGain(-12, nodeID: mixerID, channelIndex: 0)
    let originalFrame = try #require(model.node(id: mixerID)).frame
    let center = CGPoint(x: originalFrame.midX, y: originalFrame.midY)

    model.configureAudioMixer(RoutingAudioMixerConfiguration(channelCount: 4), for: mixerID)

    let mixer = try #require(model.node(id: mixerID))
    #expect(model.edges.count == 1)
    #expect(mixer.audioChannelControl(at: 0).gainDecibels == -12)
    #expect(CGPoint(x: mixer.frame.midX, y: mixer.frame.midY) == center)
    #expect(RoutingGraphPorts.values(for: mixer).count == 8)
  }

  @Test @MainActor
  func disabledPeakInputCannotBeReenabledOverAnotherActiveInput() throws {
    let model = RoutingWorkspaceModel()
    let firstSourceID = model.addApplicationAudioNode(centeredAt: .zero)
    let secondSourceID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 0, y: 220))
    let peakID = model.addPeakLevelNode(centeredAt: CGPoint(x: 400, y: 100))
    try connectAggregate(sourceID: firstSourceID, targetID: peakID, model: model)
    let firstEdgeID = try #require(model.edges.first?.id)
    model.toggleEdgeEnabled(id: firstEdgeID)
    try connectAggregate(sourceID: secondSourceID, targetID: peakID, model: model)

    model.toggleEdgeEnabled(id: firstEdgeID)

    #expect(model.edges.count == 2)
    #expect(model.edges.first { $0.id == firstEdgeID }?.isEnabled == false)
    #expect(model.incomingEdges(for: peakID).map(\.source.nodeID) == [secondSourceID])
  }

  @Test @MainActor
  func existingChannelRouteSurvivesAChannelCountIncrease() throws {
    let model = RoutingWorkspaceModel()
    let applicationID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))
    _ = model.addVisualizerNode(centeredAt: CGPoint(x: 500, y: 100))
    model.setApplicationChannelPresentation(.separate(channelCount: 2), for: applicationID)
    let content = try #require(model.canvasContent)
    let source = try #require(
      content.presentation.ports.first {
        $0.value.direction == .output && $0.value.audioChannel == .channel(0)
      }
    )
    let target = try #require(
      content.presentation.ports.first { $0.value.direction == .input }
    )
    model.send(
      .connectionCompleted(
        FlowingGraphCanvasConnectionCompletionIntent(
          operation: .create(sourcePortID: source.id, targetPortID: target.id),
          basePresentationSnapshotID: content.presentation.snapshotID,
          baseLayoutInputID: content.id
        )
      )
    )

    model.setApplicationChannelPresentation(.separate(channelCount: 3), for: applicationID)

    #expect(model.edges.count == 1)
    #expect(model.canvasContent?.presentation.edges.count == 1)
  }

  @Test @MainActor
  func reducerAllowsRemappingOneAudioChannelToAnotherLane() throws {
    let model = RoutingWorkspaceModel()
    let applicationID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))
    let visualizerID = model.addVisualizerNode(centeredAt: CGPoint(x: 500, y: 100))
    model.setApplicationChannelPresentation(.separate(channelCount: 2), for: applicationID)
    model.configureVisualizer(
      RoutingVisualizerConfiguration(
        mode: .separate,
        availableChannelCount: 2,
        selectedChannels: [1]
      ),
      for: visualizerID
    )
    let content = try #require(model.canvasContent)
    let source = try #require(
      content.presentation.ports.first {
        $0.value.direction == .output && $0.value.audioChannel == .channel(0)
      }
    )
    let target = try #require(
      content.presentation.ports.first {
        $0.value.direction == .input && $0.value.audioChannel == .channel(1)
      }
    )

    model.send(
      .connectionCompleted(
        FlowingGraphCanvasConnectionCompletionIntent(
          operation: .create(sourcePortID: source.id, targetPortID: target.id),
          basePresentationSnapshotID: content.presentation.snapshotID,
          baseLayoutInputID: content.id
        )
      )
    )

    #expect(model.edges.count == 1)
  }

  @Test @MainActor
  func nodeHeightKeepsDenseChannelPortsSeparated() throws {
    let model = RoutingWorkspaceModel()
    let applicationID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))

    model.setApplicationChannelPresentation(.separate(channelCount: 32), for: applicationID)

    let node = try #require(model.node(id: applicationID))
    #expect(node.frame.height >= 32 * 18)
    #expect(node.frame.width == RoutingCanvasMetrics.baseNodeSize.width)
  }

  @Test @MainActor
  func validDragIntentMovesNodeByWorldTranslation() throws {
    let model = RoutingWorkspaceModel()
    let nodeID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 200, y: 180))
    let originalFrame = try #require(model.node(id: nodeID)?.frame)
    let intent = try makeDragIntent(
      model: model,
      nodeID: nodeID,
      translation: CGSize(width: 48, height: -32)
    )

    model.send(.nodeDragCompleted(intent))

    let movedFrame = try #require(model.node(id: nodeID)?.frame)
    #expect(movedFrame.origin.x == originalFrame.origin.x + 48)
    #expect(movedFrame.origin.y == originalFrame.origin.y - 32)
    #expect(movedFrame.size == originalFrame.size)
  }

  @Test @MainActor
  func staleDragIntentDoesNotMoveNode() throws {
    let model = RoutingWorkspaceModel()
    let nodeID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 240, y: 220))
    let staleIntent = try makeDragIntent(
      model: model,
      nodeID: nodeID,
      translation: CGSize(width: 80, height: 40)
    )
    model.selectApplication(
      makeSelection(name: "Recorder", identifier: "com.example.recorder"),
      for: nodeID
    )
    let frameAfterRebuild = try #require(model.node(id: nodeID)?.frame)

    model.send(.nodeDragCompleted(staleIntent))

    #expect(model.node(id: nodeID)?.frame == frameAfterRebuild)
  }

  @Test @MainActor
  func runtimeFormatUpdatesSeparatePortsWithoutSelectingTheNode() throws {
    let model = RoutingWorkspaceModel()
    let sourceID = model.addApplicationAudioNode(centeredAt: .zero)
    model.setApplicationChannelPresentation(.separate(channelCount: 2), for: sourceID)

    model.synchronizeCaptureFormats([
      sourceID: try captureFormat(channelCount: 4)
    ])

    #expect(model.node(id: sourceID)?.value.channelPresentation == .separate(channelCount: 4))
    let outputChannels = try #require(model.canvasContent).presentation.ports.compactMap {
      port -> Int? in
      guard port.value.direction == .output,
        case .some(.channel(let channel)) = port.value.audioChannel
      else {
        return nil
      }
      return channel
    }
    #expect(outputChannels.sorted() == [0, 1, 2, 3])
  }

  @Test @MainActor
  func knownRuntimeFormatMigratesMixedRouteToOneEdgePerChannel() throws {
    let model = RoutingWorkspaceModel()
    let sourceID = model.addApplicationAudioNode(centeredAt: .zero)
    let visualizerID = model.addVisualizerNode(centeredAt: CGPoint(x: 400, y: 0))
    try connectAggregate(sourceID: sourceID, targetID: visualizerID, model: model)
    model.synchronizeCaptureFormats([
      sourceID: try captureFormat(channelCount: 2)
    ])
    var configuration = RoutingVisualizerConfiguration.initial
    configuration.mode = .separate

    model.configureVisualizer(configuration, for: visualizerID)

    #expect(model.node(id: sourceID)?.value.channelPresentation == .separate(channelCount: 2))
    #expect(model.edges.count == 2)
    #expect(
      Set(model.edges.compactMap { $0.source.portID.audioChannel })
        == [.channel(0), .channel(1)]
    )
    #expect(
      Set(model.edges.compactMap { $0.target.portID.audioChannel })
        == [.channel(0), .channel(1)]
    )
  }

  @Test @MainActor
  func preferredStereoLayoutDoesNotExposeSilentNativeSurroundLanes() throws {
    let model = RoutingWorkspaceModel()
    let sourceID = model.addApplicationAudioNode(centeredAt: .zero)
    let visualizerID = model.addVisualizerNode(centeredAt: CGPoint(x: 400, y: 0))
    try connectAggregate(sourceID: sourceID, targetID: visualizerID, model: model)
    model.synchronizeCaptureFormats(
      [sourceID: try captureFormat(channelCount: 8)],
      preferredSeparateChannelCount: 2
    )
    var configuration = RoutingVisualizerConfiguration.initial
    configuration.mode = .separate

    model.configureVisualizer(configuration, for: visualizerID)

    #expect(model.node(id: sourceID)?.value.channelPresentation == .separate(channelCount: 2))
    #expect(model.edges.count == 2)
    #expect(
      Set(model.edges.compactMap { $0.source.portID.audioChannel })
        == [.channel(0), .channel(1)]
    )
    #expect(
      model.node(id: visualizerID)?.value
        == .visualizer(
          configuration: RoutingVisualizerConfiguration(
            mode: .separate,
            availableChannelCount: 2,
            channelSelection: .preset(.stereo)
          )
        )
    )
  }

  @Test @MainActor
  func explicitVisualizerPresetOverridesTheAutomaticChannelDefault() throws {
    let model = RoutingWorkspaceModel()
    let sourceID = model.addApplicationAudioNode(centeredAt: .zero)
    let visualizerID = model.addVisualizerNode(centeredAt: CGPoint(x: 400, y: 0))
    try connectAggregate(sourceID: sourceID, targetID: visualizerID, model: model)
    model.synchronizeCaptureFormats(
      [sourceID: try captureFormat(channelCount: 8)],
      preferredSeparateChannelCount: 2
    )
    var configuration = RoutingVisualizerConfiguration.initial
    configuration.mode = .separate
    model.configureVisualizer(configuration, for: visualizerID)

    configuration = try #require(model.node(id: visualizerID)?.value.visualizerConfiguration)
    configuration.channelSelection = .preset(.surround51)
    model.configureVisualizer(configuration, for: visualizerID)

    #expect(model.node(id: sourceID)?.value.channelPresentation == .separate(channelCount: 6))
    #expect(model.edges.count == 6)
    #expect(
      Set(model.edges.compactMap { $0.target.portID.audioChannel })
        == Set((0..<6).map(RoutingAudioPortChannel.channel))
    )
  }

  @Test @MainActor
  func pendingSeparateRouteKeepsCaptureAliveUntilFormatArrives() throws {
    let model = RoutingWorkspaceModel()
    let sourceID = model.addApplicationAudioNode(centeredAt: .zero)
    let visualizerID = model.addVisualizerNode(centeredAt: CGPoint(x: 400, y: 0))
    try connectAggregate(sourceID: sourceID, targetID: visualizerID, model: model)
    var configuration = RoutingVisualizerConfiguration.initial
    configuration.mode = .separate

    model.configureVisualizer(configuration, for: visualizerID)

    #expect(model.edges.isEmpty)
    #expect(model.captureSourceNodeIDs == [sourceID])

    model.synchronizeCaptureFormats([
      sourceID: try captureFormat(channelCount: 2)
    ])

    #expect(model.edges.count == 2)
    #expect(model.captureSourceNodeIDs == [sourceID])
  }

  @Test @MainActor
  func largeRuntimeFormatExposesOnlyTheRequestedPresetPorts() throws {
    let model = RoutingWorkspaceModel()
    let sourceID = model.addApplicationAudioNode(centeredAt: .zero)
    let visualizerID = model.addVisualizerNode(centeredAt: CGPoint(x: 400, y: 0))
    try connectAggregate(sourceID: sourceID, targetID: visualizerID, model: model)
    model.synchronizeCaptureFormats([
      sourceID: try captureFormat(channelCount: 48)
    ])
    var configuration = RoutingVisualizerConfiguration.initial
    configuration.mode = .separate

    model.configureVisualizer(configuration, for: visualizerID)

    #expect(model.edges.count == 2)
    #expect(model.node(id: sourceID)?.value.channelPresentation == .separate(channelCount: 2))
    #expect(
      model.node(id: visualizerID)?.value.visualizerConfiguration?.availableChannelCount == 48
    )
    #expect(
      model.node(id: visualizerID)?.value.visualizerConfiguration?.channelSelection
        == .preset(.stereo)
    )
    #expect(model.captureSourceNodeIDs == [sourceID])
  }

  @MainActor
  private func makeDragIntent(
    model: RoutingWorkspaceModel,
    nodeID: UUID,
    translation: CGSize
  ) throws -> FlowingGraphCanvasNodeDragIntent<RoutingCanvasSchema> {
    let content = try #require(model.canvasContent)
    let elementID = try #require(model.elementID(for: nodeID))
    return FlowingGraphCanvasNodeDragIntent(
      nodeID: elementID,
      basePresentationSnapshotID: content.presentation.snapshotID,
      baseLayoutInputID: content.id,
      translation: translation
    )
  }

  @MainActor
  private func connectAggregate(
    sourceID: UUID,
    targetID: UUID,
    model: RoutingWorkspaceModel
  ) throws {
    let content = try #require(model.canvasContent)
    let source = try #require(
      content.presentation.ports.first {
        guard case .port(let key) = $0.address.elementID else { return false }
        return key.nodeID == sourceID && $0.value.audioChannel == .all
      }
    )
    let target = try #require(
      content.presentation.ports.first {
        guard case .port(let key) = $0.address.elementID else { return false }
        return key.nodeID == targetID && $0.value.audioChannel == .all
      }
    )
    model.send(
      .connectionCompleted(
        FlowingGraphCanvasConnectionCompletionIntent(
          operation: .create(sourcePortID: source.id, targetPortID: target.id),
          basePresentationSnapshotID: content.presentation.snapshotID,
          baseLayoutInputID: content.id
        )
      )
    )
  }

  @MainActor
  private func connectChannel(
    sourceID: UUID,
    sourceChannel: Int,
    targetID: UUID,
    targetChannel: Int,
    model: RoutingWorkspaceModel
  ) throws {
    let content = try #require(model.canvasContent)
    let source = try #require(
      content.presentation.ports.first {
        guard case .port(let key) = $0.address.elementID else { return false }
        return key.nodeID == sourceID
          && $0.value.direction == .output
          && $0.value.audioChannel == .channel(sourceChannel)
      }
    )
    let target = try #require(
      content.presentation.ports.first {
        guard case .port(let key) = $0.address.elementID else { return false }
        return key.nodeID == targetID
          && $0.value.direction == .input
          && $0.value.audioChannel == .channel(targetChannel)
      }
    )
    model.send(
      .connectionCompleted(
        FlowingGraphCanvasConnectionCompletionIntent(
          operation: .create(sourcePortID: source.id, targetPortID: target.id),
          basePresentationSnapshotID: content.presentation.snapshotID,
          baseLayoutInputID: content.id
        )
      )
    )
  }

  private func captureFormat(channelCount: Int) throws -> ProcessOutputCaptureFormat {
    let processID = try #require(AudioProcessID(rawValue: 42))
    let channelIDs = try (0..<channelCount).map { index in
      AudioChannelID(
        ownerID: .source(.processOutput(processID)),
        index: try #require(AudioChannelIndex(rawValue: index))
      )
    }
    return ProcessOutputCaptureFormat(
      processID: processID,
      sampleRate: 48_000,
      channelIDs: channelIDs
    )
  }

  private func inputCaptureFormat(
    deviceID: AudioDeviceID,
    channelCount: Int
  ) throws -> DeviceInputCaptureFormat {
    let channelIDs = try (0..<channelCount).map { index in
      AudioChannelID(
        ownerID: .source(.deviceInput(deviceID)),
        index: try #require(AudioChannelIndex(rawValue: index))
      )
    }
    return DeviceInputCaptureFormat(
      deviceID: deviceID,
      sampleRate: 48_000,
      channelIDs: channelIDs
    )
  }

  private func makeSelection(
    name: String,
    identifier: String
  ) -> RoutingApplicationSelection {
    RoutingApplicationSelection(
      stableID: identifier,
      applicationURL: URL(fileURLWithPath: "/Applications/\(name).app"),
      bundleIdentifier: identifier,
      displayName: name
    )
  }
}
