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
  func selectingApplicationUpdatesOnlyRequestedNode() throws {
    let model = RoutingWorkspaceModel()
    let firstID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))
    let secondID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 500, y: 300))
    let selection = makeSelection(name: "Player", identifier: "com.example.player")

    model.selectApplication(selection, for: firstID)

    #expect(model.node(id: firstID)?.value.applicationSelection == selection)
    #expect(model.node(id: secondID)?.value.applicationSelection == nil)
    #expect(model.nodes.count == 2)
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

    #expect(ports.count == 2)
    #expect(ports.contains { $0.value.direction == .output && $0.value.audioChannel == .all })
    #expect(ports.contains { $0.value.direction == .input && $0.value.audioChannel == .all })
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

    #expect(outputChannels.sorted() == [0, 1, 2])
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
  func largeRuntimeFormatIsNeverSilentlyTruncatedIntoAutomaticLanes() throws {
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

    #expect(model.edges.isEmpty)
    #expect(model.node(id: sourceID)?.value.channelPresentation == .aggregate)
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
