import FlowingDayGraphCanvas
import FlowingDayGraphComposition
import FlowingDayGraphCore
import FlowingDayGraphLayout
import Foundation

struct RoutingCanvasBuild {
  let content: RoutingCanvasContent
  let accessibilitySnapshot: RoutingCanvasAccessibilitySnapshot
}

enum RoutingCanvasContentBuilder {
  @MainActor
  static func build(nodes: [RoutingWorkspaceNode]) throws -> RoutingCanvasBuild {
    var graph = FlowingGraph<RoutingGraphSchema>()
    let update = graph.update { transaction in
      for node in nodes {
        transaction.insert(FlowingGraphNode(id: node.id, value: node.value))
      }
    }
    guard case .committed = update else {
      throw RoutingCanvasBuildIssue.graphMutationRejected
    }

    let document = FlowingGraphDocument<RoutingCanvasSchema>(
      id: "workspace",
      defaultEntryPointID: "main",
      entryPoints: [
        FlowingGraphEntryPoint(id: "main", name: "Audio Routing", graphID: "main")
      ],
      definitions: [FlowingGraphDefinition(id: "main", graph: graph)],
      subgraphLinks: []
    )
    let presentation = try FlowingGraphProjector(document: document).projectDefault()
    let topology = try FlowingGraphCanvasLayoutAdapter.topology(for: presentation)
    let input = try FlowingGraphLayoutResolution.input(
      topology: topology,
      nodeSizeResolver: FlowingFixedNodeSizeResolver<
        FlowingGraphCanvasLayoutSchema<RoutingCanvasSchema>
      >(size: RoutingCanvasMetrics.nodeSize),
      portAnchorResolver: FlowingCenteredPortAnchorResolver<
        FlowingGraphCanvasLayoutSchema<RoutingCanvasSchema>
      >(),
      pipelineIdentity: FlowingLayoutPipelineIdentity(
        component: FlowingLayoutComponentIdentity()
      )
    )
    let frameByNodeID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.frame) })
    let nodeFrames: [FlowingGraphNodeFrame<FlowingGraphCanvasLayoutSchema<RoutingCanvasSchema>>] =
      try presentation.nodes.map { node in
        guard case .node(let nodeID) = node.address.elementID,
          let frame = frameByNodeID[nodeID]
        else {
          throw RoutingCanvasBuildIssue.unmappedPresentationNode
        }
        return FlowingGraphNodeFrame<FlowingGraphCanvasLayoutSchema<RoutingCanvasSchema>>(
          nodeID: node.localID,
          frame: frame
        )
      }
    let placement = try FlowingGraphNodePlacement(
      input: input,
      nodeFrames: nodeFrames,
      contentBounds: RoutingCanvasMetrics.contentBounds
    )
    let layoutResult = try FlowingGraphLayoutResult(
      input: input,
      placement: placement,
      edgeRoutes: []
    )
    let content = try RoutingCanvasContent(
      presentation: presentation,
      layoutInput: input,
      layoutResult: layoutResult
    )
    let accessibilitySnapshot = try content.accessibilitySnapshot(
      canvasDescription: FlowingGraphCanvasAccessibilityDescription(
        label: "Audio routing canvas",
        hint: "Add and arrange audio routing nodes."
      ),
      node: accessibilityRepresentation,
      port: { _ -> FlowingGraphCanvasAccessibilityRepresentation in .hidden },
      edge: { _ -> FlowingGraphCanvasAccessibilityRepresentation in .hidden }
    )
    return RoutingCanvasBuild(
      content: content,
      accessibilitySnapshot: accessibilitySnapshot
    )
  }

  private static func accessibilityRepresentation(
    for node: FlowingGraphPresentationNode<RoutingCanvasSchema>
  ) -> FlowingGraphCanvasAccessibilityRepresentation {
    let selectedApplication = node.value.applicationSelection
    let value = selectedApplication?.displayName ?? "No application selected"
    let identifier: String?
    if case .node(let nodeID) = node.address.elementID {
      identifier = "routing-node-\(nodeID.uuidString.lowercased())"
    } else {
      identifier = nil
    }
    return .element(
      FlowingGraphCanvasAccessibilityDescription(
        label: "Application Audio",
        value: value,
        hint: "Select an installed application whose audio will be routed.",
        roleDescription: "audio routing node",
        identifier: identifier
      )
    )
  }
}

private enum RoutingCanvasBuildIssue: Error {
  case graphMutationRejected
  case unmappedPresentationNode
}
