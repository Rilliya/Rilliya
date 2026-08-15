import CoreGraphics
import FlowingDayGraphCanvas
import Foundation
import Observation
import RilliyaKit

@MainActor
@Observable
final class RoutingWorkspaceModel {
  let id: UUID

  private(set) var nodes: [RoutingWorkspaceNode] = []
  private(set) var edges: [RoutingWorkspaceEdge] = []
  private(set) var canvasContent: RoutingCanvasContent?
  private(set) var accessibilitySnapshot: RoutingCanvasAccessibilitySnapshot?
  private(set) var buildFailureDescription: String?
  private(set) var runtimeCaptureFormats: [UUID: RoutingAudioCaptureFormat] = [:]

  private var pendingSeparateSourcesByVisualizer: [UUID: Set<UUID>] = [:]
  private var preferredSeparateChannelCount: Int?

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
  func addInputAudioNode(
    centeredAt worldPoint: CGPoint,
    id: UUID = UUID()
  ) -> UUID {
    precondition(worldPoint.x.isFinite && worldPoint.y.isFinite)
    precondition(!nodes.contains { $0.id == id })
    let value = RoutingNodeValue.inputAudio(
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

  @discardableResult
  func addPeakLevelNode(
    centeredAt worldPoint: CGPoint,
    id: UUID = UUID()
  ) -> UUID {
    precondition(worldPoint.x.isFinite && worldPoint.y.isFinite)
    precondition(!nodes.contains { $0.id == id })
    let value = RoutingNodeValue.peakLevel
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
    runtimeCaptureFormats[nodeID] = nil
    resizeNode(at: index)
    rebuildCanvas()
  }

  func selectInputDevice(
    _ selection: RoutingInputDeviceSelection?,
    for nodeID: UUID
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
    guard case .inputAudio(_, let channelPresentation) = nodes[index].value else { return }
    nodes[index].value = .inputAudio(
      selection: selection,
      channelPresentation: channelPresentation
    )
    runtimeCaptureFormats[nodeID] = nil
    resizeNode(at: index)
    rebuildCanvas()
  }

  func setApplicationChannelPresentation(
    _ presentation: RoutingChannelPresentation,
    for nodeID: UUID
  ) {
    setAudioSourceChannelPresentation(presentation, for: nodeID, expectedApplication: true)
  }

  func setInputDeviceChannelPresentation(
    _ presentation: RoutingChannelPresentation,
    for nodeID: UUID
  ) {
    setAudioSourceChannelPresentation(presentation, for: nodeID, expectedApplication: false)
  }

  private func setAudioSourceChannelPresentation(
    _ presentation: RoutingChannelPresentation,
    for nodeID: UUID,
    expectedApplication: Bool
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
    let current = nodes[index].value
    guard
      expectedApplication
        ? current.applicationSelection != nil || isUnconfiguredApplication(current)
        : current.inputDeviceSelection != nil || isUnconfiguredInputDevice(current)
    else { return }
    let normalized: RoutingChannelPresentation
    switch presentation {
    case .aggregate:
      normalized = .aggregate
    case .separate(let channelCount):
      let runtimeChannelCount = runtimeCaptureFormats[nodeID]?.channelIDs.count
      normalized = .separate(
        channelCount: max(
          1,
          min(
            RoutingVisualizerConfiguration.maximumAvailableChannelCount,
            min(channelCount, runtimeChannelCount ?? channelCount)
          )
        )
      )
    }

    guard
      migrateAudioSourceEdges(
        nodeID: nodeID,
        from: current,
        to: normalized
      )
    else {
      return
    }
    guard let updated = current.replacingAudioSourceChannelPresentation(normalized) else { return }
    nodes[index].value = updated
    resizeNode(at: index)
    rebuildCanvas()
  }

  private func isUnconfiguredApplication(_ value: RoutingNodeValue) -> Bool {
    guard case .applicationAudio = value else { return false }
    return true
  }

  private func isUnconfiguredInputDevice(_ value: RoutingNodeValue) -> Bool {
    guard case .inputAudio = value else { return false }
    return true
  }

  func configureVisualizer(
    _ configuration: RoutingVisualizerConfiguration,
    for nodeID: UUID
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }),
      case .visualizer(let previous) = nodes[index].value
    else {
      return
    }
    var normalized = configuration
    normalized.availableChannelCount = max(
      1,
      min(
        RoutingVisualizerConfiguration.maximumAvailableChannelCount,
        configuration.availableChannelCount
      )
    )
    normalized.selectedChannels = Set(normalized.normalizedSelectedChannels)
    if normalized.selectedChannels.isEmpty {
      normalized.selectedChannels = [0]
    }
    nodes[index].value = .visualizer(configuration: normalized)

    if previous.mode != normalized.mode {
      switch normalized.mode {
      case .mixed:
        pendingSeparateSourcesByVisualizer[nodeID] = nil
        retargetIncomingEdgesToMixedInput(nodeID: nodeID)
      case .separate:
        let sourceIDs = Set(incomingEdges(for: nodeID).map(\.source.nodeID))
        if !sourceIDs.isEmpty {
          pendingSeparateSourcesByVisualizer[nodeID] = sourceIDs
          edges.removeAll { $0.target.nodeID == nodeID }
          _ = materializePendingSeparation(for: nodeID)
        }
      }
    }
    resizeNode(at: index)
    rebuildCanvas()
  }

  func synchronizeCaptureFormats(
    _ formats: [UUID: ProcessOutputCaptureFormat],
    preferredSeparateChannelCount: Int? = nil
  ) {
    synchronizeAudioCaptureFormats(
      formats.mapValues(RoutingAudioCaptureFormat.init),
      preferredSeparateChannelCount: preferredSeparateChannelCount
    )
  }

  func synchronizeInputCaptureFormats(
    _ formats: [UUID: DeviceInputCaptureFormat],
    preferredSeparateChannelCount: Int? = nil
  ) {
    synchronizeAudioCaptureFormats(
      formats.mapValues(RoutingAudioCaptureFormat.init),
      preferredSeparateChannelCount: preferredSeparateChannelCount
    )
  }

  private func synchronizeAudioCaptureFormats(
    _ formats: [UUID: RoutingAudioCaptureFormat],
    preferredSeparateChannelCount: Int? = nil
  ) {
    self.preferredSeparateChannelCount = preferredSeparateChannelCount.map(
      normalizedRuntimeChannelCount
    )
    var needsRebuild = false
    for (nodeID, format) in formats where !format.channelIDs.isEmpty {
      guard let index = nodes.firstIndex(where: { $0.id == nodeID }),
        let presentation = nodes[index].value.audioSourceChannelPresentation
      else {
        continue
      }
      if runtimeCaptureFormats[nodeID] != format {
        runtimeCaptureFormats[nodeID] = format
      }
      let channelCount = effectiveSeparateChannelCount(format.channelIDs.count)
      guard case .separate(let currentCount) = presentation,
        currentCount != channelCount
      else {
        continue
      }
      guard
        let updated = nodes[index].value.replacingAudioSourceChannelPresentation(
          .separate(channelCount: channelCount)
        )
      else { continue }
      nodes[index].value = updated
      resizeNode(at: index)
      needsRebuild = true
    }

    for visualizerID in pendingSeparateSourcesByVisualizer.keys.sorted(by: {
      $0.uuidString < $1.uuidString
    }) {
      needsRebuild = materializePendingSeparation(for: visualizerID) || needsRebuild
    }
    if needsRebuild {
      rebuildCanvas()
    }
  }

  var captureSourceNodeIDs: Set<UUID> {
    Set(edges.filter(\.isEnabled).map(\.source.nodeID))
      .union(pendingSeparateSourcesByVisualizer.values.flatMap { $0 })
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
      .filter { $0.isEnabled && $0.target.nodeID == nodeID }
      .map(\.source.nodeID)
      .filter { seen.insert($0).inserted }
  }

  func incomingEdges(for nodeID: UUID) -> [RoutingWorkspaceEdge] {
    edges.filter { $0.isEnabled && $0.target.nodeID == nodeID }
  }

  func removeEdges(ids: Set<UUID>) {
    guard !ids.isEmpty else { return }
    let previousCount = edges.count
    edges.removeAll { ids.contains($0.id) }
    guard edges.count != previousCount else { return }
    rebuildCanvas()
  }

  func toggleEdgeEnabled(id: UUID) {
    guard let index = edges.firstIndex(where: { $0.id == id }) else { return }
    if edges[index].isEnabled {
      edges[index].isEnabled = false
    } else {
      guard
        case .valid = connectionValidation(
          source: edges[index].source,
          target: edges[index].target,
          ignoringEdgeID: edges[index].id
        )
      else {
        return
      }
      edges[index].isEnabled = true
    }
    rebuildCanvas()
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
    target: RoutingWorkspacePortAddress,
    ignoringEdgeID: UUID? = nil
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
    if targetValue.connectionPolicy == .singleInput,
      edges.contains(where: {
        $0.id != ignoringEdgeID && $0.isEnabled && $0.target == target
      })
    {
      return .invalid(.init(message: "Disconnect the existing input first"))
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
    if let index = edges.firstIndex(where: { $0.source == source && $0.target == target }) {
      guard !edges[index].isEnabled else { return }
      edges[index].isEnabled = true
      rebuildCanvas()
      return
    }
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

  private func migrateAudioSourceEdges(
    nodeID: UUID,
    from value: RoutingNodeValue,
    to presentation: RoutingChannelPresentation
  ) -> Bool {
    guard let previous = value.audioSourceChannelPresentation,
      previous != presentation
    else {
      return true
    }
    let outgoing = edges.filter { $0.source.nodeID == nodeID }

    switch (previous, presentation) {
    case (.aggregate, .separate(let channelCount)):
      let aggregateEdges = outgoing.filter { $0.source.portID.audioChannel == .all }
      edges.removeAll { edge in aggregateEdges.contains { $0.id == edge.id } }
      for edge in aggregateEdges where edge.target.portID.audioChannel == .all {
        for channel in 0..<channelCount {
          appendEdgeIfMissing(
            source: RoutingWorkspacePortAddress(
              nodeID: nodeID,
              portID: RoutingGraphPortID(direction: .output, channel: .channel(channel))
            ),
            target: edge.target
          )
        }
      }
      return true

    case (.separate(let channelCount), .aggregate):
      guard canCollapseToAggregate(outgoing: outgoing, channelCount: channelCount) else {
        return false
      }
      let targetAddresses = Set(outgoing.map(\.target))
      edges.removeAll { $0.source.nodeID == nodeID }
      for target in targetAddresses {
        appendEdgeIfMissing(
          source: RoutingWorkspacePortAddress(
            nodeID: nodeID,
            portID: RoutingGraphPortID(direction: .output, channel: .all)
          ),
          target: target
        )
      }
      return true

    case (.aggregate, .aggregate), (.separate, .separate):
      return true
    }
  }

  private func canCollapseToAggregate(
    outgoing: [RoutingWorkspaceEdge],
    channelCount: Int
  ) -> Bool {
    guard !outgoing.isEmpty else { return true }
    let grouped = Dictionary(grouping: outgoing, by: \.target)
    let expected = Set(0..<channelCount)
    return grouped.allSatisfy { target, targetEdges in
      guard target.portID.audioChannel == .all else { return false }
      let channels = Set(
        targetEdges.compactMap { edge -> Int? in
          guard case .some(.channel(let index)) = edge.source.portID.audioChannel else {
            return nil
          }
          return index
        })
      return channels == expected && targetEdges.count == expected.count
    }
  }

  private func retargetIncomingEdgesToMixedInput(nodeID: UUID) {
    let incoming = incomingEdges(for: nodeID)
    edges.removeAll { $0.target.nodeID == nodeID }
    let target = RoutingWorkspacePortAddress(
      nodeID: nodeID,
      portID: RoutingGraphPortID(direction: .input, channel: .all)
    )
    for edge in incoming {
      appendEdgeIfMissing(source: edge.source, target: target)
    }
  }

  @discardableResult
  private func materializePendingSeparation(for visualizerID: UUID) -> Bool {
    guard let sourceIDs = pendingSeparateSourcesByVisualizer[visualizerID],
      !sourceIDs.isEmpty,
      let visualizerIndex = nodes.firstIndex(where: { $0.id == visualizerID }),
      case .visualizer(var configuration) = nodes[visualizerIndex].value
    else {
      return false
    }
    let formats = sourceIDs.sorted(by: { $0.uuidString < $1.uuidString }).compactMap { nodeID in
      runtimeCaptureFormats[nodeID].map { (nodeID, $0) }
    }
    guard formats.count == sourceIDs.count else { return false }
    let maximumChannelCount =
      formats.map { effectiveSeparateChannelCount($0.1.channelIDs.count) }.max() ?? 0
    guard maximumChannelCount > 0,
      maximumChannelCount <= RoutingVisualizerConfiguration.maximumSeparateLaneCount
    else {
      return false
    }

    configuration.mode = .separate
    configuration.availableChannelCount = maximumChannelCount
    configuration.selectedChannels = Set(0..<maximumChannelCount)
    nodes[visualizerIndex].value = .visualizer(configuration: configuration)
    resizeNode(at: visualizerIndex)

    edges.removeAll { $0.target.nodeID == visualizerID }
    for (sourceID, format) in formats {
      guard let sourceIndex = nodes.firstIndex(where: { $0.id == sourceID }),
        let updated = nodes[sourceIndex].value.replacingAudioSourceChannelPresentation(
          .separate(channelCount: effectiveSeparateChannelCount(format.channelIDs.count))
        )
      else {
        continue
      }
      let channelCount = effectiveSeparateChannelCount(format.channelIDs.count)
      nodes[sourceIndex].value = updated
      resizeNode(at: sourceIndex)
      for channel in 0..<channelCount {
        appendEdgeIfMissing(
          source: RoutingWorkspacePortAddress(
            nodeID: sourceID,
            portID: RoutingGraphPortID(direction: .output, channel: .channel(channel))
          ),
          target: RoutingWorkspacePortAddress(
            nodeID: visualizerID,
            portID: RoutingGraphPortID(direction: .input, channel: .channel(channel))
          )
        )
      }
    }
    pendingSeparateSourcesByVisualizer[visualizerID] = nil
    return true
  }

  private func appendEdgeIfMissing(
    source: RoutingWorkspacePortAddress,
    target: RoutingWorkspacePortAddress
  ) {
    guard !edges.contains(where: { $0.source == source && $0.target == target }) else {
      return
    }
    edges.append(RoutingWorkspaceEdge(id: UUID(), source: source, target: target))
  }

  private func normalizedRuntimeChannelCount(_ channelCount: Int) -> Int {
    max(
      1,
      min(
        RoutingVisualizerConfiguration.maximumAvailableChannelCount,
        channelCount
      )
    )
  }

  private func effectiveSeparateChannelCount(_ nativeChannelCount: Int) -> Int {
    let normalizedNativeCount = normalizedRuntimeChannelCount(nativeChannelCount)
    guard let preferredSeparateChannelCount else { return normalizedNativeCount }
    return min(normalizedNativeCount, preferredSeparateChannelCount)
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
