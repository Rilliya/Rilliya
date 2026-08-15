import CoreGraphics
import FlowingDayGraphCanvas
import Foundation
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
    let secondPoint = RoutingNodeInsertion.point(
      in: visibleWorldRect,
      existingNodeCount: 1
    )

    #expect(firstPoint == CGPoint(x: 1_650, y: -380))
    #expect(secondPoint == CGPoint(x: 1_678, y: -352))
  }

  @Test @MainActor
  func dropCreatesCenteredApplicationAudioPlaceholder() throws {
    let model = RoutingWorkspaceModel()
    let dropPoint = CGPoint(x: 320, y: 240)

    let nodeID = model.addApplicationAudioNode(centeredAt: dropPoint)

    let node = try #require(model.node(id: nodeID))
    #expect(node.frame.size == RoutingCanvasMetrics.nodeSize)
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
