import AppKit
import FlowingDayGraphCanvas
import FlowingDayGraphComposition
import FlowingDayGraphLayout
import Foundation
import RilliyaKit

struct RoutingMetalNodeSupplement: Equatable {
  let isRunning: Bool
  let isCapturing: Bool
  let captureConsumerCount: Int
  let visualizerSignal: RoutingVisualizerSignal?
  let peakLevelSignal: RoutingPeakLevelSignal?
  let captureFormat: RoutingAudioCaptureFormat?
  let audioSourceMeters: [RoutingAudioChannelMeterSignal]
  let audioChannelControls: [Int: RoutingAudioChannelControl]
  let applicationIcon: NSImage?
  let audioOutputState: RoutingAudioOutputState?

  init(
    isRunning: Bool,
    isCapturing: Bool,
    captureConsumerCount: Int,
    visualizerSignal: RoutingVisualizerSignal?,
    peakLevelSignal: RoutingPeakLevelSignal? = nil,
    captureFormat: RoutingAudioCaptureFormat? = nil,
    audioSourceMeters: [RoutingAudioChannelMeterSignal] = [],
    audioChannelControls: [Int: RoutingAudioChannelControl] = [:],
    applicationIcon: NSImage? = nil,
    audioOutputState: RoutingAudioOutputState? = nil
  ) {
    self.isRunning = isRunning
    self.isCapturing = isCapturing
    self.captureConsumerCount = captureConsumerCount
    self.visualizerSignal = visualizerSignal
    self.peakLevelSignal = peakLevelSignal
    self.captureFormat = captureFormat
    self.audioSourceMeters = audioSourceMeters
    self.audioChannelControls = audioChannelControls
    self.applicationIcon = applicationIcon
    self.audioOutputState = audioOutputState
  }

  static let empty = RoutingMetalNodeSupplement(
    isRunning: false,
    isCapturing: false,
    captureConsumerCount: 0,
    visualizerSignal: nil,
    peakLevelSignal: nil,
    captureFormat: nil,
    audioSourceMeters: [],
    audioChannelControls: [:]
  )
}

enum RoutingMetalVisualizerPresentation: Equatable {
  static let waitingMessage = "Waiting for audio input"

  case waiting
  case waveform([RoutingVisualizerLaneSignal])

  init(signal: RoutingVisualizerSignal?) {
    guard let lanes = signal?.lanes, !lanes.isEmpty else {
      self = .waiting
      return
    }
    self = .waveform(lanes)
  }
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
      case .inputAudio:
        return "Input Audio"
      case .outputAudio:
        return "Output Audio"
      case .visualizer:
        return "Visualizer"
      case .audioMixer:
        return "Audio Mixer"
      case .peakLevel:
        return "Peak Level"
      case .signalGenerator:
        return "Signal Generator"
      }
    }

    var subtitle: String {
      switch value {
      case .applicationAudio(let selection, _):
        return selection?.displayName ?? "Choose an application"
      case .inputAudio(let selection, _):
        return selection?.displayName ?? "Choose an input device"
      case .outputAudio(let selection, _):
        return selection?.displayName ?? "Choose an output device"
      case .visualizer(let configuration):
        if configuration.mode == .mixed { return "Mixed waveform" }
        let count = configuration.normalizedSelectedChannels.count
        return "\(count) selected channel\(count == 1 ? "" : "s")"
      case .audioMixer(let configuration):
        return "\(configuration.channelCount)-channel mix"
      case .peakLevel:
        return "Linear full-scale peak"
      case .signalGenerator(let configuration):
        if configuration.waveform.usesFrequency {
          return
            "\(configuration.waveform.displayName) · \(configuration.frequency.formatted(.number.precision(.fractionLength(0)))) Hz"
        }
        return configuration.waveform.displayName
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
      case .inputAudio(let selection, _):
        if supplement.isCapturing {
          if supplement.captureConsumerCount > 1 {
            return "Shared capture · \(supplement.captureConsumerCount) nodes"
          }
          return "Capturing live input"
        }
        if supplement.isRunning { return "Ready to capture" }
        return selection == nil ? "Select to configure" : "Input device is unavailable"
      case .outputAudio(let selection, _):
        switch supplement.audioOutputState {
        case .waitingForCapture:
          return "Waiting for routed capture"
        case .starting:
          return "Preparing output device"
        case .running:
          return "Playing routed audio"
        case .failed:
          return "Output stopped"
        case .idle, .none:
          break
        }
        if supplement.isRunning { return "Ready for routed audio" }
        return selection == nil ? "Select to configure" : "Output device is unavailable"
      case .visualizer:
        return supplement.visualizerSignal == nil ? "Waiting for routed audio" : "Live waveform"
      case .audioMixer:
        return supplement.audioSourceMeters.contains(where: { $0.peak > 0 })
          ? "Live mix" : "Waiting for routed audio"
      case .peakLevel:
        guard let signal = supplement.peakLevelSignal else { return "Waiting for routed audio" }
        return signal.isClipping ? "Clipping" : "Live peak"
      case .signalGenerator:
        return "Ready to route"
      }
    }

    var applicationStatusText: String? {
      guard case .applicationAudio(let selection, _) = value else { return nil }
      return selection == nil ? "Select this node to configure" : nil
    }

    var inputDeviceStatusText: String? {
      guard case .inputAudio(let selection, _) = value else { return nil }
      return selection == nil ? "Select this node to configure" : nil
    }

    var outputDeviceStatusText: String? {
      guard case .outputAudio(let selection, _) = value else { return nil }
      return selection == nil ? "Select this node to configure" : nil
    }

    var applicationStatusSymbolName: String? {
      guard case .applicationAudio(let selection, _) = value else { return nil }
      return selection == nil ? "cursorarrow.click" : nil
    }

    var inputDeviceStatusSymbolName: String? {
      guard case .inputAudio(let selection, _) = value else { return nil }
      return selection == nil ? "cursorarrow.click" : nil
    }

    var outputDeviceStatusSymbolName: String? {
      guard case .outputAudio(let selection, _) = value else { return nil }
      return selection == nil ? "cursorarrow.click" : nil
    }

    var hasApplicationSelection: Bool {
      guard case .applicationAudio(let selection, _) = value else { return false }
      return selection != nil
    }

    var hasAudioSourceSelection: Bool {
      switch value {
      case .applicationAudio(let selection, _):
        return selection != nil
      case .inputAudio(let selection, _):
        return selection != nil
      case .outputAudio(let selection, _):
        return selection != nil
      case .visualizer, .audioMixer, .peakLevel, .signalGenerator:
        return false
      }
    }

    var applicationURL: URL? {
      guard case .applicationAudio(let selection, _) = value else { return nil }
      return selection?.applicationURL
    }

    var drawsIconPlate: Bool {
      switch value {
      case .applicationAudio:
        supplement.applicationIcon == nil
      case .inputAudio, .outputAudio, .visualizer, .audioMixer, .peakLevel,
        .signalGenerator:
        true
      }
    }

    var symbolName: String {
      switch value {
      case .applicationAudio:
        return applicationURL == nil ? "macwindow" : "app.dashed"
      case .inputAudio:
        return "waveform.badge.mic"
      case .outputAudio:
        return "speaker.wave.2"
      case .visualizer:
        return "waveform"
      case .audioMixer:
        return "slider.horizontal.3"
      case .peakLevel:
        return "gauge.with.dots.needle.50percent"
      case .signalGenerator:
        return "waveform.path"
      }
    }

    var miniMapStyleIndex: Int {
      switch value {
      case .applicationAudio: 0
      case .inputAudio: 1
      case .outputAudio: 2
      case .visualizer: 3
      case .audioMixer: 4
      case .peakLevel: 5
      case .signalGenerator: 6
      }
    }

    var embedsPortLabels: Bool {
      switch value {
      case .applicationAudio(let selection, .separate):
        return selection != nil
      case .inputAudio(let selection, .separate):
        return selection != nil
      case .outputAudio(let selection, .separate):
        return selection != nil
      case .audioMixer:
        return true
      case .applicationAudio, .inputAudio, .outputAudio, .visualizer, .peakLevel,
        .signalGenerator:
        return false
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
    let workspaceID: UUID
    let route: FlowingGraphEdgeRoute
    let sourceNodeID: RoutingCanvasElementID
    let targetNodeID: RoutingCanvasElementID
    let sourcePort: Port
    let targetPort: Port
    let label: String?
    let isEnabled: Bool
    let isActive: Bool
    let cullingBounds: CGRect
  }

  let contentID: FlowingLayoutInputID
  let presentationSnapshotID: FlowingGraphPresentationSnapshotID
  let nodes: [Node]
  let edges: [Edge]
  let contentBounds: CGRect

  private let miniMapStyleIndexByID: [RoutingCanvasElementID: Int]
  private let portByID: [RoutingCanvasElementID: Port]

  init(
    content: RoutingCanvasContent,
    supplements: [UUID: RoutingMetalNodeSupplement],
    connectionInformationLevel: RoutingConnectionInformationLevel = .format
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
    miniMapStyleIndexByID = Dictionary(
      uniqueKeysWithValues: nextNodes.map { ($0.id, $0.miniMapStyleIndex) }
    )
    let nextNodesByID = Dictionary(uniqueKeysWithValues: nextNodes.map { ($0.id, $0) })
    portByID = nextPortsByID
    edges = content.presentation.edges.compactMap { presentationEdge in
      guard let route = content.route(for: presentationEdge.localID),
        case .edge(let workspaceID) = presentationEdge.address.elementID,
        case .directed(.port(let sourcePortID), .port(let targetPortID)) =
          presentationEdge.endpoints,
        let sourcePort = nextPortsByID[sourcePortID],
        let targetPort = nextPortsByID[targetPortID],
        let sourceNode = nextNodesByID[sourcePort.nodeID],
        let targetNode = nextNodesByID[targetPort.nodeID]
      else {
        return nil
      }
      return Edge(
        id: presentationEdge.id,
        workspaceID: workspaceID,
        route: route,
        sourceNodeID: sourcePort.nodeID,
        targetNodeID: targetPort.nodeID,
        sourcePort: sourcePort,
        targetPort: targetPort,
        label: RoutingConnectionLabelFormatter.label(
          level: connectionInformationLevel,
          source: sourcePort.value,
          target: targetPort.value,
          targetNode: targetNode.value,
          format: sourceNode.supplement.captureFormat
        ),
        isEnabled: presentationEdge.value.isEnabled,
        isActive: presentationEdge.value.isActive,
        cullingBounds: Self.cullingBounds(for: route)
      )
    }
    contentBounds =
      nextNodes.map(\.frame).reduce(nil) { bounds, frame in
        bounds?.union(frame) ?? frame
      }?.insetBy(dx: -72, dy: -72) ?? CGRect(x: -1, y: -1, width: 2, height: 2)
  }

  func port(id: RoutingCanvasElementID) -> Port? {
    portByID[id]
  }

  func miniMapStyleIndex(for id: RoutingCanvasElementID) -> Int {
    miniMapStyleIndexByID[id] ?? 0
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

  func renderElements(
    intersecting rect: CGRect,
    selection: Set<RoutingCanvasElementID>
  ) -> (nodes: [Node], edges: [Edge]) {
    var unselectedNodes: [Node] = []
    var selectedNodes: [Node] = []
    unselectedNodes.reserveCapacity(nodes.count)
    selectedNodes.reserveCapacity(min(selection.count, nodes.count))
    for node in nodes where node.frame.intersects(rect) {
      if selection.contains(node.id) {
        selectedNodes.append(node)
      } else {
        unselectedNodes.append(node)
      }
    }
    unselectedNodes.append(contentsOf: selectedNodes)
    return (
      unselectedNodes,
      edges.filter { $0.cullingBounds.intersects(rect) }
    )
  }

  func validatesConnection(
    from source: Port,
    to target: Port
  ) -> Bool {
    guard source.workspaceNodeID != target.workspaceNodeID,
      source.value.isEnabled,
      target.value.isEnabled,
      RoutingPortCompatibility.incompatibilityReason(
        source: source.value,
        target: target.value
      ) == nil
    else {
      return false
    }
    if target.value.connectionPolicy == .singleInput,
      edges.contains(where: { $0.isEnabled && $0.targetPort.id == target.id })
    {
      return false
    }
    return true
  }

  private static func cullingBounds(for route: FlowingGraphEdgeRoute) -> CGRect {
    var minimumX = route.start.x
    var maximumX = route.start.x
    var minimumY = route.start.y
    var maximumY = route.start.y
    func include(_ point: CGPoint) {
      minimumX = min(minimumX, point.x)
      maximumX = max(maximumX, point.x)
      minimumY = min(minimumY, point.y)
      maximumY = max(maximumY, point.y)
    }
    for segment in route.segments {
      switch segment {
      case .line(let end):
        include(end)
      case .quadratic(let control, let end):
        include(control)
        include(end)
      case .cubic(let control1, let control2, let end):
        include(control1)
        include(control2)
        include(end)
      }
    }
    return CGRect(
      x: minimumX,
      y: minimumY,
      width: maximumX - minimumX,
      height: maximumY - minimumY
    ).insetBy(dx: -12, dy: -12)
  }
}

enum RoutingMetalEdgeRouteProjection {
  static func route(
    _ route: FlowingGraphEdgeRoute,
    sourceMoves: Bool,
    targetMoves: Bool,
    translation: CGSize
  ) -> FlowingGraphEdgeRoute {
    guard translation != .zero, sourceMoves || targetMoves else { return route }
    if sourceMoves, targetMoves {
      return translated(route, by: translation)
    }

    let finalIndex = route.segments.indices.last
    let segments: [FlowingGraphEdgePathSegment] = route.segments.enumerated().map {
      index, segment in
      switch segment {
      case .line(let end):
        return FlowingGraphEdgePathSegment.line(
          end: targetMoves && index == finalIndex ? end.translated(by: translation) : end
        )
      case .quadratic(let control, let end):
        return FlowingGraphEdgePathSegment.quadratic(
          control: (sourceMoves && index == 0) || (targetMoves && index == finalIndex)
            ? control.translated(by: translation)
            : control,
          end: targetMoves && index == finalIndex ? end.translated(by: translation) : end
        )
      case .cubic(let control1, let control2, let end):
        return FlowingGraphEdgePathSegment.cubic(
          control1: sourceMoves && index == 0
            ? control1.translated(by: translation)
            : control1,
          control2: targetMoves && index == finalIndex
            ? control2.translated(by: translation)
            : control2,
          end: targetMoves && index == finalIndex ? end.translated(by: translation) : end
        )
      }
    }
    return FlowingGraphEdgeRoute(
      start: sourceMoves ? route.start.translated(by: translation) : route.start,
      segments: segments
    )
  }

  private static func translated(
    _ route: FlowingGraphEdgeRoute,
    by translation: CGSize
  ) -> FlowingGraphEdgeRoute {
    FlowingGraphEdgeRoute(
      start: route.start.translated(by: translation),
      segments: route.segments.map { segment -> FlowingGraphEdgePathSegment in
        switch segment {
        case .line(let end):
          return .line(end: end.translated(by: translation))
        case .quadratic(let control, let end):
          return .quadratic(
            control: control.translated(by: translation),
            end: end.translated(by: translation)
          )
        case .cubic(let control1, let control2, let end):
          return .cubic(
            control1: control1.translated(by: translation),
            control2: control2.translated(by: translation),
            end: end.translated(by: translation)
          )
        }
      }
    )
  }
}

extension CGPoint {
  fileprivate func translated(by translation: CGSize) -> CGPoint {
    CGPoint(x: x + translation.width, y: y + translation.height)
  }
}
