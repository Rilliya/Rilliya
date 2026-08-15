import CoreGraphics
import FlowingDayGraphCanvas
import Foundation
import Observation

@MainActor
@Observable
final class RoutingWorkspaceModel {
  let id: UUID

  private(set) var nodes: [RoutingWorkspaceNode] = []
  private(set) var edges: [RoutingWorkspaceEdge] = []
  private(set) var canvasContent: RoutingCanvasContent?
  private(set) var accessibilitySnapshot: RoutingCanvasAccessibilitySnapshot?
  private(set) var buildFailureDescription: String?

  init(id: UUID = UUID()) {
    self.id = id
    rebuildCanvas()
  }

  @discardableResult
  func addApplicationAudioNode(
    centeredAt worldPoint: CGPoint,
    id: UUID = UUID()
  ) -> UUID {
    precondition(worldPoint.x.isFinite && worldPoint.y.isFinite)
    precondition(!nodes.contains { $0.id == id })
    let value = RoutingNodeValue.applicationAudio(
      selection: nil,
      channelPresentation: .aggregate
    )
    let size = RoutingCanvasMetrics.nodeSize(for: value)
    nodes.append(
      RoutingWorkspaceNode(
        id: id,
        value: value,
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

  @discardableResult
  func addVisualizerNode(
    centeredAt worldPoint: CGPoint,
    id: UUID = UUID()
  ) -> UUID {
    precondition(worldPoint.x.isFinite && worldPoint.y.isFinite)
    precondition(!nodes.contains { $0.id == id })
    let value = RoutingNodeValue.visualizer(configuration: .initial)
    let size = RoutingCanvasMetrics.nodeSize(for: value)
    nodes.append(
      RoutingWorkspaceNode(
        id: id,
        value: value,
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
    guard case .applicationAudio(_, let channelPresentation) = nodes[index].value else { return }
    nodes[index].value = .applicationAudio(
      selection: selection,
      channelPresentation: channelPresentation
    )
    rebuildCanvas()
  }

  func setApplicationChannelPresentation(
    _ presentation: RoutingChannelPresentation,
    for nodeID: UUID
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }),
      case .applicationAudio(let selection, _) = nodes[index].value
    else {
      return
    }
    let normalized: RoutingChannelPresentation
    switch presentation {
    case .aggregate:
      normalized = .aggregate
    case .separate(let channelCount):
      normalized = .separate(channelCount: max(1, min(32, channelCount)))
    }
    nodes[index].value = .applicationAudio(
      selection: selection,
      channelPresentation: normalized
    )
    resizeNode(at: index)
    rebuildCanvas()
  }

  func configureVisualizer(
    _ configuration: RoutingVisualizerConfiguration,
    for nodeID: UUID
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }),
      case .visualizer = nodes[index].value
    else {
      return
    }
    var normalized = configuration
    normalized.availableChannelCount = max(1, min(32, configuration.availableChannelCount))
    normalized.selectedChannels = Set(normalized.normalizedSelectedChannels)
    if normalized.selectedChannels.isEmpty {
      normalized.selectedChannels = [0]
    }
    nodes[index].value = .visualizer(configuration: normalized)
    resizeNode(at: index)
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

  func sourceNodeIDs(feeding nodeID: UUID) -> [UUID] {
    var seen = Set<UUID>()
    return
      edges
      .filter { $0.target.nodeID == nodeID }
      .map(\.source.nodeID)
      .filter { seen.insert($0).inserted }
  }

  func incomingEdges(for nodeID: UUID) -> [RoutingWorkspaceEdge] {
    edges.filter { $0.target.nodeID == nodeID }
  }

  func send(_ intent: FlowingGraphCanvasInteractionIntent<RoutingCanvasSchema>) {
    switch intent {
    case .nodeDragCompleted(let drag):
      apply(drag)
    case .connectionCompleted(let connection):
      apply(connection)
    case .nodeResizeCompleted,
      .nodeArrangementRequested,
      .connectionCancelled,
      .elementAction:
      break
    }
  }

  func canBeginConnection(
    _ origin: FlowingGraphCanvasConnectionOrigin<RoutingCanvasSchema>
  ) -> Bool {
    portAddress(for: origin.fixedElementID)?.portID.direction == .output
  }

  func validateConnection(
    _ request: FlowingGraphCanvasConnectionValidationRequest<RoutingCanvasSchema>
  ) -> FlowingGraphCanvasConnectionValidation {
    guard request.basePresentationSnapshotID == canvasContent?.presentation.snapshotID,
      request.baseLayoutInputID == canvasContent?.id,
      let source = portAddress(for: request.origin.fixedElementID),
      let target = portAddress(for: request.targetPortID),
      source.nodeID != target.nodeID,
      source.portID.direction == .output,
      target.portID.direction == .input
    else {
      return .invalid(.init(message: "Connect an output to an input on another node"))
    }
    return connectionValidation(source: source, target: target)
  }

  private func connectionValidation(
    source: RoutingWorkspacePortAddress,
    target: RoutingWorkspacePortAddress
  ) -> FlowingGraphCanvasConnectionValidation {
    guard let sourceValue = portValue(at: source),
      let targetValue = portValue(at: target)
    else {
      return .invalid(.init(message: "The selected port is no longer available"))
    }
    if let reason = RoutingPortCompatibility.incompatibilityReason(
      source: sourceValue,
      target: targetValue
    ) {
      return .invalid(.init(message: reason))
    }
    return .valid
  }

  private func portValue(
    at address: RoutingWorkspacePortAddress
  ) -> RoutingGraphPortValue? {
    guard let node = node(id: address.nodeID) else { return nil }
    return RoutingGraphPorts.values(for: node).first { $0.id == address.portID }
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

  private func apply(
    _ connection: FlowingGraphCanvasConnectionCompletionIntent<RoutingCanvasSchema>
  ) {
    guard connection.basePresentationSnapshotID == canvasContent?.presentation.snapshotID,
      connection.baseLayoutInputID == canvasContent?.id
    else {
      return
    }
    guard case .create(let sourceElementID, let targetElementID) = connection.operation,
      let source = portAddress(for: sourceElementID),
      let target = portAddress(for: targetElementID),
      source.portID.direction == .output,
      target.portID.direction == .input,
      source.nodeID != target.nodeID,
      case .valid = connectionValidation(source: source, target: target)
    else {
      return
    }
    guard !edges.contains(where: { $0.source == source && $0.target == target }) else { return }
    edges.append(RoutingWorkspaceEdge(id: UUID(), source: source, target: target))
    rebuildCanvas()
  }

  private func portAddress(
    for elementID: RoutingCanvasElementID
  ) -> RoutingWorkspacePortAddress? {
    guard case .source(let address, _) = elementID,
      case .port(let key) = address.elementID
    else {
      return nil
    }
    return RoutingWorkspacePortAddress(nodeID: key.nodeID, portID: key.portID)
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
      pruneEdgesWithMissingPorts()
      let build = try RoutingCanvasContentBuilder.build(
        workspaceID: id,
        nodes: nodes,
        edges: edges
      )
      canvasContent = build.content
      accessibilitySnapshot = build.accessibilitySnapshot
      buildFailureDescription = nil
    } catch {
      buildFailureDescription = String(describing: error)
    }
  }

  private func pruneEdgesWithMissingPorts() {
    let availablePorts = Dictionary(
      uniqueKeysWithValues: nodes.flatMap { node in
        let values = RoutingGraphPorts.values(for: node)
        return values.map { value in
          (
            RoutingWorkspacePortAddress(
              nodeID: node.id,
              portID: RoutingGraphPorts.portID(for: value)
            ),
            value
          )
        }
      }
    )
    edges.removeAll { edge in
      guard let source = availablePorts[edge.source],
        let target = availablePorts[edge.target]
      else {
        return true
      }
      return RoutingPortCompatibility.incompatibilityReason(
        source: source,
        target: target
      ) != nil
    }
  }

  private func resizeNode(at index: Int) {
    let size = RoutingCanvasMetrics.nodeSize(for: nodes[index].value)
    guard nodes[index].frame.size != size else { return }
    let center = CGPoint(x: nodes[index].frame.midX, y: nodes[index].frame.midY)
    nodes[index].frame = CGRect(
      x: center.x - size.width / 2,
      y: center.y - size.height / 2,
      width: size.width,
      height: size.height
    )
  }
}
