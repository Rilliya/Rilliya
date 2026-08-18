import FlowingDayGraphCanvas
import FlowingDayGraphComposition
import FlowingDayGraphCore
import FlowingDayGraphLayout
import Foundation

struct RoutingCanvasBuild {
  let content: RoutingCanvasContent
  let accessibilitySnapshot: RoutingCanvasAccessibilitySnapshot
}

private struct RoutingCanvasPreparedBuild: Sendable {
  let presentation: FlowingGraphPresentation<RoutingCanvasSchema>
  let layoutInput:
    FlowingGraphLayoutInput<
      FlowingGraphCanvasLayoutSchema<RoutingCanvasSchema>
    >
  let layoutResult:
    FlowingGraphLayoutResult<
      FlowingGraphCanvasLayoutSchema<RoutingCanvasSchema>
    >
}

// FlowingGraphCanvasContent is an immutable value whose presentation, layout, and render-index
// members are Sendable for RoutingCanvasSchema. FlowingDayUI does not currently expose that
// conditional conformance, so this narrow box carries a fully initialized content value back to
// the main actor without making the shared UI package part of this optimization.
private struct RoutingCanvasPreparedContent: @unchecked Sendable {
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
    finishForPublication(
      try makeContent(from: prepare(workspaceID: workspaceID, nodes: nodes, edges: edges))
    )
  }

  @MainActor
  static func buildInBackground(
    workspaceID: UUID,
    nodes: [RoutingWorkspaceNode],
    edges: [RoutingWorkspaceEdge]
  ) async throws -> RoutingCanvasBuild {
    let prepared = try await Task.detached(priority: .userInitiated) {
      try makeContent(
        from: prepare(workspaceID: workspaceID, nodes: nodes, edges: edges)
      )
    }.value
    return finishForPublication(prepared)
  }

  private static func prepare(
    workspaceID: UUID,
    nodes: [RoutingWorkspaceNode],
    edges: [RoutingWorkspaceEdge]
  ) throws -> RoutingCanvasPreparedBuild {
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
    return RoutingCanvasPreparedBuild(
      presentation: presentation,
      layoutInput: input,
      layoutResult: layoutResult
    )
  }

  private static func makeContent(
    from prepared: RoutingCanvasPreparedBuild
  ) throws -> RoutingCanvasPreparedContent {
    let content = try RoutingCanvasContent(
      presentation: prepared.presentation,
      layoutInput: prepared.layoutInput,
      layoutResult: prepared.layoutResult
    )
    return RoutingCanvasPreparedContent(
      content: content,
      accessibilitySnapshot: try makeAccessibilitySnapshot(for: content)
    )
  }

  @MainActor
  private static func finishForPublication(
    _ prepared: RoutingCanvasPreparedContent
  ) -> RoutingCanvasBuild {
    RoutingCanvasBuild(
      content: prepared.content,
      accessibilitySnapshot: prepared.accessibilitySnapshot
    )
  }

  private static func makeAccessibilitySnapshot(
    for content: RoutingCanvasContent
  ) throws -> RoutingCanvasAccessibilitySnapshot {
    var relatedElementIDs: [RoutingCanvasElementID: [RoutingCanvasElementID]] = [:]
    for edge in content.presentation.edges {
      let endpointIDs: [RoutingCanvasElementID] =
        switch edge.endpoints {
        case .directed(let source, let target):
          [elementID(for: source), elementID(for: target)]
        case .undirected(let first, let second):
          [elementID(for: first), elementID(for: second)]
        }
      relatedElementIDs[edge.id] = endpointIDs
      for endpointID in endpointIDs {
        relatedElementIDs[endpointID, default: []].append(edge.id)
      }
    }
    let nodeElementIDByWorkspaceID: [UUID: RoutingCanvasElementID] = Dictionary(
      uniqueKeysWithValues: content.presentation.nodes.compactMap { node in
        guard case .node(let nodeID) = node.address.elementID else { return nil }
        return (nodeID, node.id)
      }
    )
    for port in content.presentation.ports {
      guard case .port(let key) = port.address.elementID,
        let nodeID = nodeElementIDByWorkspaceID[key.nodeID]
      else { continue }
      relatedElementIDs[port.id, default: []].append(nodeID)
      relatedElementIDs[nodeID, default: []].append(port.id)
    }

    var items: [FlowingGraphCanvasAccessibilityItem<RoutingCanvasElementID>] = []
    items.reserveCapacity(content.presentation.nodes.count + content.presentation.ports.count)
    for node in content.presentation.nodes {
      guard case .element(let description) = accessibilityRepresentation(for: node),
        let frame = content.frame(for: node.localID)
      else { continue }
      items.append(
        FlowingGraphCanvasAccessibilityItem(
          id: node.id,
          kind: .node,
          frame: frame,
          description: description,
          relatedElementIDs: relatedElementIDs[node.id] ?? []
        )
      )
    }
    for port in content.presentation.ports {
      guard let anchor = content.anchor(for: port.localID) else { continue }
      items.append(
        FlowingGraphCanvasAccessibilityItem(
          id: port.id,
          kind: .port,
          frame: CGRect(
            x: anchor.position.x - 0.5, y: anchor.position.y - 0.5, width: 1, height: 1),
          description: FlowingGraphCanvasAccessibilityDescription(
            label: port.value.isEnabled ? port.value.label : "\(port.value.label), disabled",
            hint: port.value.isEnabled
              ? "Drag to connect this port."
              : "Use the context menu to enable this port.",
            roleDescription: "routing port"
          ),
          relatedElementIDs: relatedElementIDs[port.id] ?? []
        )
      )
    }
    return try RoutingCanvasAccessibilitySnapshot(
      canvasDescription: FlowingGraphCanvasAccessibilityDescription(
        label: "Audio routing canvas",
        hint: "Add and arrange audio routing nodes."
      ),
      items: items,
      relationships: relatedElementIDs
    )
  }

  private static func elementID(
    for endpoint: FlowingGraphPresentationEndpoint<RoutingCanvasSchema>
  ) -> RoutingCanvasElementID {
    switch endpoint {
    case .node(let id), .port(let id):
      id
    }
  }

  private static func verticalOffset(
    for value: RoutingGraphPortValue,
    in node: RoutingWorkspaceNode
  ) -> CGFloat? {
    let localFrame = CGRect(origin: .zero, size: node.frame.size)
    switch node.value {
    case .applicationAudio(_, .separate(let channelCount)),
      .inputAudio(_, .separate(let channelCount)),
      .systemOutput(_, .separate(let channelCount)),
      .virtualOutput(_, .separate(let channelCount)),
      .outputAudio(_, .separate(let channelCount)),
      .virtualInput(_, .separate(let channelCount)):
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
    case .channelRouter(let configuration):
      let rowFrames = RoutingAudioMixerLayout.rowFrames(
        in: localFrame,
        channelCount: max(configuration.inputChannelCount, configuration.outputChannelCount)
      )
      guard rowFrames.indices.contains(value.ordinal) else { return nil }
      return rowFrames[value.ordinal].midY
    case .applicationAudio, .inputAudio, .systemOutput, .virtualOutput, .outputAudio,
      .virtualInput, .gain, .peakLevel, .signalGenerator, .filePlayback, .fileOutput,
      .networkSend, .networkReceive, .delay, .noiseGate, .compressor:
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
    case .systemOutput(let selection, _):
      switch selection {
      case .systemDefault:
        value = "Following the system default output"
      case .device(let device):
        value = device.displayName
      case nil:
        value = "No output source selected"
      }
      hint = "Choose the system default or a specific output device whose audio will be routed."
    case .virtualOutput(let selection, _):
      value = selection?.displayName ?? "No virtual output selected"
      hint = "Choose a shared virtual output whose audio Rilliya will receive."
    case .outputAudio(let selection, _):
      switch selection {
      case .systemDefault:
        value = "Following the system default output"
      case .device(let device):
        value = device.displayName
      case nil:
        value = "No output device selected"
      }
      hint = "Choose the system default or a specific output device for routed channels."
    case .virtualInput(let selection, _):
      value = selection?.displayName ?? "No virtual input selected"
      hint = "Choose a shared virtual input that will receive routed audio."
    case .visualizer(let configuration):
      value =
        configuration.displayMode == .mixed
        ? "Mixed waveform"
        : "\(configuration.normalizedSelectedChannels.count) selected channels"
      hint = "Select to configure the routed channels shown by this visualizer."
    case .audioMixer(let configuration):
      value = "\(configuration.channelCount)-channel mixer"
      hint = "Connect audio inputs and adjust each output channel level."
    case .gain(let configuration):
      value = configuration.isMuted ? "Muted" : configuration.gainDescription
      hint = "Connect audio through this node to adjust level or invert polarity."
    case .channelRouter(let configuration):
      value =
        "\(configuration.inputChannelCount) inputs routed to \(configuration.outputChannelCount) outputs"
      hint = "Configure which input channel feeds each output channel."
    case .peakLevel:
      value = "Maximum linear full-scale sample"
      hint = "Connect one audio output to measure its current peak level."
    case .signalGenerator(let configuration):
      value = "\(configuration.waveform.displayName), \(Int(configuration.frequency)) hertz"
      hint = "Connect this generated mono signal to an audio destination."
    case .filePlayback(let configuration):
      value = configuration.selection?.displayName ?? "No audio file selected"
      hint = "Choose a local audio file, then connect this source to an audio destination."
    case .fileOutput(let configuration):
      value = configuration.destination?.displayName ?? "No destination selected"
      hint = "Choose an audio file destination, then connect routed audio to this node."
    case .networkSend(let configuration):
      value = "\(configuration.host):\(configuration.port)"
      hint = "Connect audio to send it to one trusted local-network peer."
    case .networkReceive(let configuration):
      value = "UDP port \(configuration.port)"
      hint = "Connect this source to receive audio from one trusted local-network peer."
    case .delay(let configuration):
      value = "\(Int((configuration.delaySeconds * 1_000).rounded())) milliseconds"
      hint = "Connect audio through this node to add a realtime delay."
    case .noiseGate(let configuration):
      value = "\(Int(configuration.thresholdDecibels.rounded())) decibels full scale threshold"
      hint = "Connect audio through this node to attenuate quiet passages."
    case .compressor(let configuration):
      value =
        "\(Int(configuration.thresholdDecibels.rounded())) decibels full scale threshold, "
        + "\(configuration.ratio.formatted(.number.precision(.fractionLength(1)))) to one ratio"
      hint = "Connect audio through this node to control its dynamic range."
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
    let horizontalPosition =
      isInput
      ? RoutingCanvasMetrics.portAnchorInset
      : nodeSize.width - RoutingCanvasMetrics.portAnchorInset
    return FlowingGraphPortAnchor(
      key: port.key,
      position: CGPoint(x: horizontalPosition, y: verticalPosition),
      normal: CGVector(dx: isInput ? -1 : 1, dy: 0)
    )
  }
}

private enum RoutingCanvasBuildIssue: Error {
  case graphMutationRejected
  case unmappedPresentationNode
}
