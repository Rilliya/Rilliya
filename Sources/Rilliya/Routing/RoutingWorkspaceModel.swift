import CoreGraphics
import FlowingDayGraphCanvas
import Foundation
import Observation
import RilliyaCapture

enum RoutingWorkspaceRestorationError: Error, Equatable {
  case duplicateNodeID
  case duplicateEdgeID
  case invalidNodeFrame
}

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
  private(set) var persistenceRevision: UInt64 = 0

  private var pendingSeparateSourcesByVisualizer: [UUID: Set<UUID>] = [:]
  private var preferredSeparateChannelCount: Int?
  @ObservationIgnored private var canvasBuildGeneration: UInt64 = 0

  init(id: UUID = UUID()) {
    self.id = id
    rebuildCanvas()
  }

  init(
    restoringID id: UUID,
    nodes: [RoutingWorkspaceNode],
    edges: [RoutingWorkspaceEdge]
  ) throws {
    guard Set(nodes.map(\.id)).count == nodes.count else {
      throw RoutingWorkspaceRestorationError.duplicateNodeID
    }
    guard Set(edges.map(\.id)).count == edges.count else {
      throw RoutingWorkspaceRestorationError.duplicateEdgeID
    }
    guard nodes.allSatisfy({ Self.isValidPersistedFrame($0.frame) }) else {
      throw RoutingWorkspaceRestorationError.invalidNodeFrame
    }

    self.id = id
    self.nodes = nodes.map { node in
      var restored = node
      let size = RoutingCanvasMetrics.nodeSize(for: restored.value)
      restored.frame = CGRect(
        x: node.frame.midX - size.width / 2,
        y: node.frame.midY - size.height / 2,
        width: size.width,
        height: size.height
      )
      let availablePortIDs = Set(RoutingGraphPorts.values(for: restored.value).map(\.id))
      restored.disabledPortIDs.formIntersection(availablePortIDs)
      return restored
    }
    let nodeIDs = Set(nodes.map(\.id))
    self.edges = edges.filter {
      $0.source.nodeID != $0.target.nodeID
        && nodeIDs.contains($0.source.nodeID)
        && nodeIDs.contains($0.target.nodeID)
    }
    rebuildCanvas()
  }

  #if PROFILE
    func installProfilingGraph(
      nodes: [RoutingWorkspaceNode],
      edges: [RoutingWorkspaceEdge]
    ) {
      precondition(Set(nodes.map(\.id)).count == nodes.count)
      precondition(Set(edges.map(\.id)).count == edges.count)
      self.nodes = nodes
      self.edges = edges
      rebuildCanvas()
    }
  #endif

  @discardableResult
  func addNode(
    of kind: RoutingNodeKind,
    centeredAt worldPoint: CGPoint
  ) async -> UUID {
    let value: RoutingNodeValue =
      switch kind {
      case .applicationAudio:
        .applicationAudio(selection: nil, channelPresentation: .aggregate)
      case .inputAudio:
        .inputAudio(selection: nil, channelPresentation: .aggregate)
      case .outputAudio:
        .outputAudio(selection: nil, channelPresentation: .aggregate)
      case .visualizer:
        .visualizer(configuration: .initial)
      case .audioMixer:
        .audioMixer(configuration: .initial)
      case .gain:
        .gain(configuration: .initial)
      case .channelRouter:
        .channelRouter(configuration: .initial)
      case .peakLevel:
        .peakLevel
      case .signalGenerator:
        .signalGenerator(configuration: .initial)
      case .filePlayback:
        .filePlayback(configuration: .initial)
      case .fileOutput:
        .fileOutput(configuration: .initial)
      case .networkSend:
        .networkSend(configuration: .initial)
      case .networkReceive:
        .networkReceive(configuration: .initial)
      case .delay:
        .delay(configuration: .initial)
      case .noiseGate:
        .noiseGate(configuration: .initial)
      case .compressor:
        .compressor(configuration: .initial)
      }
    let nodeID = UUID()
    appendNode(id: nodeID, value: value, centeredAt: worldPoint)
    await rebuildCanvasInBackground()
    return nodeID
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
  func addOutputAudioNode(
    centeredAt worldPoint: CGPoint,
    id: UUID = UUID()
  ) -> UUID {
    precondition(worldPoint.x.isFinite && worldPoint.y.isFinite)
    precondition(!nodes.contains { $0.id == id })
    let value = RoutingNodeValue.outputAudio(
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
  func addAudioMixerNode(
    centeredAt worldPoint: CGPoint,
    id: UUID = UUID()
  ) -> UUID {
    precondition(worldPoint.x.isFinite && worldPoint.y.isFinite)
    precondition(!nodes.contains { $0.id == id })
    let value = RoutingNodeValue.audioMixer(configuration: .initial)
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

  @discardableResult
  func addGainNode(
    centeredAt worldPoint: CGPoint,
    id: UUID = UUID()
  ) -> UUID {
    precondition(worldPoint.x.isFinite && worldPoint.y.isFinite)
    precondition(!nodes.contains { $0.id == id })
    appendNode(id: id, value: .gain(configuration: .initial), centeredAt: worldPoint)
    rebuildCanvas()
    return id
  }

  @discardableResult
  func addChannelRouterNode(
    centeredAt worldPoint: CGPoint,
    id: UUID = UUID()
  ) -> UUID {
    precondition(worldPoint.x.isFinite && worldPoint.y.isFinite)
    precondition(!nodes.contains { $0.id == id })
    appendNode(id: id, value: .channelRouter(configuration: .initial), centeredAt: worldPoint)
    rebuildCanvas()
    return id
  }

  @discardableResult
  func addSignalGeneratorNode(
    centeredAt worldPoint: CGPoint,
    id: UUID = UUID()
  ) -> UUID {
    precondition(worldPoint.x.isFinite && worldPoint.y.isFinite)
    precondition(!nodes.contains { $0.id == id })
    let value = RoutingNodeValue.signalGenerator(configuration: .initial)
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
  func addFilePlaybackNode(
    centeredAt worldPoint: CGPoint,
    id: UUID = UUID()
  ) -> UUID {
    precondition(worldPoint.x.isFinite && worldPoint.y.isFinite)
    precondition(!nodes.contains { $0.id == id })
    appendNode(
      id: id,
      value: .filePlayback(configuration: .initial),
      centeredAt: worldPoint
    )
    rebuildCanvas()
    return id
  }

  @discardableResult
  func addFileOutputNode(
    centeredAt worldPoint: CGPoint,
    id: UUID = UUID()
  ) -> UUID {
    precondition(worldPoint.x.isFinite && worldPoint.y.isFinite)
    precondition(!nodes.contains { $0.id == id })
    appendNode(
      id: id,
      value: .fileOutput(configuration: .initial),
      centeredAt: worldPoint
    )
    rebuildCanvas()
    return id
  }

  @discardableResult
  func addNetworkSendNode(
    centeredAt worldPoint: CGPoint,
    id: UUID = UUID()
  ) -> UUID {
    precondition(worldPoint.x.isFinite && worldPoint.y.isFinite)
    precondition(!nodes.contains { $0.id == id })
    appendNode(id: id, value: .networkSend(configuration: .initial), centeredAt: worldPoint)
    rebuildCanvas()
    return id
  }

  @discardableResult
  func addNetworkReceiveNode(
    centeredAt worldPoint: CGPoint,
    id: UUID = UUID()
  ) -> UUID {
    precondition(worldPoint.x.isFinite && worldPoint.y.isFinite)
    precondition(!nodes.contains { $0.id == id })
    appendNode(id: id, value: .networkReceive(configuration: .initial), centeredAt: worldPoint)
    rebuildCanvas()
    return id
  }

  @discardableResult
  func addDelayNode(
    centeredAt worldPoint: CGPoint,
    id: UUID = UUID()
  ) -> UUID {
    precondition(worldPoint.x.isFinite && worldPoint.y.isFinite)
    precondition(!nodes.contains { $0.id == id })
    let value = RoutingNodeValue.delay(configuration: .initial)
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
  func addNoiseGateNode(
    centeredAt worldPoint: CGPoint,
    id: UUID = UUID()
  ) -> UUID {
    precondition(worldPoint.x.isFinite && worldPoint.y.isFinite)
    precondition(!nodes.contains { $0.id == id })
    let value = RoutingNodeValue.noiseGate(configuration: .initial)
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
  func addCompressorNode(
    centeredAt worldPoint: CGPoint,
    id: UUID = UUID()
  ) -> UUID {
    precondition(worldPoint.x.isFinite && worldPoint.y.isFinite)
    precondition(!nodes.contains { $0.id == id })
    let value = RoutingNodeValue.compressor(configuration: .initial)
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
    guard
      case .applicationAudio(let currentSelection, let channelPresentation) =
        nodes[index].value,
      currentSelection != selection
    else { return }
    nodes[index].value = .applicationAudio(
      selection: selection,
      channelPresentation: channelPresentation
    )
    nodes[index].audioChannelControls.removeAll(keepingCapacity: true)
    runtimeCaptureFormats[nodeID] = nil
    resizeNode(at: index)
    rebuildCanvas()
  }

  func selectInputDevice(
    _ selection: RoutingInputDeviceSelection?,
    for nodeID: UUID
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
    guard case .inputAudio(let currentSelection, let channelPresentation) = nodes[index].value,
      currentSelection != selection
    else { return }
    nodes[index].value = .inputAudio(
      selection: selection,
      channelPresentation: channelPresentation
    )
    nodes[index].audioChannelControls.removeAll(keepingCapacity: true)
    runtimeCaptureFormats[nodeID] = nil
    resizeNode(at: index)
    rebuildCanvas()
  }

  func selectOutputDevice(
    _ selection: RoutingOutputDeviceSelection?,
    for nodeID: UUID
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
    guard case .outputAudio(let currentSelection, let channelPresentation) = nodes[index].value,
      currentSelection != selection
    else { return }
    nodes[index].value = .outputAudio(
      selection: selection,
      channelPresentation: channelPresentation
    )
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

  func setOutputDeviceChannelPresentation(
    _ presentation: RoutingChannelPresentation,
    for nodeID: UUID
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }),
      let updated = nodes[index].value.replacingAudioDestinationChannelPresentation(presentation),
      updated != nodes[index].value
    else { return }
    nodes[index].value = updated
    resizeNode(at: index)
    rebuildCanvas()
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
    } else if normalized.mode == .separate,
      previous.channelSelection != normalized.channelSelection
    {
      let sourceIDs = Set(incomingEdges(for: nodeID).map(\.source.nodeID))
        .union(pendingSeparateSourcesByVisualizer[nodeID] ?? [])
      if !sourceIDs.isEmpty {
        pendingSeparateSourcesByVisualizer[nodeID] = sourceIDs
        edges.removeAll { $0.target.nodeID == nodeID }
        _ = materializePendingSeparation(for: nodeID)
      }
    }
    resizeNode(at: index)
    rebuildCanvas()
  }

  func configureAudioMixer(
    _ configuration: RoutingAudioMixerConfiguration,
    for nodeID: UUID
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }),
      case .audioMixer(let previous) = nodes[index].value,
      previous != configuration
    else {
      return
    }
    nodes[index].value = .audioMixer(configuration: configuration)
    nodes[index].audioChannelControls = nodes[index].audioChannelControls.filter {
      $0.key < configuration.channelCount
    }
    let availablePortIDs = Set(RoutingGraphPorts.values(for: nodes[index].value).map(\.id))
    nodes[index].disabledPortIDs.formIntersection(availablePortIDs)
    resizeNode(at: index)
    rebuildCanvas()
  }

  func configureSignalGenerator(
    _ configuration: RoutingSignalGeneratorConfiguration,
    for nodeID: UUID
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }),
      case .signalGenerator(let previous) = nodes[index].value,
      previous != configuration
    else {
      return
    }
    nodes[index].value = .signalGenerator(configuration: configuration)
    rebuildCanvas()
  }

  func configureFilePlayback(
    _ configuration: RoutingFilePlaybackConfiguration,
    for nodeID: UUID
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }),
      case .filePlayback(let previous) = nodes[index].value,
      previous != configuration
    else {
      return
    }
    nodes[index].value = .filePlayback(configuration: configuration)
    let channelCount = configuration.selection?.channelCount ?? 0
    nodes[index].audioChannelControls = nodes[index].audioChannelControls.filter {
      $0.key < channelCount
    }
    rebuildCanvas()
  }

  func configureFileOutput(
    _ configuration: RoutingFileOutputConfiguration,
    for nodeID: UUID
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }),
      case .fileOutput(let previous) = nodes[index].value,
      previous != configuration
    else {
      return
    }
    nodes[index].value = .fileOutput(configuration: configuration)
    rebuildCanvas()
  }

  func configureNetworkSend(
    _ configuration: RoutingNetworkSendConfiguration,
    for nodeID: UUID
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }),
      case .networkSend(let previous) = nodes[index].value,
      previous != configuration
    else { return }
    nodes[index].value = .networkSend(configuration: configuration)
    rebuildCanvas()
  }

  func configureNetworkReceive(
    _ configuration: RoutingNetworkReceiveConfiguration,
    for nodeID: UUID
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }),
      case .networkReceive(let previous) = nodes[index].value,
      previous != configuration
    else { return }
    nodes[index].value = .networkReceive(configuration: configuration)
    rebuildCanvas()
  }

  func configureGain(
    _ configuration: RoutingGainConfiguration,
    for nodeID: UUID
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }),
      case .gain(let previous) = nodes[index].value,
      previous != configuration
    else {
      return
    }
    nodes[index].value = .gain(configuration: configuration)
    rebuildCanvas()
  }

  func configureChannelRouter(
    _ configuration: RoutingChannelRouterConfiguration,
    for nodeID: UUID
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }),
      case .channelRouter(let previous) = nodes[index].value,
      previous != configuration
    else {
      return
    }
    nodes[index].value = .channelRouter(configuration: configuration)
    let availablePortIDs = Set(RoutingGraphPorts.values(for: nodes[index].value).map(\.id))
    nodes[index].disabledPortIDs.formIntersection(availablePortIDs)
    resizeNode(at: index)
    rebuildCanvas()
  }

  func configureDelay(
    _ configuration: RoutingDelayConfiguration,
    for nodeID: UUID
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }),
      case .delay(let previous) = nodes[index].value,
      previous != configuration
    else {
      return
    }
    nodes[index].value = .delay(configuration: configuration)
    rebuildCanvas()
  }

  func configureNoiseGate(
    _ configuration: RoutingNoiseGateConfiguration,
    for nodeID: UUID
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }),
      case .noiseGate(let previous) = nodes[index].value,
      previous != configuration
    else {
      return
    }
    nodes[index].value = .noiseGate(configuration: configuration)
    rebuildCanvas()
  }

  func configureCompressor(
    _ configuration: RoutingCompressorConfiguration,
    for nodeID: UUID
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }),
      case .compressor(let previous) = nodes[index].value,
      previous != configuration
    else {
      return
    }
    nodes[index].value = .compressor(configuration: configuration)
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

    let separateVisualizerIDs = nodes.compactMap { node -> UUID? in
      guard case .visualizer(let configuration) = node.value,
        configuration.mode == .separate
      else { return nil }
      return node.id
    }
    for visualizerID in separateVisualizerIDs.sorted(by: {
      $0.uuidString < $1.uuidString
    }) {
      let sourceIDs =
        pendingSeparateSourcesByVisualizer[visualizerID]
        ?? Set(edges.lazy.filter { $0.target.nodeID == visualizerID }.map(\.source.nodeID))
      if !sourceIDs.isEmpty {
        pendingSeparateSourcesByVisualizer[visualizerID] = sourceIDs
      }
      needsRebuild = materializePendingSeparation(for: visualizerID) || needsRebuild
    }
    if needsRebuild {
      rebuildCanvas()
    }
  }

  var captureSourceNodeIDs: Set<UUID> {
    Set(edges.filter(isEdgeActive).map(\.source.nodeID))
      .union(pendingSeparateSourcesByVisualizer.values.flatMap { $0 })
  }

  var audioSourceNodeIDsFeedingOutputAudio: Set<UUID> {
    let activeEdges = edges.filter(isEdgeActive)
    let incomingEdges = Dictionary(grouping: activeEdges, by: { $0.target.nodeID })
    let outputNodeIDs = nodes.compactMap { node -> UUID? in
      guard case .outputAudio(let selection, _) = node.value, selection != nil else { return nil }
      return node.id
    }
    var reachable = Set(outputNodeIDs)
    var pending = outputNodeIDs
    while let nodeID = pending.popLast() {
      for edge in incomingEdges[nodeID] ?? []
      where reachable.insert(edge.source.nodeID).inserted {
        pending.append(edge.source.nodeID)
      }
    }
    return Set(
      nodes.compactMap { node -> UUID? in
        guard reachable.contains(node.id), case .applicationAudio = node.value else { return nil }
        return node.id
      })
  }

  func node(id: UUID) -> RoutingWorkspaceNode? {
    nodes.first { $0.id == id }
  }

  func setAccentOverride(_ accentID: RoutingAccentID?, for nodeID: UUID) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }),
      nodes[index].accentOverride != accentID
    else { return }
    nodes[index].accentOverride = accentID
    rebuildCanvas()
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
      .filter { isEdgeActive($0) && $0.target.nodeID == nodeID }
      .map(\.source.nodeID)
      .filter { seen.insert($0).inserted }
  }

  func incomingEdges(for nodeID: UUID) -> [RoutingWorkspaceEdge] {
    edges.filter { isEdgeActive($0) && $0.target.nodeID == nodeID }
  }

  func activeIncomingEdgesByTargetNode() -> [UUID: [RoutingWorkspaceEdge]] {
    Dictionary(
      grouping: edges.filter(isEdgeActive),
      by: { $0.target.nodeID }
    )
  }

  func isPortEnabled(nodeID: UUID, portID: RoutingGraphPortID) -> Bool {
    node(id: nodeID)?.isPortEnabled(portID) == true
  }

  func setPortEnabled(
    _ isEnabled: Bool,
    nodeID: UUID,
    portID: RoutingGraphPortID
  ) {
    guard let index = nodes.firstIndex(where: { $0.id == nodeID }),
      RoutingGraphPorts.values(for: nodes[index]).contains(where: { $0.id == portID })
    else {
      return
    }
    let wasEnabled = nodes[index].isPortEnabled(portID)
    guard wasEnabled != isEnabled else { return }
    if isEnabled {
      nodes[index].disabledPortIDs.remove(portID)
    } else {
      nodes[index].disabledPortIDs.insert(portID)
    }
    rebuildCanvas()
  }

  func togglePortEnabled(nodeID: UUID, portID: RoutingGraphPortID) {
    setPortEnabled(
      !isPortEnabled(nodeID: nodeID, portID: portID),
      nodeID: nodeID,
      portID: portID
    )
  }

  func audioChannelControl(
    nodeID: UUID,
    channelIndex: Int
  ) -> RoutingAudioChannelControl {
    node(id: nodeID)?.audioChannelControl(at: channelIndex) ?? .unity
  }

  func setAudioChannelGain(
    _ gainDecibels: Double,
    nodeID: UUID,
    channelIndex: Int
  ) {
    guard gainDecibels.isFinite else { return }
    let clampedGain = min(
      max(gainDecibels, RoutingAudioChannelControl.minimumGainDecibels),
      RoutingAudioChannelControl.maximumGainDecibels
    )
    updateAudioChannelControl(nodeID: nodeID, channelIndex: channelIndex) { control in
      control.gainDecibels = clampedGain
    }
  }

  func setAudioChannelMuted(
    _ isMuted: Bool,
    nodeID: UUID,
    channelIndex: Int
  ) {
    updateAudioChannelControl(nodeID: nodeID, channelIndex: channelIndex) { control in
      control.isMuted = isMuted
    }
  }

  func toggleAudioChannelMuted(nodeID: UUID, channelIndex: Int) {
    let next = !audioChannelControl(nodeID: nodeID, channelIndex: channelIndex).isMuted
    setAudioChannelMuted(next, nodeID: nodeID, channelIndex: channelIndex)
  }

  private func updateAudioChannelControl(
    nodeID: UUID,
    channelIndex: Int,
    update: (inout RoutingAudioChannelControl) -> Void
  ) {
    guard
      (0..<RoutingVisualizerConfiguration.maximumAvailableChannelCount).contains(
        channelIndex
      ),
      let index = nodes.firstIndex(where: { $0.id == nodeID }),
      nodes[index].value.audioSourceChannelPresentation != nil
        || nodes[index].value.audioMixerConfiguration != nil
    else {
      return
    }
    var control = nodes[index].audioChannelControl(at: channelIndex)
    let previous = control
    update(&control)
    guard control != previous else { return }
    if control == .unity {
      nodes[index].audioChannelControls[channelIndex] = nil
    } else {
      nodes[index].audioChannelControls[channelIndex] = control
    }
    persistenceRevision &+= 1
  }

  func isEdgeActive(_ edge: RoutingWorkspaceEdge) -> Bool {
    edge.isEnabled
      && isPortEnabled(nodeID: edge.source.nodeID, portID: edge.source.portID)
      && isPortEnabled(nodeID: edge.target.nodeID, portID: edge.target.portID)
  }

  func removeEdges(ids: Set<UUID>) {
    guard !ids.isEmpty else { return }
    let previousCount = edges.count
    edges.removeAll { ids.contains($0.id) }
    guard edges.count != previousCount else { return }
    rebuildCanvas()
  }

  func removeNodes(ids: Set<UUID>) {
    let removedNodeIDs = ids.intersection(nodes.map(\.id))
    guard !removedNodeIDs.isEmpty else { return }

    nodes.removeAll { removedNodeIDs.contains($0.id) }
    edges.removeAll {
      removedNodeIDs.contains($0.source.nodeID)
        || removedNodeIDs.contains($0.target.nodeID)
    }
    runtimeCaptureFormats = runtimeCaptureFormats.filter {
      !removedNodeIDs.contains($0.key)
    }

    var nextPendingSources: [UUID: Set<UUID>] = [:]
    for (visualizerID, sourceIDs) in pendingSeparateSourcesByVisualizer
    where !removedNodeIDs.contains(visualizerID) {
      let retainedSourceIDs = sourceIDs.subtracting(removedNodeIDs)
      if !retainedSourceIDs.isEmpty {
        nextPendingSources[visualizerID] = retainedSourceIDs
      }
    }
    pendingSeparateSourcesByVisualizer = nextPendingSources
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
    guard let address = portAddress(for: origin.fixedElementID),
      let value = portValue(at: address)
    else {
      return false
    }
    return value.direction == .output && value.isEnabled
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
    guard sourceValue.isEnabled, targetValue.isEnabled else {
      return .invalid(.init(message: "Enable both ports before connecting them"))
    }
    if let reason = RoutingPortCompatibility.incompatibilityReason(
      source: sourceValue,
      target: targetValue
    ),
      !canAutomaticallySeparateSource(
        source: source,
        sourceValue: sourceValue,
        targetValue: targetValue
      )
    {
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
      let originalSource = portAddress(for: sourceElementID),
      let target = portAddress(for: targetElementID),
      originalSource.portID.direction == .output,
      target.portID.direction == .input,
      originalSource.nodeID != target.nodeID
    else {
      return
    }
    guard case .valid = connectionValidation(source: originalSource, target: target) else {
      return
    }
    let source =
      automaticallySeparatedSource(
        source: originalSource,
        target: target
      ) ?? originalSource
    guard
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

  private func canAutomaticallySeparateSource(
    source: RoutingWorkspacePortAddress,
    sourceValue: RoutingGraphPortValue,
    targetValue: RoutingGraphPortValue
  ) -> Bool {
    guard
      let channel = RoutingPortCompatibility.separatedSourceChannel(
        source: sourceValue,
        target: targetValue
      ),
      let sourceNode = node(id: source.nodeID),
      sourceNode.value.audioSourceChannelPresentation == .aggregate
    else {
      return false
    }
    return runtimeCaptureFormats[source.nodeID].map { channel < $0.channelIDs.count } ?? true
  }

  private func automaticallySeparatedSource(
    source: RoutingWorkspacePortAddress,
    target: RoutingWorkspacePortAddress
  ) -> RoutingWorkspacePortAddress? {
    guard let sourceValue = portValue(at: source),
      let targetValue = portValue(at: target),
      canAutomaticallySeparateSource(
        source: source,
        sourceValue: sourceValue,
        targetValue: targetValue
      ),
      let channel = RoutingPortCompatibility.separatedSourceChannel(
        source: sourceValue,
        target: targetValue
      ),
      let index = nodes.firstIndex(where: { $0.id == source.nodeID })
    else {
      return nil
    }
    let channelCount =
      runtimeCaptureFormats[source.nodeID].map(\.channelIDs.count)
      ?? max(2, channel + 1)
    guard
      migrateAudioSourceEdges(
        nodeID: source.nodeID,
        from: nodes[index].value,
        to: .separate(channelCount: channelCount)
      ),
      let updatedValue = nodes[index].value.replacingAudioSourceChannelPresentation(
        .separate(channelCount: channelCount)
      )
    else {
      return nil
    }
    nodes[index].value = updatedValue
    resizeNode(at: index)
    return RoutingWorkspacePortAddress(
      nodeID: source.nodeID,
      portID: RoutingGraphPortID(direction: .output, channel: .channel(channel))
    )
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
    canvasBuildGeneration &+= 1
    defer { persistenceRevision &+= 1 }
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

  private func rebuildCanvasInBackground() async {
    pruneEdgesWithMissingPorts()
    canvasBuildGeneration &+= 1
    persistenceRevision &+= 1
    let generation = canvasBuildGeneration
    let workspaceID = id
    let nodeSnapshot = nodes
    let edgeSnapshot = edges
    do {
      let build = try await RoutingCanvasContentBuilder.buildInBackground(
        workspaceID: workspaceID,
        nodes: nodeSnapshot,
        edges: edgeSnapshot
      )
      guard generation == canvasBuildGeneration else { return }
      canvasContent = build.content
      accessibilitySnapshot = build.accessibilitySnapshot
      buildFailureDescription = nil
    } catch {
      guard generation == canvasBuildGeneration else { return }
      buildFailureDescription = String(describing: error)
    }
  }

  private func appendNode(
    id: UUID,
    value: RoutingNodeValue,
    centeredAt worldPoint: CGPoint
  ) {
    precondition(worldPoint.x.isFinite && worldPoint.y.isFinite)
    precondition(!nodes.contains { $0.id == id })
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
    let nativeMaximumChannelCount =
      formats.map { normalizedRuntimeChannelCount($0.1.channelIDs.count) }.max() ?? 0
    let requestedChannelCount =
      (configuration.channelSelection.requestedChannels.max() ?? 0) + 1
    let automaticChannelCount = preferredSeparateChannelCount ?? nativeMaximumChannelCount
    let maximumChannelCount = min(
      nativeMaximumChannelCount,
      max(automaticChannelCount, requestedChannelCount)
    )
    guard maximumChannelCount > 0 else {
      return false
    }

    configuration.mode = .separate
    configuration.availableChannelCount = maximumChannelCount
    nodes[visualizerIndex].value = .visualizer(configuration: configuration)
    resizeNode(at: visualizerIndex)

    let selectedChannels = configuration.normalizedSelectedChannels
    edges.removeAll { $0.target.nodeID == visualizerID }
    for (sourceID, format) in formats {
      let nativeChannelCount = normalizedRuntimeChannelCount(format.channelIDs.count)
      let exposedChannelCount = min(
        nativeChannelCount,
        (selectedChannels.max() ?? 0) + 1
      )
      guard let sourceIndex = nodes.firstIndex(where: { $0.id == sourceID }),
        let updated = nodes[sourceIndex].value.replacingAudioSourceChannelPresentation(
          .separate(channelCount: exposedChannelCount)
        )
      else {
        continue
      }
      nodes[sourceIndex].value = updated
      resizeNode(at: sourceIndex)
      for channel in selectedChannels where channel < nativeChannelCount {
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

  nonisolated private static func isValidPersistedFrame(_ frame: CGRect) -> Bool {
    frame.origin.x.isFinite
      && frame.origin.y.isFinite
      && frame.width.isFinite
      && frame.height.isFinite
      && frame.width > 0
      && frame.height > 0
  }
}
