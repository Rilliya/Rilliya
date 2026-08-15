import CoreGraphics
import FlowingDayGraphCanvas
import Foundation
import Observation

@MainActor
@Observable
final class RoutingWorkspaceModel {
  private(set) var nodes: [RoutingWorkspaceNode] = []
  private(set) var canvasContent: RoutingCanvasContent?
  private(set) var accessibilitySnapshot: RoutingCanvasAccessibilitySnapshot?
  private(set) var buildFailureDescription: String?

  init() {
    rebuildCanvas()
  }

  @discardableResult
  func addApplicationAudioNode(
    centeredAt worldPoint: CGPoint,
    id: UUID = UUID()
  ) -> UUID {
    precondition(worldPoint.x.isFinite && worldPoint.y.isFinite)
    precondition(!nodes.contains { $0.id == id })
    let size = RoutingCanvasMetrics.nodeSize
    nodes.append(
      RoutingWorkspaceNode(
        id: id,
        value: .applicationAudio(selection: nil),
        frame: CGRect(
          x: worldPoint.x - size.width / 2,
          y: worldPoint.y - size.height / 2,
          width: size.width,
          height: size.height
        )
      )
    )
    rebuildCanvas()
    return id
  }

  func selectApplication(
    _ selection: RoutingApplicationSelection?,
    for nodeID: UUID
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
    guard case .applicationAudio = nodes[index].value else { return }
    nodes[index].value = .applicationAudio(selection: selection)
    rebuildCanvas()
  }

  func node(id: UUID) -> RoutingWorkspaceNode? {
    nodes.first { $0.id == id }
  }

  func elementID(for nodeID: UUID) -> RoutingCanvasElementID? {
    canvasContent?.presentation.nodes.first { presentationNode in
      guard case .node(let presentedNodeID) = presentationNode.address.elementID else {
        return false
      }
      return presentedNodeID == nodeID
    }?.id
  }

  func send(_ intent: FlowingGraphCanvasInteractionIntent<RoutingCanvasSchema>) {
    switch intent {
    case .nodeDragCompleted(let drag):
      apply(drag)
    case .nodeResizeCompleted,
      .nodeArrangementRequested,
      .connectionCompleted,
      .connectionCancelled,
      .elementAction:
      break
    }
  }

  private func apply(_ drag: FlowingGraphCanvasNodeDragIntent<RoutingCanvasSchema>) {
    guard let canvasContent,
      drag.basePresentationSnapshotID == canvasContent.presentation.snapshotID,
      drag.baseLayoutInputID == canvasContent.id
    else {
      return
    }
    let nodeIDs = drag.nodeIDs.compactMap(workspaceNodeID)
    guard nodeIDs.count == drag.nodeIDs.count else { return }
    let indices = nodeIDs.compactMap { nodeID in
      nodes.firstIndex { $0.id == nodeID }
    }
    guard indices.count == nodeIDs.count else { return }

    for index in indices {
      nodes[index].frame = nodes[index].frame.offsetBy(
        dx: drag.translation.width,
        dy: drag.translation.height
      )
    }
    rebuildCanvas()
  }

  private func workspaceNodeID(for elementID: RoutingCanvasElementID) -> UUID? {
    guard
      let presentationNode = canvasContent?.presentation.nodes.first(where: {
        $0.id == elementID
      }),
      case .node(let nodeID) = presentationNode.address.elementID
    else {
      return nil
    }
    return nodeID
  }

  private func rebuildCanvas() {
    do {
      let build = try RoutingCanvasContentBuilder.build(nodes: nodes)
      canvasContent = build.content
      accessibilitySnapshot = build.accessibilitySnapshot
      buildFailureDescription = nil
    } catch {
      buildFailureDescription = String(describing: error)
    }
  }
}
