import FlowingDayGraphCanvas
import FlowingDayGraphComposition
import FlowingDayGraphLayout
import Foundation

struct RoutingMetalNodeSupplement: Equatable {
  let isRunning: Bool
  let isCapturing: Bool
  let captureConsumerCount: Int
  let visualizerSignal: RoutingVisualizerSignal?

  static let empty = RoutingMetalNodeSupplement(
    isRunning: false,
    isCapturing: false,
    captureConsumerCount: 0,
    visualizerSignal: nil
  )
}

struct RoutingMetalScene {
  struct Node: Identifiable {
    let id: RoutingCanvasElementID
    let workspaceID: UUID
    let value: RoutingNodeValue
    let frame: CGRect
    let ports: [Port]
    let supplement: RoutingMetalNodeSupplement

    var title: String {
      switch value {
      case .applicationAudio:
        return "Application Audio"
      case .visualizer:
        return "Visualizer"
      }
    }

    var subtitle: String {
      switch value {
      case .applicationAudio(let selection, _):
        return selection?.displayName ?? "Choose an application"
      case .visualizer(let configuration):
        if configuration.mode == .mixed { return "Mixed waveform" }
        let count = configuration.normalizedSelectedChannels.count
        return "\(count) selected channel\(count == 1 ? "" : "s")"
      }
    }

    var status: String {
      switch value {
      case .applicationAudio(let selection, _):
        if supplement.isCapturing {
          if supplement.captureConsumerCount > 1 {
            return "Shared capture · \(supplement.captureConsumerCount) nodes"
          }
          return "Capturing live audio"
        }
        if supplement.isRunning { return "Ready to capture" }
        return selection == nil ? "Select to configure" : "Application is not running"
      case .visualizer:
        return supplement.visualizerSignal == nil ? "Waiting for routed audio" : "Live waveform"
      }
    }

    var applicationStatusText: String? {
      guard case .applicationAudio(let selection, _) = value else { return nil }
      return selection == nil ? "Select this node to configure" : "Application selected"
    }

    var applicationStatusSymbolName: String? {
      guard case .applicationAudio(let selection, _) = value else { return nil }
      return selection == nil ? "cursorarrow.click" : "checkmark"
    }

    var hasApplicationSelection: Bool {
      guard case .applicationAudio(let selection, _) = value else { return false }
      return selection != nil
    }

    var applicationURL: URL? {
      guard case .applicationAudio(let selection, _) = value else { return nil }
      return selection?.applicationURL
    }

    var symbolName: String {
      switch value {
      case .applicationAudio:
        return "macwindow"
      case .visualizer:
        return "waveform"
      }
    }

    var miniMapStyleIndex: Int {
      switch value {
      case .applicationAudio: 0
      case .visualizer: 1
      }
    }
  }

  struct Port: Identifiable {
    let id: RoutingCanvasElementID
    let nodeID: RoutingCanvasElementID
    let workspaceNodeID: UUID
    let value: RoutingGraphPortValue
    let position: CGPoint
  }

  struct Edge: Identifiable {
    let id: RoutingCanvasElementID
    let route: FlowingGraphEdgeRoute
  }

  let contentID: FlowingLayoutInputID
  let presentationSnapshotID: FlowingGraphPresentationSnapshotID
  let nodes: [Node]
  let edges: [Edge]
  let contentBounds: CGRect

  private let portByID: [RoutingCanvasElementID: Port]

  init(
    content: RoutingCanvasContent,
    supplements: [UUID: RoutingMetalNodeSupplement]
  ) {
    contentID = content.id
    presentationSnapshotID = content.presentation.snapshotID

    var nextNodes: [Node] = []
    nextNodes.reserveCapacity(content.presentation.nodes.count)
    var nextPortsByID: [RoutingCanvasElementID: Port] = [:]

    for presentationNode in content.presentation.nodes {
      guard case .node(let workspaceID) = presentationNode.address.elementID,
        let frame = content.frame(for: presentationNode.localID)
      else {
        continue
      }
      let ports: [Port] = content.portLocalIDs(of: presentationNode.localID).compactMap {
        localID -> Port? in
        guard let presentationPort = content.port(for: localID),
          let anchor = content.anchor(for: localID)
        else {
          return nil
        }
        return Port(
          id: presentationPort.id,
          nodeID: presentationNode.id,
          workspaceNodeID: workspaceID,
          value: presentationPort.value,
          position: anchor.position
        )
      }
      for port in ports {
        nextPortsByID[port.id] = port
      }
      nextNodes.append(
        Node(
          id: presentationNode.id,
          workspaceID: workspaceID,
          value: presentationNode.value,
          frame: frame,
          ports: ports,
          supplement: supplements[workspaceID] ?? .empty
        )
      )
    }

    nodes = nextNodes
    portByID = nextPortsByID
    edges = content.presentation.edges.compactMap { presentationEdge in
      guard let route = content.route(for: presentationEdge.localID) else { return nil }
      return Edge(id: presentationEdge.id, route: route)
    }
    contentBounds =
      nextNodes.map(\.frame).reduce(nil) { bounds, frame in
        bounds?.union(frame) ?? frame
      }?.insetBy(dx: -72, dy: -72) ?? CGRect(x: -1, y: -1, width: 2, height: 2)
  }

  func port(id: RoutingCanvasElementID) -> Port? {
    portByID[id]
  }

  func nodesInRenderOrder(
    selection: Set<RoutingCanvasElementID>
  ) -> [Node] {
    nodes.enumerated().sorted { first, second in
      let firstSelected = selection.contains(first.element.id)
      let secondSelected = selection.contains(second.element.id)
      if firstSelected != secondSelected { return !firstSelected }
      return first.offset < second.offset
    }.map(\.element)
  }

  func validatesConnection(
    from source: Port,
    to target: Port
  ) -> Bool {
    guard source.workspaceNodeID != target.workspaceNodeID,
      source.value.direction == .output,
      target.value.direction == .input
    else {
      return false
    }
    switch (source.value.channel, target.value.channel) {
    case (.all, .all), (.channel, .all):
      return true
    case (.channel(let sourceIndex), .channel(let targetIndex)):
      return sourceIndex == targetIndex
    case (.all, .channel):
      return false
    }
  }
}
