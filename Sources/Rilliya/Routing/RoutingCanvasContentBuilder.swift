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
  static func build(
    workspaceID: UUID,
    nodes: [RoutingWorkspaceNode],
    edges: [RoutingWorkspaceEdge]
  ) throws -> RoutingCanvasBuild {
    var graph = FlowingGraph<RoutingGraphSchema>()
    var portPlacements: [RoutingWorkspacePortAddress: RoutingPortPlacement] = [:]
    let portValues = Dictionary(
      uniqueKeysWithValues: nodes.flatMap { node in
        RoutingGraphPorts.values(for: node).map { value in
          (
            RoutingWorkspacePortAddress(nodeID: node.id, portID: value.id),
            value
          )
        }
      }
    )
    let update = graph.update { transaction in
      for node in nodes {
        transaction.insert(FlowingGraphNode(id: node.id, value: node.value))
        let ports = RoutingGraphPorts.values(for: node)
        for value in ports {
          let portID = RoutingGraphPorts.portID(for: value)
          transaction.insert(
            FlowingGraphPort(
              key: FlowingGraphPortKey(
                nodeID: node.id,
                portID: portID
              ),
              value: value
            )
          )
          portPlacements[
            RoutingWorkspacePortAddress(nodeID: node.id, portID: portID)
          ] = RoutingPortPlacement(
            ordinal: value.ordinal,
            total: value.total,
            verticalOffset: verticalOffset(for: value, in: node)
          )
        }
      }
      for edge in edges {
        guard let sourceValue = portValues[edge.source] else { continue }
        transaction.insert(
          FlowingGraphEdge(
            id: edge.id,
            endpoints: .directed(
              source: .port(
                FlowingGraphPortKey(
                  nodeID: edge.source.nodeID,
                  portID: edge.source.portID
                )
              ),
              target: .port(
                FlowingGraphPortKey(
                  nodeID: edge.target.nodeID,
                  portID: edge.target.portID
                )
              )
            ),
            value: RoutingGraphEdgeValue(
              signalType: sourceValue.signalType,
              isEnabled: edge.isEnabled,
              isActive: edge.isEnabled
                && sourceValue.isEnabled
                && portValues[edge.target]?.isEnabled == true
            )
          )
        )
      }
    }
    guard case .committed = update else {
      throw RoutingCanvasBuildIssue.graphMutationRejected
    }

    let document = FlowingGraphDocument<RoutingCanvasSchema>(
      id: workspaceID.uuidString.lowercased(),
      defaultEntryPointID: "main",
      entryPoints: [
        FlowingGraphEntryPoint(id: "main", name: "Audio Routing", graphID: "main")
      ],
      definitions: [FlowingGraphDefinition(id: "main", graph: graph)],
      subgraphLinks: []
    )
    let presentation = try FlowingGraphProjector(document: document).projectDefault()
    let frameByNodeID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.frame) })
    let sizeByLocalNodeID = Dictionary(
      uniqueKeysWithValues: try presentation.nodes.map { node in
        guard case .node(let nodeID) = node.address.elementID,
          let frame = frameByNodeID[nodeID]
        else {
          throw RoutingCanvasBuildIssue.unmappedPresentationNode
        }
        return (node.localID, frame.size)
      }
    )
    let topology = try FlowingGraphCanvasLayoutAdapter.topology(for: presentation)
    let input = try FlowingGraphLayoutResolution.input(
      topology: topology,
      nodeSizeResolver: RoutingNodeSizeResolver(sizes: sizeByLocalNodeID),
      portAnchorResolver: RoutingPortAnchorResolver(placements: portPlacements),
      pipelineIdentity: FlowingLayoutPipelineIdentity(
        component: FlowingLayoutComponentIdentity()
      )
    )
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
    let edgeRoutes = try FlowingCubicEdgeRouter<
      FlowingGraphCanvasLayoutSchema<RoutingCanvasSchema>
    >().routes(for: input, placement: placement)
    let layoutResult = try FlowingGraphLayoutResult(
      input: input,
      placement: placement,
      edgeRoutes: edgeRoutes
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
      port: { port in
        .element(
          FlowingGraphCanvasAccessibilityDescription(
            label: port.value.isEnabled ? port.value.label : "\(port.value.label), disabled",
            hint: port.value.isEnabled
              ? "Drag to connect this port."
              : "Use the context menu to enable this port.",
            roleDescription: "routing port"
          )
        )
      },
      edge: { _ -> FlowingGraphCanvasAccessibilityRepresentation in .hidden }
    )
    return RoutingCanvasBuild(
      content: content,
      accessibilitySnapshot: accessibilitySnapshot
    )
  }

  private static func verticalOffset(
    for value: RoutingGraphPortValue,
    in node: RoutingWorkspaceNode
  ) -> CGFloat? {
    let localFrame = CGRect(origin: .zero, size: node.frame.size)
    switch node.value {
    case .applicationAudio(_, .separate(let channelCount)),
      .inputAudio(_, .separate(let channelCount)),
      .outputAudio(_, .separate(let channelCount)):
      let rowFrames = RoutingAudioSourceLayout.rowFrames(
        in: localFrame,
        channelCount: channelCount
      )
      guard rowFrames.indices.contains(value.ordinal) else { return nil }
      return rowFrames[value.ordinal].midY
    case .visualizer(let configuration):
      if value.direction == .output, value.audioChannel == .all,
        let centerY = RoutingVisualizerLayout.mixedOutputCenterY(
          in: localFrame,
          configuration: configuration
        )
      {
        return centerY
      }
      let laneFrames = RoutingVisualizerLayout.laneFrames(
        in: localFrame,
        configuration: configuration
      )
      guard case .some(.channel(let channelIndex)) = value.audioChannel,
        let laneIndex = configuration.normalizedSelectedChannels.firstIndex(of: channelIndex),
        laneFrames.indices.contains(laneIndex)
      else {
        return nil
      }
      return laneFrames[laneIndex].midY
    case .audioMixer(let configuration):
      let rowFrames = RoutingAudioMixerLayout.rowFrames(
        in: localFrame,
        channelCount: configuration.channelCount
      )
      guard rowFrames.indices.contains(value.ordinal) else { return nil }
      return rowFrames[value.ordinal].midY
    case .applicationAudio, .inputAudio, .outputAudio, .peakLevel, .signalGenerator, .delay:
      return nil
    }
  }

  private static func accessibilityRepresentation(
    for node: FlowingGraphPresentationNode<RoutingCanvasSchema>
  ) -> FlowingGraphCanvasAccessibilityRepresentation {
    let value: String
    let hint: String
    switch node.value {
    case .applicationAudio(let selection, _):
      value = selection?.displayName ?? "No application selected"
      hint = "Select an installed application whose audio will be routed."
    case .inputAudio(let selection, _):
      value = selection?.displayName ?? "No input device selected"
      hint = "Select an audio input device whose channels will be routed."
    case .outputAudio(let selection, _):
      value = selection?.displayName ?? "No output device selected"
      hint = "Select an audio output device that will receive routed channels."
    case .visualizer(let configuration):
      value =
        configuration.mode == .mixed
        ? "Mixed waveform"
        : "\(configuration.normalizedSelectedChannels.count) selected channels"
      hint = "Select to configure the routed channels shown by this visualizer."
    case .audioMixer(let configuration):
      value = "\(configuration.channelCount)-channel mixer"
      hint = "Connect audio inputs and adjust each output channel level."
    case .peakLevel:
      value = "Maximum linear full-scale sample"
      hint = "Connect one audio output to measure its current peak level."
    case .signalGenerator(let configuration):
      value = "\(configuration.waveform.displayName), \(Int(configuration.frequency)) hertz"
      hint = "Connect this generated mono signal to an audio destination."
    case .delay(let configuration):
      value = "\(Int((configuration.delaySeconds * 1_000).rounded())) milliseconds"
      hint = "Connect audio through this node to add a realtime delay."
    }
    let identifier: String?
    if case .node(let nodeID) = node.address.elementID {
      identifier = "routing-node-\(nodeID.uuidString.lowercased())"
    } else {
      identifier = nil
    }
    return .element(
      FlowingGraphCanvasAccessibilityDescription(
        label: node.value.title,
        value: value,
        hint: hint,
        roleDescription: "audio routing node",
        identifier: identifier
      )
    )
  }
}

private struct RoutingNodeSizeResolver: FlowingGraphNodeSizeResolver {
  typealias Schema = FlowingGraphCanvasLayoutSchema<RoutingCanvasSchema>
  typealias NodeID = FlowingGraphPresentationLocalElementID<RoutingCanvasSchema>

  let identity = FlowingLayoutComponentIdentity()
  let sizes: [NodeID: CGSize]

  func size(for nodeID: NodeID) throws -> CGSize {
    sizes[nodeID] ?? RoutingCanvasMetrics.baseNodeSize
  }
}

private struct RoutingPortPlacement: Sendable {
  let ordinal: Int
  let total: Int
  let verticalOffset: CGFloat?
}

private struct RoutingPortAnchorResolver: FlowingGraphPortAnchorResolver {
  typealias Schema = FlowingGraphCanvasLayoutSchema<RoutingCanvasSchema>

  let identity = FlowingLayoutComponentIdentity()
  let placements: [RoutingWorkspacePortAddress: RoutingPortPlacement]

  func anchor(
    for port: FlowingGraphLayoutPort<Schema>,
    nodeSize: CGSize
  ) throws -> FlowingGraphPortAnchor<Schema> {
    guard case .source(_, .port(let key), _) = port.id else {
      return FlowingGraphPortAnchor(
        key: port.key,
        position: CGPoint(x: nodeSize.width / 2, y: nodeSize.height / 2),
        normal: .zero
      )
    }
    let id = key.portID
    let placement =
      placements[
        RoutingWorkspacePortAddress(nodeID: key.nodeID, portID: key.portID)
      ] ?? RoutingPortPlacement(ordinal: 0, total: 1, verticalOffset: nil)
    let verticalPosition =
      placement.verticalOffset
      ?? nodeSize.height * CGFloat(placement.ordinal + 1) / CGFloat(placement.total + 1)
    let isInput = id.direction == .input
    return FlowingGraphPortAnchor(
      key: port.key,
      position: CGPoint(x: isInput ? 0 : nodeSize.width, y: verticalPosition),
      normal: CGVector(dx: isInput ? -1 : 1, dy: 0)
    )
  }
}

private enum RoutingCanvasBuildIssue: Error {
  case graphMutationRejected
  case unmappedPresentationNode
}
