import AppKit
import FlowingDayCanvas
import FlowingDayControls
import FlowingDayGraphCanvas
import FlowingDayGraphComposition
import RilliyaCore
import RilliyaDSP
import RilliyaFilePlayback
import RilliyaFileWriting
import RilliyaVirtualAudio
import SwiftUI
import UniformTypeIdentifiers

private enum RoutingPaletteItem: String, CaseIterable, Codable, Identifiable, Transferable {
  case applicationAudio = "moe.uwucocoa.rilliya.node.application-audio"
  case inputAudio = "moe.uwucocoa.rilliya.node.input-audio"
  case systemOutput = "moe.uwucocoa.rilliya.node.system-output"
  case virtualOutput = "moe.uwucocoa.rilliya.node.virtual-output"
  case outputAudio = "moe.uwucocoa.rilliya.node.output-audio"
  case virtualInput = "moe.uwucocoa.rilliya.node.virtual-input"
  case visualizer = "moe.uwucocoa.rilliya.node.visualizer"
  case audioMixer = "moe.uwucocoa.rilliya.node.audio-mixer"
  case gain = "moe.uwucocoa.rilliya.node.gain"
  case channelRouter = "moe.uwucocoa.rilliya.node.channel-router"
  case peakLevel = "moe.uwucocoa.rilliya.node.peak-level"
  case signalGenerator = "moe.uwucocoa.rilliya.node.signal-generator"
  case filePlayback = "moe.uwucocoa.rilliya.node.file-playback"
  case fileOutput = "moe.uwucocoa.rilliya.node.file-output"
  case networkSend = "moe.uwucocoa.rilliya.node.network-send"
  case networkReceive = "moe.uwucocoa.rilliya.node.network-receive"
  case delay = "moe.uwucocoa.rilliya.node.delay"
  case noiseGate = "moe.uwucocoa.rilliya.node.noise-gate"
  case compressor = "moe.uwucocoa.rilliya.node.compressor"

  var id: String { rawValue }

  var kind: RoutingNodeKind {
    switch self {
    case .applicationAudio: .applicationAudio
    case .inputAudio: .inputAudio
    case .systemOutput: .systemOutput
    case .virtualOutput: .virtualOutput
    case .outputAudio: .outputAudio
    case .virtualInput: .virtualInput
    case .visualizer: .visualizer
    case .audioMixer: .audioMixer
    case .gain: .gain
    case .channelRouter: .channelRouter
    case .peakLevel: .peakLevel
    case .signalGenerator: .signalGenerator
    case .filePlayback: .filePlayback
    case .fileOutput: .fileOutput
    case .networkSend: .networkSend
    case .networkReceive: .networkReceive
    case .delay: .delay
    case .noiseGate: .noiseGate
    case .compressor: .compressor
    }
  }

  var title: String { kind.title }

  var subtitle: String {
    switch self {
    case .applicationAudio: "Capture an app output"
    case .inputAudio: "Capture an input device"
    case .systemOutput: "Capture an output device"
    case .virtualOutput: "Receive audio from other applications"
    case .outputAudio: "Play through an output device"
    case .virtualInput: "Expose routed audio to other applications"
    case .visualizer: "Inspect routed channels"
    case .audioMixer: "Mix routed channel levels"
    case .gain: "Adjust level and polarity"
    case .channelRouter: "Reorder and duplicate channels"
    case .peakLevel: "Measure the strongest sample"
    case .signalGenerator: "Create tones and colored noise"
    case .filePlayback: "Stream a local audio file"
    case .fileOutput: "Record routed audio to a file"
    case .networkSend: "Send PCM to a trusted LAN peer"
    case .networkReceive: "Receive PCM from a trusted LAN peer"
    case .delay: "Add time and feedback"
    case .noiseGate: "Attenuate quiet passages"
    case .compressor: "Control dynamics and peaks"
    }
  }

  var category: RoutingPaletteCategory {
    switch self {
    case .applicationAudio, .inputAudio, .systemOutput, .virtualOutput, .signalGenerator,
      .filePlayback, .networkReceive:
      .sources
    case .outputAudio, .virtualInput, .fileOutput, .networkSend:
      .destinations
    case .audioMixer, .gain, .channelRouter:
      .routing
    case .visualizer, .peakLevel:
      .measurement
    case .delay, .noiseGate, .compressor:
      .processing
    }
  }

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .plainText)
  }
}

private enum RoutingPaletteCategory: String, CaseIterable, Identifiable {
  case sources
  case destinations
  case routing
  case measurement
  case processing

  var id: String { rawValue }

  var title: String {
    switch self {
    case .sources: "Sources"
    case .destinations: "Destinations"
    case .routing: "Routing & Level"
    case .measurement: "Measurement"
    case .processing: "Dynamics & Effects"
    }
  }

  var items: [RoutingPaletteItem] {
    RoutingPaletteItem.allCases.filter { $0.category == self }
  }
}

private struct RoutingDropPreviewState: Identifiable, Equatable {
  let id: UUID
  let item: RoutingPaletteItem
  let location: CGPoint
  var isCommitted: Bool
}

private struct RoutingCanvasPaletteDropDelegate: DropDelegate {
  @Binding var isTargeted: Bool
  let currentItem: RoutingPaletteItem?
  let hover: (RoutingPaletteItem, CGPoint) -> Void
  let exit: () -> Void
  let commit: (RoutingPaletteItem, CGPoint) -> Void

  func validateDrop(info: DropInfo) -> Bool {
    !info.itemProviders(for: [.plainText]).isEmpty
  }

  func dropEntered(info: DropInfo) {
    isTargeted = true
    loadItem(from: info) { item in
      hover(item, info.location)
    }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? {
    isTargeted = true
    if let currentItem {
      hover(currentItem, info.location)
    }
    return DropProposal(operation: .copy)
  }

  func dropExited(info: DropInfo) {
    isTargeted = false
    exit()
  }

  func performDrop(info: DropInfo) -> Bool {
    isTargeted = false
    if let currentItem {
      commit(currentItem, info.location)
      return true
    }
    guard !info.itemProviders(for: [.plainText]).isEmpty else { return false }
    loadItem(from: info) { item in
      commit(item, info.location)
    }
    return true
  }

  private func loadItem(
    from info: DropInfo,
    completion: @escaping @MainActor (RoutingPaletteItem) -> Void
  ) {
    guard let provider = info.itemProviders(for: [.plainText]).first else { return }
    provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) {
      data,
      _ in
      guard let data,
        let item = try? JSONDecoder().decode(RoutingPaletteItem.self, from: data)
      else { return }
      Task { @MainActor in
        completion(item)
      }
    }
  }
}

enum RoutingNodePaletteMetrics {
  static let outerWidth: CGFloat = 286
  static let outerLeadingInset = NativeWindowChrome.contentEdgeInset
  static let outerTrailingInset: CGFloat = 10
  static let outerTopInset = NativeWindowChrome.contentEdgeInset
  static let outerBottomInset = NativeWindowChrome.contentEdgeInset
  static let panelCornerRadius = NativeWindowChrome.visualWindowCornerRadius
  static let panelHorizontalPadding: CGFloat = 14
  static let panelTopPadding: CGFloat = 34
  static let panelBottomPadding: CGFloat = 14
  static let scrollIndicatorTrailingOffset = panelHorizontalPadding
  static let cardHoverOutset: CGFloat = 2
  static let scrollIndicatorVerticalInset = panelCornerRadius / 2
  static let panelBackgroundWidth = outerWidth - outerLeadingInset - outerTrailingInset
  static let panelContentWidth = panelBackgroundWidth - panelHorizontalPadding * 2
}

struct RoutingCanvasView: View {
  let workspace: RoutingWorkspaceModel
  let settings: RilliyaSettings
  let applicationCatalog: InstalledApplicationCatalogController
  let audioCatalog: AudioCatalogController
  let iconResolver: NSWorkspaceInstalledApplicationIconResolver
  let captureController: RoutingCaptureController
  let inputCaptureController: RoutingInputCaptureController
  let outputCaptureController: RoutingOutputCaptureController
  let filePlaybackController: RoutingFilePlaybackController
  let fileOutputController: RoutingFileOutputController
  let networkSendController: RoutingNetworkSendController
  let networkReceiveController: RoutingNetworkReceiveController
  let outputController: RoutingAudioOutputController
  let virtualAudioController: RilliyaVirtualAudioController
  let sessionID: FlowingGraphCanvasSessionID
  let isWorkflowRunning: Bool

  @Binding var session: FlowingGraphCanvasSessionState<RoutingCanvasSchema>
  let isMiniMapVisible: Bool
  let setMiniMapVisible: (Bool) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isDropTargeted = false
  @State private var dropPreview: RoutingDropPreviewState?
  @State private var dropTask: Task<Void, Never>?
  @State private var metalSceneTopologyCache = RoutingMetalSceneTopologyCache()
  @State private var expandedNodeColorPickerID: UUID?

  var body: some View {
    ZStack {
      if let content = workspace.canvasContent {
        canvas(content)
      } else {
        FlowingPalette.canvas
      }

      if workspace.nodes.isEmpty {
        emptyWorkspace
      }

      if let failure = workspace.buildFailureDescription {
        FlowingCanvasViewportOverlay(
          alignment: .topLeading,
          insets: EdgeInsets(top: 18, leading: 18, bottom: 0, trailing: 0)
        ) {
          FlowingCallout(
            failure,
            title: "Canvas unavailable",
            systemImage: "exclamationmark.triangle",
            tone: .critical
          )
          .frame(maxWidth: 360)
        }
      }

      if let dropPreview {
        RoutingCanvasDropPreview(
          item: dropPreview.item,
          isExpanded: true,
          accent: settings.resolvedAccentID(for: dropPreview.item.kind).accent
        )
        .position(dropPreview.location)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
    }
    .onDrop(
      of: [.plainText],
      delegate: RoutingCanvasPaletteDropDelegate(
        isTargeted: $isDropTargeted,
        currentItem: dropPreview?.isCommitted == false ? dropPreview?.item : nil,
        hover: updateDropPreview,
        exit: cancelDropPreview,
        commit: beginDrop
      )
    )
    .onDisappear {
      dropTask?.cancel()
    }
    .onChange(of: selectedWorkspaceNodeID) { oldValue, newValue in
      guard oldValue != newValue else { return }
      expandedNodeColorPickerID = nil
    }
  }

  private func canvas(_ content: RoutingCanvasContent) -> some View {
    FlowingGraphCanvas(
      content: content,
      sessionID: sessionID,
      session: $session,
      configuration: FlowingGraphCanvasConfiguration(
        renderingBackend: .metal,
        canvas: FlowingCanvasConfiguration(
          initialZoom: 1,
          focusedZoom: 1.12,
          zoomRange: 0.3...3
        ),
        nodeDraggingMode: .single,
        nodeResizing: .disabled,
        connectionEditing: FlowingGraphCanvasConnectionEditingConfiguration(
          isEnabled: true,
          allowsReconnection: false
        ),
        snapping: FlowingGraphCanvasSnappingConfiguration(
          isEnabled: true,
          grid: FlowingGraphCanvasGridConfiguration(
            majorCellSize: CGSize(width: 24, height: 24)
          )
        ),
        rendersDefaultGuides: false,
        allowsArrangementCommands: false
      ),
      metalVisualAdapter: FlowingGraphCanvasMetalVisualAdapter { context in
        RoutingMetalViewport(
          context: context,
          scene: metalScene(for: context.content),
          inspectorID: selectedWorkspaceNodeID,
          inspector: AnyView(selectedNodeInspector),
          removeNodes: workspace.removeNodes,
          removeEdges: workspace.removeEdges,
          toggleEdgeEnabled: workspace.toggleEdgeEnabled,
          togglePortEnabled: workspace.togglePortEnabled,
          showNodeColorPicker: { nodeID in
            expandedNodeColorPickerID = nodeID
          },
          setAudioChannelGain: { nodeID, channelIndex, gainDecibels in
            workspace.setAudioChannelGain(
              gainDecibels,
              nodeID: nodeID,
              channelIndex: channelIndex
            )
          },
          toggleAudioChannelMuted: workspace.toggleAudioChannelMuted,
          showsDisabledPortCrosses: settings.showsDisabledPortCrosses,
          isMiniMapVisible: isMiniMapVisible,
          setMiniMapVisible: setMiniMapVisible
        )
      },
      accessibilitySnapshot: workspace.accessibilitySnapshot,
      contentInsets: EdgeInsets(top: 22, leading: 300, bottom: 22, trailing: 22),
      interactionPolicy: FlowingGraphCanvasInteractionPolicy(
        connectionPolicy: FlowingGraphCanvasConnectionPolicy(
          canBegin: workspace.canBeginConnection,
          validate: workspace.validateConnection
        )
      ),
      onIntent: workspace.send,
      background: { RoutingCanvasGrid(context: $0) },
      node: { node, context in
        Group {
          switch node.value {
          case .applicationAudio:
            ApplicationAudioNodeView(
              node: node,
              context: context,
              applicationCatalog: applicationCatalog,
              iconResolver: iconResolver
            )
            .zIndex(context.isSelected ? 2 : 1)
          case .inputAudio:
            InputAudioNodeView(node: node, context: context)
              .zIndex(context.isSelected ? 2 : 1)
          case .systemOutput:
            SystemOutputNodeView(node: node, context: context)
              .zIndex(context.isSelected ? 2 : 1)
          case .virtualOutput:
            VirtualAudioEndpointNodeView(
              node: node,
              context: context,
              direction: .output,
              isDriverAvailable: virtualAudioController.availability != .notInstalled
            )
            .zIndex(context.isSelected ? 2 : 1)
          case .outputAudio:
            OutputAudioNodeView(node: node, context: context)
              .zIndex(context.isSelected ? 2 : 1)
          case .virtualInput:
            VirtualAudioEndpointNodeView(
              node: node,
              context: context,
              direction: .input,
              isDriverAvailable: virtualAudioController.availability != .notInstalled
            )
            .zIndex(context.isSelected ? 2 : 1)
          case .visualizer(let configuration):
            VisualizerNodeView(
              configuration: configuration,
              snapshot: visualizerSnapshot(for: node),
              context: context
            )
            .zIndex(context.isSelected ? 2 : 1)
          case .audioMixer(let configuration):
            AudioMixerNodeView(
              configuration: configuration,
              context: context
            )
            .zIndex(context.isSelected ? 2 : 1)
          case .gain(let configuration):
            GainNodeView(configuration: configuration, context: context)
              .zIndex(context.isSelected ? 2 : 1)
          case .channelRouter(let configuration):
            ChannelRouterNodeView(configuration: configuration, context: context)
              .zIndex(context.isSelected ? 2 : 1)
          case .peakLevel:
            PeakLevelNodeView(
              signal: peakLevelSignal(for: node),
              context: context
            )
            .zIndex(context.isSelected ? 2 : 1)
          case .signalGenerator(let configuration):
            SignalGeneratorNodeView(configuration: configuration, context: context)
              .zIndex(context.isSelected ? 2 : 1)
          case .filePlayback(let configuration):
            FilePlaybackNodeView(configuration: configuration, context: context)
              .zIndex(context.isSelected ? 2 : 1)
          case .fileOutput(let configuration):
            FileOutputNodeView(configuration: configuration, context: context)
              .zIndex(context.isSelected ? 2 : 1)
          case .networkSend(let configuration):
            NetworkAudioNodeView(
              title: "Network Send",
              subtitle: "\(configuration.host):\(configuration.port)",
              sampleRate: configuration.sampleRate,
              channelCount: configuration.channelCount,
              systemImage: "paperplane.fill",
              context: context
            )
            .zIndex(context.isSelected ? 2 : 1)
          case .networkReceive(let configuration):
            NetworkAudioNodeView(
              title: "Network Receive",
              subtitle: "UDP \(configuration.port)",
              sampleRate: configuration.sampleRate,
              channelCount: configuration.channelCount,
              systemImage: "network",
              context: context
            )
            .zIndex(context.isSelected ? 2 : 1)
          case .delay(let configuration):
            DelayNodeView(configuration: configuration, context: context)
              .zIndex(context.isSelected ? 2 : 1)
          case .noiseGate(let configuration):
            NoiseGateNodeView(configuration: configuration, context: context)
              .zIndex(context.isSelected ? 2 : 1)
          case .compressor(let configuration):
            CompressorNodeView(configuration: configuration, context: context)
              .zIndex(context.isSelected ? 2 : 1)
          }
        }
        .flowingAccent(resolvedAccentID(for: node).accent)
      },
      edge: { _, context in
        FlowingGraphCanvasDefaultEdge(
          context: context,
          style: FlowingGraphCanvasDefaultEdgeStyle(
            color: FlowingAccent.fern.fill.opacity(0.62),
            selectedColor: FlowingAccent.fern.foreground
          )
        )
      },
      port: { RoutingAudioPortView(port: $0, context: $1) },
      decorations: { _ in EmptyView() },
      overlays: { _ in selectedNodeInspectorOverlay }
    )
    .focusEffectDisabled()
  }

  private func metalScene(for content: RoutingCanvasContent) -> RoutingMetalScene {
    _ = iconResolver.revision
    var supplements: [UUID: RoutingMetalNodeSupplement] = [:]
    let incomingEdgesByTargetNode = workspace.activeIncomingEdgesByTargetNode()
    let signalResolver = RoutingAudioSignalResolver(
      nodes: workspace.nodes,
      activeEdges: workspace.edges.filter(workspace.isEdgeActive),
      snapshotForNode: audioSnapshot
    )
    for node in workspace.nodes {
      switch node.value {
      case .applicationAudio(let selection, _):
        let state = captureController.state(for: node.id)
        let isCapturing: Bool
        let captureFormat: RoutingAudioCaptureFormat?
        switch state {
        case .starting:
          isCapturing = true
          captureFormat = nil
        case .running(let format):
          isCapturing = true
          captureFormat = RoutingAudioCaptureFormat(format)
        case .idle, .failed:
          isCapturing = false
          captureFormat = nil
        }
        supplements[node.id] = RoutingMetalNodeSupplement(
          isRunning: isRunning(selection),
          isCapturing: isCapturing,
          captureConsumerCount: captureController.consumerCount(for: node.id),
          visualizerSignal: nil,
          captureFormat: captureFormat,
          audioSourceMeters: audioSourceMeters(for: node),
          audioChannelControls: node.audioChannelControls,
          applicationIcon: applicationIcon(selection),
          captureState: state
        )
      case .inputAudio(let selection, _):
        let state = inputCaptureController.state(for: node.id)
        let isCapturing: Bool
        let captureFormat: RoutingAudioCaptureFormat?
        switch state {
        case .starting:
          isCapturing = true
          captureFormat = nil
        case .running(let format):
          isCapturing = true
          captureFormat = RoutingAudioCaptureFormat(format)
        case .idle, .failed:
          isCapturing = false
          captureFormat = nil
        }
        supplements[node.id] = RoutingMetalNodeSupplement(
          isRunning: isAvailable(selection),
          isCapturing: isCapturing,
          captureConsumerCount: inputCaptureController.consumerCount(for: node.id),
          visualizerSignal: nil,
          captureFormat: captureFormat,
          audioSourceMeters: audioSourceMeters(for: node),
          audioChannelControls: node.audioChannelControls,
          inputCaptureState: state
        )
      case .systemOutput(let selection, _):
        let state = outputCaptureController.state(for: node.id)
        let captureFormat: RoutingAudioCaptureFormat?
        switch state {
        case .running(let format):
          captureFormat = RoutingAudioCaptureFormat(format)
        case .idle, .starting, .failed:
          captureFormat = nil
        }
        supplements[node.id] = RoutingMetalNodeSupplement(
          isRunning: isOutputCaptureAvailable(selection),
          isCapturing: {
            switch state {
            case .starting, .running: true
            case .idle, .failed: false
            }
          }(),
          captureConsumerCount: outputCaptureController.consumerCount(for: node.id),
          visualizerSignal: nil,
          captureFormat: captureFormat,
          audioSourceMeters: audioSourceMeters(for: node),
          audioChannelControls: node.audioChannelControls,
          outputCaptureState: state
        )
      case .virtualOutput(let selection, _):
        let state = inputCaptureController.state(for: node.id)
        let captureFormat: RoutingAudioCaptureFormat?
        switch state {
        case .running(let format):
          captureFormat = RoutingAudioCaptureFormat(format)
        case .idle, .starting, .failed:
          captureFormat = nil
        }
        supplements[node.id] = RoutingMetalNodeSupplement(
          isRunning: isVirtualEndpointAvailable(selection, direction: .output),
          isCapturing: {
            switch state {
            case .starting, .running: true
            case .idle, .failed: false
            }
          }(),
          captureConsumerCount: inputCaptureController.consumerCount(for: node.id),
          visualizerSignal: nil,
          captureFormat: captureFormat,
          audioSourceMeters: audioSourceMeters(for: node),
          audioChannelControls: node.audioChannelControls,
          virtualAudioDriverAvailable: virtualAudioDriverAvailability,
          inputCaptureState: state
        )
      case .outputAudio(let selection, _):
        supplements[node.id] = RoutingMetalNodeSupplement(
          isRunning: isOutputAvailable(selection),
          isCapturing: false,
          captureConsumerCount: 0,
          visualizerSignal: nil,
          audioOutputState: outputController.state(for: node.id)
        )
      case .virtualInput(let selection, _):
        supplements[node.id] = RoutingMetalNodeSupplement(
          isRunning: isVirtualEndpointAvailable(selection, direction: .input),
          isCapturing: false,
          captureConsumerCount: 0,
          visualizerSignal: nil,
          audioOutputState: outputController.state(for: node.id),
          virtualAudioDriverAvailable: virtualAudioDriverAvailability
        )
      case .visualizer(let configuration):
        supplements[node.id] = RoutingMetalNodeSupplement(
          isRunning: false,
          isCapturing: false,
          captureConsumerCount: 0,
          visualizerSignal: RoutingVisualizerSignalBuilder.build(
            configuration: configuration,
            incomingEdges: incomingEdgesByTargetNode[node.id] ?? [],
            resolvedSignalsForSource: signalResolver.resolveOutput
          )
        )
      case .audioMixer(let configuration):
        let meters = (0..<configuration.channelCount).map { channelIndex in
          let signal = signalResolver.resolveOutput(
            RoutingWorkspacePortAddress(
              nodeID: node.id,
              portID: RoutingGraphPortID(
                direction: .output,
                channel: .channel(channelIndex)
              )
            )
          ).first
          return RoutingAudioChannelMeterSignal(
            channelIndex: channelIndex,
            rootMeanSquare: signal?.rootMeanSquare ?? 0,
            peak: signal?.peak ?? 0,
            isClipping: signal?.isClipping == true
          )
        }
        supplements[node.id] = RoutingMetalNodeSupplement(
          isRunning: false,
          isCapturing: false,
          captureConsumerCount: 0,
          visualizerSignal: nil,
          audioSourceMeters: meters,
          audioChannelControls: node.audioChannelControls
        )
      case .gain, .channelRouter:
        supplements[node.id] = .empty
      case .peakLevel:
        supplements[node.id] = RoutingMetalNodeSupplement(
          isRunning: false,
          isCapturing: false,
          captureConsumerCount: 0,
          visualizerSignal: nil,
          peakLevelSignal: RoutingPeakLevelSignalBuilder.build(
            incomingEdges: incomingEdgesByTargetNode[node.id] ?? [],
            resolvedSignalsForSource: signalResolver.resolveOutput
          )
        )
      case .signalGenerator:
        supplements[node.id] = .empty
      case .filePlayback:
        supplements[node.id] = RoutingMetalNodeSupplement(
          isRunning: false,
          isCapturing: false,
          captureConsumerCount: 0,
          visualizerSignal: nil,
          filePlaybackState: filePlaybackController.state(for: node.id)
        )
      case .fileOutput:
        supplements[node.id] = RoutingMetalNodeSupplement(
          isRunning: false,
          isCapturing: false,
          captureConsumerCount: 0,
          visualizerSignal: nil,
          fileOutputState: fileOutputController.state(for: node.id)
        )
      case .networkSend:
        supplements[node.id] = RoutingMetalNodeSupplement(
          isRunning: false,
          isCapturing: false,
          captureConsumerCount: 0,
          visualizerSignal: nil,
          networkSendState: networkSendController.state(for: node.id)
        )
      case .networkReceive:
        supplements[node.id] = RoutingMetalNodeSupplement(
          isRunning: false,
          isCapturing: false,
          captureConsumerCount: 0,
          visualizerSignal: nil,
          networkReceiveState: networkReceiveController.state(for: node.id)
        )
      case .delay:
        supplements[node.id] = .empty
      case .noiseGate:
        supplements[node.id] = .empty
      case .compressor:
        supplements[node.id] = .empty
      }
    }
    return RoutingMetalScene(
      topology: metalSceneTopologyCache.topology(for: content),
      supplements: supplements,
      accentIDs: Dictionary(
        uniqueKeysWithValues: workspace.nodes.map { ($0.id, resolvedAccentID(for: $0)) }
      ),
      connectionInformationLevel: settings.connectionInformationLevel
    )
  }

  private func resolvedAccentID(for node: RoutingWorkspaceNode) -> RoutingAccentID {
    RoutingNodeAccentResolver.resolve(
      nodeOverride: node.accentOverride,
      typeOverride: settings.nodeAccentOverride(for: node.value.kind),
      kind: node.value.kind
    )
  }

  private func resolvedAccentID(
    for node: FlowingGraphPresentationNode<RoutingCanvasSchema>
  ) -> RoutingAccentID {
    guard case .node(let nodeID) = node.address.elementID,
      let workspaceNode = workspace.node(id: nodeID)
    else {
      return settings.resolvedAccentID(for: node.value.kind)
    }
    return resolvedAccentID(for: workspaceNode)
  }

  private func isRunning(_ selection: RoutingApplicationSelection?) -> Bool {
    guard let selection else { return false }
    return applicationCatalog.state.snapshot?.items.contains { item in
      item.isRunning
        && canonicalApplicationURL(item.application.bundleURL)
          == canonicalApplicationURL(selection.applicationURL)
    } == true
  }

  private func applicationIcon(_ selection: RoutingApplicationSelection?) -> NSImage? {
    guard let selection,
      let application = applicationCatalog.state.snapshot?.items.first(where: {
        canonicalApplicationURL($0.application.bundleURL)
          == canonicalApplicationURL(selection.applicationURL)
      })?.application
    else { return nil }
    return iconResolver.cachedIcon(for: application)
  }

  private func isAvailable(_ selection: RoutingInputDeviceSelection?) -> Bool {
    guard let selection else { return false }
    return audioCatalog.state.snapshot?.inputDevices.contains {
      $0.id == selection.id && $0.isAlive
    } == true
  }

  private func isOutputAvailable(_ selection: RoutingOutputDeviceSelection?) -> Bool {
    guard let selection else { return false }
    return audioCatalog.state.snapshot?.outputDevices.contains {
      $0.id == selection.id && $0.isAlive
    } == true
  }

  private func isOutputCaptureAvailable(_ selection: RoutingOutputCaptureSelection?) -> Bool {
    let devices = audioCatalog.state.snapshot?.outputDevices ?? []
    switch selection {
    case .systemDefault:
      return devices.contains { $0.isAlive && $0.output?.isDefault == true }
    case .device(let selection):
      return devices.contains { $0.id == selection.id && $0.isAlive }
    case nil:
      return false
    }
  }

  private func isVirtualEndpointAvailable(
    _ selection: RoutingVirtualAudioEndpointSelection?,
    direction: VirtualAudioEndpointDirection
  ) -> Bool {
    guard let selection else { return false }
    return virtualAudioController.catalog.endpoint(id: selection.id)?.configuration.direction
      == direction
  }

  private var virtualAudioDriverAvailability: Bool? {
    switch virtualAudioController.availability {
    case .available: true
    case .notInstalled: false
    case nil: nil
    }
  }

  @ViewBuilder
  private var selectedNodeInspector: some View {
    if let nodeID = selectedWorkspaceNodeID,
      let node = workspace.node(id: nodeID)
    {
      VStack(spacing: 6) {
        selectedNodeInspectorContent(node: node)
        RoutingNodeColorOverrideCard(
          selection: node.accentOverride,
          inheritedAccentID: settings.resolvedAccentID(for: node.value.kind),
          isExpanded: Binding(
            get: { expandedNodeColorPickerID == node.id },
            set: { isExpanded in
              expandedNodeColorPickerID = isExpanded ? node.id : nil
            }
          ),
          setSelection: { workspace.setAccentOverride($0, for: node.id) }
        )
      }
      .flowingAccent(resolvedAccentID(for: node).accent)
      .frame(width: 330)
    }
  }

  private var selectedNodeInspectorOverlay: some View {
    FlowingCanvasViewportOverlay(
      alignment: .topTrailing,
      insets: EdgeInsets(top: 18, leading: 0, bottom: 0, trailing: 18)
    ) {
      selectedNodeInspector
    }
  }

  @ViewBuilder
  private func selectedNodeInspectorContent(node: RoutingWorkspaceNode) -> some View {
    switch node.value {
    case .applicationAudio(let selection, let channelPresentation):
      SelectedApplicationInspector(
        nodeID: node.id,
        selection: selection,
        channelPresentation: channelPresentation,
        isRouted: workspace.edges.contains { $0.isEnabled && $0.source.nodeID == node.id },
        applicationCatalog: applicationCatalog,
        iconResolver: iconResolver,
        captureController: captureController,
        channelControls: node.audioChannelControls,
        selectApplication: { selection in
          workspace.selectApplication(selection, for: node.id)
        },
        setChannelPresentation: { presentation in
          workspace.setApplicationChannelPresentation(presentation, for: node.id)
        },
        setChannelGain: { channelIndex, gainDecibels in
          workspace.setAudioChannelGain(
            gainDecibels,
            nodeID: node.id,
            channelIndex: channelIndex
          )
        },
        setChannelMuted: { channelIndex, isMuted in
          workspace.setAudioChannelMuted(
            isMuted,
            nodeID: node.id,
            channelIndex: channelIndex
          )
        }
      )
    case .inputAudio(let selection, let channelPresentation):
      SelectedInputAudioInspector(
        nodeID: node.id,
        selection: selection,
        channelPresentation: channelPresentation,
        isWorkflowRunning: isWorkflowRunning,
        isRouted: workspace.edges.contains { $0.isEnabled && $0.source.nodeID == node.id },
        audioCatalog: audioCatalog,
        captureController: inputCaptureController,
        channelControls: node.audioChannelControls,
        selectDevice: { selection in
          workspace.selectInputDevice(selection, for: node.id)
        },
        setChannelPresentation: { presentation in
          workspace.setInputDeviceChannelPresentation(presentation, for: node.id)
        },
        setChannelGain: { channelIndex, gainDecibels in
          workspace.setAudioChannelGain(
            gainDecibels,
            nodeID: node.id,
            channelIndex: channelIndex
          )
        },
        setChannelMuted: { channelIndex, isMuted in
          workspace.setAudioChannelMuted(
            isMuted,
            nodeID: node.id,
            channelIndex: channelIndex
          )
        }
      )
    case .systemOutput(let selection, let channelPresentation):
      SelectedSystemOutputInspector(
        nodeID: node.id,
        selection: selection,
        channelPresentation: channelPresentation,
        isWorkflowRunning: isWorkflowRunning,
        isRouted: workspace.edges.contains { $0.isEnabled && $0.source.nodeID == node.id },
        audioCatalog: audioCatalog,
        captureController: outputCaptureController,
        channelControls: node.audioChannelControls,
        selectOutput: { selection in
          workspace.selectSystemOutput(selection, for: node.id)
        },
        setChannelPresentation: { presentation in
          workspace.setSystemOutputChannelPresentation(presentation, for: node.id)
        },
        setChannelGain: { channelIndex, gainDecibels in
          workspace.setAudioChannelGain(
            gainDecibels,
            nodeID: node.id,
            channelIndex: channelIndex
          )
        },
        setChannelMuted: { channelIndex, isMuted in
          workspace.setAudioChannelMuted(
            isMuted,
            nodeID: node.id,
            channelIndex: channelIndex
          )
        }
      )
    case .virtualOutput(let selection, let channelPresentation):
      SelectedVirtualAudioEndpointInspector(
        direction: .output,
        selection: selection,
        channelPresentation: channelPresentation,
        controller: virtualAudioController,
        state: inputCaptureController.state(for: node.id),
        selectEndpoint: { selection in
          workspace.selectVirtualOutput(selection, for: node.id)
        },
        setChannelPresentation: { presentation in
          workspace.setVirtualOutputChannelPresentation(presentation, for: node.id)
        }
      )
    case .outputAudio(let selection, let channelPresentation):
      SelectedOutputAudioInspector(
        selection: selection,
        channelPresentation: channelPresentation,
        state: outputController.state(for: node.id),
        audioCatalog: audioCatalog,
        selectDevice: { selection in
          workspace.selectOutputDevice(selection, for: node.id)
        },
        setChannelPresentation: { presentation in
          workspace.setOutputDeviceChannelPresentation(presentation, for: node.id)
        }
      )
    case .virtualInput(let selection, let channelPresentation):
      SelectedVirtualAudioEndpointInspector(
        direction: .input,
        selection: selection,
        channelPresentation: channelPresentation,
        controller: virtualAudioController,
        state: nil,
        selectEndpoint: { selection in
          workspace.selectVirtualInput(selection, for: node.id)
        },
        setChannelPresentation: { presentation in
          workspace.setVirtualInputChannelPresentation(presentation, for: node.id)
        }
      )
    case .visualizer(let configuration):
      SelectedVisualizerInspector(configuration: configuration) { updated in
        workspace.configureVisualizer(updated, for: node.id)
      }
    case .audioMixer(let configuration):
      SelectedAudioMixerInspector(
        configuration: configuration,
        channelControls: node.audioChannelControls,
        updateConfiguration: { updated in
          workspace.configureAudioMixer(updated, for: node.id)
        },
        setChannelGain: { channelIndex, gainDecibels in
          workspace.setAudioChannelGain(
            gainDecibels,
            nodeID: node.id,
            channelIndex: channelIndex
          )
        },
        setChannelMuted: { channelIndex, isMuted in
          workspace.setAudioChannelMuted(
            isMuted,
            nodeID: node.id,
            channelIndex: channelIndex
          )
        }
      )
    case .gain(let configuration):
      SelectedGainInspector(configuration: configuration) { updated in
        workspace.configureGain(updated, for: node.id)
      }
    case .channelRouter(let configuration):
      SelectedChannelRouterInspector(configuration: configuration) { updated in
        workspace.configureChannelRouter(updated, for: node.id)
      }
    case .peakLevel:
      SelectedPeakLevelInspector(
        signal: RoutingPeakLevelSignalBuilder.build(
          incomingEdges: workspace.incomingEdges(for: node.id),
          resolvedSignalsForSource: audioSignalResolver.resolveOutput
        )
      )
    case .signalGenerator(let configuration):
      SelectedSignalGeneratorInspector(configuration: configuration) { updated in
        workspace.configureSignalGenerator(updated, for: node.id)
      }
    case .filePlayback(let configuration):
      SelectedFilePlaybackInspector(
        configuration: configuration,
        state: filePlaybackController.state(for: node.id),
        channelControls: node.audioChannelControls,
        onRetry: { filePlaybackController.retry(nodeID: node.id) },
        updateConfiguration: { updated in
          workspace.configureFilePlayback(updated, for: node.id)
        },
        setVolume: { gainDecibels in
          for channelIndex in 0..<(configuration.selection?.channelCount ?? 0) {
            workspace.setAudioChannelGain(
              gainDecibels,
              nodeID: node.id,
              channelIndex: channelIndex
            )
          }
        },
        setMuted: { isMuted in
          for channelIndex in 0..<(configuration.selection?.channelCount ?? 0) {
            workspace.setAudioChannelMuted(
              isMuted,
              nodeID: node.id,
              channelIndex: channelIndex
            )
          }
        }
      )
    case .fileOutput(let configuration):
      SelectedFileOutputInspector(
        configuration: configuration,
        state: fileOutputController.state(for: node.id),
        onRetry: { fileOutputController.retry(nodeID: node.id) },
        updateConfiguration: { updated in
          workspace.configureFileOutput(updated, for: node.id)
        }
      )
    case .networkSend(let configuration):
      SelectedNetworkSendInspector(
        configuration: configuration,
        state: networkSendController.state(for: node.id),
        onRetry: { networkSendController.retry(nodeID: node.id) },
        updateConfiguration: { updated in
          workspace.configureNetworkSend(updated, for: node.id)
        }
      )
    case .networkReceive(let configuration):
      SelectedNetworkReceiveInspector(
        configuration: configuration,
        state: networkReceiveController.state(for: node.id),
        onRetry: { networkReceiveController.retry(nodeID: node.id) },
        updateConfiguration: { updated in
          workspace.configureNetworkReceive(updated, for: node.id)
        }
      )
    case .delay(let configuration):
      SelectedDelayInspector(configuration: configuration) { updated in
        workspace.configureDelay(updated, for: node.id)
      }
    case .noiseGate(let configuration):
      SelectedNoiseGateInspector(configuration: configuration) { updated in
        workspace.configureNoiseGate(updated, for: node.id)
      }
    case .compressor(let configuration):
      SelectedCompressorInspector(configuration: configuration) { updated in
        workspace.configureCompressor(updated, for: node.id)
      }
    }
  }

  private func visualizerSnapshot(
    for node: FlowingGraphPresentationNode<RoutingCanvasSchema>
  ) -> RoutingVisualizerSignal? {
    guard case .node(let nodeID) = node.address.elementID,
      case .visualizer(let configuration) = node.value
    else {
      return nil
    }
    return RoutingVisualizerSignalBuilder.build(
      configuration: configuration,
      incomingEdges: workspace.incomingEdges(for: nodeID),
      resolvedSignalsForSource: audioSignalResolver.resolveOutput
    )
  }

  private func peakLevelSignal(
    for node: FlowingGraphPresentationNode<RoutingCanvasSchema>
  ) -> RoutingPeakLevelSignal? {
    guard case .node(let nodeID) = node.address.elementID,
      case .peakLevel = node.value
    else {
      return nil
    }
    return RoutingPeakLevelSignalBuilder.build(
      incomingEdges: workspace.incomingEdges(for: nodeID),
      resolvedSignalsForSource: audioSignalResolver.resolveOutput
    )
  }

  private func audioSnapshot(for nodeID: UUID) -> (any RoutingAudioMeterSnapshot)? {
    if let snapshot = captureController.snapshot(for: nodeID) {
      return snapshot
    }
    if let snapshot = inputCaptureController.snapshot(for: nodeID) {
      return snapshot
    }
    return outputCaptureController.snapshot(for: nodeID)
  }

  private var audioSignalResolver: RoutingAudioSignalResolver {
    RoutingAudioSignalResolver(
      nodes: workspace.nodes,
      activeEdges: workspace.edges.filter(workspace.isEdgeActive),
      snapshotForNode: audioSnapshot
    )
  }

  private func audioSourceMeters(
    for node: RoutingWorkspaceNode
  ) -> [RoutingAudioChannelMeterSignal] {
    guard case .separate(let channelCount) = node.value.audioSourceChannelPresentation else {
      return []
    }
    return RoutingAudioSourceMeterSignalBuilder.build(
      channelCount: channelCount,
      snapshot: audioSnapshot(for: node.id),
      controls: node.audioChannelControls
    )
  }

  private func selectNode(_ nodeID: UUID) {
    guard let elementID = workspace.elementID(for: nodeID) else { return }
    session.selection = [elementID]
    session.focusedElementID = elementID
  }

  private func beginDrop(_ item: RoutingPaletteItem, at location: CGPoint) {
    dropTask?.cancel()
    let previewID =
      dropPreview?.item == item
      ? dropPreview?.id ?? UUID()
      : UUID()
    let worldPoint = session.viewport.transform.removing(from: location)
    dropPreview = RoutingDropPreviewState(
      id: previewID,
      item: item,
      location: location,
      isCommitted: true
    )

    dropTask = Task { @MainActor in
      await Task.yield()
      guard !Task.isCancelled, dropPreview?.id == previewID else { return }

      let nodeID = await workspace.addNode(of: item.kind, centeredAt: worldPoint)
      selectNode(nodeID)

      try? await Task.sleep(for: reduceMotion ? .milliseconds(40) : .milliseconds(120))
      guard !Task.isCancelled, dropPreview?.id == previewID else { return }
      withAnimation(.easeOut(duration: reduceMotion ? 0.06 : 0.12)) {
        dropPreview = nil
      }
    }
  }

  private func updateDropPreview(_ item: RoutingPaletteItem, at location: CGPoint) {
    guard isDropTargeted else { return }
    if let dropPreview, dropPreview.item == item, !dropPreview.isCommitted {
      self.dropPreview = RoutingDropPreviewState(
        id: dropPreview.id,
        item: item,
        location: location,
        isCommitted: false
      )
      return
    }
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
      dropPreview = RoutingDropPreviewState(
        id: UUID(),
        item: item,
        location: location,
        isCommitted: false
      )
    }
  }

  private func cancelDropPreview() {
    guard dropPreview?.isCommitted != true else { return }
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.1)) {
      dropPreview = nil
    }
  }

  private var selectedWorkspaceNodeID: UUID? {
    guard session.selection.count == 1,
      let elementID = session.selection.first,
      let presentationNode = workspace.canvasContent?.presentation.nodes.first(where: {
        $0.id == elementID
      }),
      case .node(let nodeID) = presentationNode.address.elementID
    else {
      return nil
    }
    return nodeID
  }

  private var emptyWorkspace: some View {
    FlowingCard(
      alignment: .center,
      spacing: 10,
      contentInsets: EdgeInsets(top: 26, leading: 30, bottom: 26, trailing: 30)
    ) {
      FlowingEmptyState(systemImage: "point.3.connected.trianglepath.dotted") {
        VStack(spacing: 5) {
          Text("Build your first route")
            .font(.headline)
            .foregroundStyle(FlowingPalette.ink)
          Text("Drag Application Audio from the left panel onto the canvas.")
            .multilineTextAlignment(.center)
        }
      }
    }
    .frame(maxWidth: 390)
    .allowsHitTesting(false)
  }
}

struct RoutingNodePaletteView<WorkflowNavigation: View>: View {

  let applicationCatalog: InstalledApplicationCatalogController
  let settings: RilliyaSettings
  let allowsClickInsertion: Bool
  let insertApplicationAudio: () -> Void
  let insertInputAudio: () -> Void
  let insertSystemOutput: () -> Void
  let insertVirtualOutput: () -> Void
  let insertOutputAudio: () -> Void
  let insertVirtualInput: () -> Void
  let insertVisualizer: () -> Void
  let insertAudioMixer: () -> Void
  let insertGain: () -> Void
  let insertChannelRouter: () -> Void
  let insertPeakLevel: () -> Void
  let insertSignalGenerator: () -> Void
  let insertFilePlayback: () -> Void
  let insertFileOutput: () -> Void
  let insertNetworkSend: () -> Void
  let insertNetworkReceive: () -> Void
  let insertDelay: () -> Void
  let insertNoiseGate: () -> Void
  let insertCompressor: () -> Void
  let workflowNavigation: WorkflowNavigation

  @State private var searchText = ""

  init(
    applicationCatalog: InstalledApplicationCatalogController,
    settings: RilliyaSettings,
    allowsClickInsertion: Bool,
    insertApplicationAudio: @escaping () -> Void,
    insertInputAudio: @escaping () -> Void,
    insertSystemOutput: @escaping () -> Void,
    insertVirtualOutput: @escaping () -> Void,
    insertOutputAudio: @escaping () -> Void,
    insertVirtualInput: @escaping () -> Void,
    insertVisualizer: @escaping () -> Void,
    insertAudioMixer: @escaping () -> Void,
    insertGain: @escaping () -> Void,
    insertChannelRouter: @escaping () -> Void,
    insertPeakLevel: @escaping () -> Void,
    insertSignalGenerator: @escaping () -> Void,
    insertFilePlayback: @escaping () -> Void,
    insertFileOutput: @escaping () -> Void,
    insertNetworkSend: @escaping () -> Void,
    insertNetworkReceive: @escaping () -> Void,
    insertDelay: @escaping () -> Void,
    insertNoiseGate: @escaping () -> Void,
    insertCompressor: @escaping () -> Void,
    @ViewBuilder workflowNavigation: () -> WorkflowNavigation
  ) {
    self.applicationCatalog = applicationCatalog
    self.settings = settings
    self.allowsClickInsertion = allowsClickInsertion
    self.insertApplicationAudio = insertApplicationAudio
    self.insertInputAudio = insertInputAudio
    self.insertSystemOutput = insertSystemOutput
    self.insertVirtualOutput = insertVirtualOutput
    self.insertOutputAudio = insertOutputAudio
    self.insertVirtualInput = insertVirtualInput
    self.insertVisualizer = insertVisualizer
    self.insertAudioMixer = insertAudioMixer
    self.insertGain = insertGain
    self.insertChannelRouter = insertChannelRouter
    self.insertPeakLevel = insertPeakLevel
    self.insertSignalGenerator = insertSignalGenerator
    self.insertFilePlayback = insertFilePlayback
    self.insertFileOutput = insertFileOutput
    self.insertNetworkSend = insertNetworkSend
    self.insertNetworkReceive = insertNetworkReceive
    self.insertDelay = insertDelay
    self.insertNoiseGate = insertNoiseGate
    self.insertCompressor = insertCompressor
    self.workflowNavigation = workflowNavigation()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      Divider()
        .overlay(FlowingPalette.hairline)
        .padding(.vertical, 12)

      workflowNavigation

      Divider()
        .overlay(FlowingPalette.hairline)
        .padding(.vertical, 12)

      GeometryReader { geometry in
        ScrollView {
          VStack(spacing: 18) {
            RoutingPaletteSection(
              "Audio Nodes",
              footer:
                "Drag a node onto the canvas. Search matches every category."
            ) {
              FlowingTextField(
                "Search audio nodes",
                text: $searchText,
                placeholder: "Search nodes",
                systemImage: "magnifyingglass",
                emphasis: .standard
              )
            }

            paletteResults

            catalogIssue
              .padding(.top, 14)
          }
          .frame(width: RoutingNodePaletteMetrics.panelContentWidth, alignment: .leading)
          .frame(minHeight: geometry.size.height, alignment: .top)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(NativeWindowDragRegion().accessibilityHidden(true))
        }
        .contentMargins(
          .vertical,
          RoutingNodePaletteMetrics.scrollIndicatorVerticalInset,
          for: .scrollIndicators
        )
        .scrollContentBackground(.hidden)
        .background(Color.clear)
      }
      .frame(
        width: RoutingNodePaletteMetrics.panelContentWidth
          + RoutingNodePaletteMetrics.scrollIndicatorTrailingOffset,
        alignment: .leading
      )
      .frame(maxHeight: .infinity, alignment: .top)
      .frame(width: RoutingNodePaletteMetrics.panelContentWidth, alignment: .leading)
      .layoutPriority(1)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(.horizontal, RoutingNodePaletteMetrics.panelHorizontalPadding)
    .padding(.bottom, RoutingNodePaletteMetrics.panelBottomPadding)
    .padding(.top, RoutingNodePaletteMetrics.panelTopPadding)
    .background {
      ZStack {
        RoundedRectangle(
          cornerRadius: RoutingNodePaletteMetrics.panelCornerRadius,
          style: .continuous
        )
        .fill(FlowingPalette.control.opacity(0.94))
        NativeWindowDragRegion()
          .clipShape(
            RoundedRectangle(
              cornerRadius: RoutingNodePaletteMetrics.panelCornerRadius,
              style: .continuous
            )
          )
          .accessibilityHidden(true)
      }
    }
    .overlay {
      RoundedRectangle(
        cornerRadius: RoutingNodePaletteMetrics.panelCornerRadius,
        style: .continuous
      )
      .strokeBorder(FlowingPalette.hairline)
    }
    .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
    .padding(.leading, RoutingNodePaletteMetrics.outerLeadingInset)
    .padding(.trailing, RoutingNodePaletteMetrics.outerTrailingInset)
    .padding(.top, RoutingNodePaletteMetrics.outerTopInset)
    .padding(.bottom, RoutingNodePaletteMetrics.outerBottomInset)
    .frame(width: RoutingNodePaletteMetrics.outerWidth)
    .background(Color.clear)
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Rilliya")
          .font(.system(size: 23, weight: .semibold, design: .rounded))
          .foregroundStyle(FlowingPalette.ink)
        Text("Audio routing workspace")
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }
      .allowsHitTesting(false)

      Spacer(minLength: 8)

    }
    .background(NativeWindowDragRegion().accessibilityHidden(true))
  }

  @ViewBuilder
  private var catalogIssue: some View {
    if let errorMessage = applicationCatalog.state.rootErrorMessage {
      FlowingCallout(
        errorMessage,
        title: "Applications unavailable",
        systemImage: "exclamationmark.triangle",
        tone: .warning
      )
    }
  }

  private func accent(for kind: RoutingNodeKind) -> FlowingAccent {
    settings.resolvedAccentID(for: kind).accent
  }

  @ViewBuilder
  private var paletteResults: some View {
    ForEach(RoutingPaletteCategory.allCases) { category in
      let matchingItems = category.items.filter(matchesSearch)
      if !matchingItems.isEmpty {
        RoutingPaletteSection(category.title) {
          VStack(spacing: 10) {
            ForEach(matchingItems) { item in
              paletteItem(item)
            }
          }
        }
      }
    }
    if !hasPaletteResults {
      FlowingEmptyState(systemImage: "magnifyingglass") {
        Text("No matching audio nodes")
      }
      .padding(.vertical, 18)
      .allowsHitTesting(false)
    }
  }

  private var hasPaletteResults: Bool {
    RoutingPaletteItem.allCases.contains(where: matchesSearch)
  }

  private func matchesSearch(_ item: RoutingPaletteItem) -> Bool {
    RoutingPaletteSearch.matches(
      query: searchText,
      title: item.title,
      description: item.subtitle
    )
  }

  private func paletteItem(_ item: RoutingPaletteItem) -> some View {
    let accent = accent(for: item.kind)
    return RoutingPaletteNodeItem(
      item: item,
      title: item.title,
      subtitle: item.subtitle,
      systemImage: item.kind.systemImage,
      foreground: accent.foreground,
      veil: accent.veil,
      allowsClickInsertion: allowsClickInsertion,
      action: action(for: item)
    )
  }

  private func action(for item: RoutingPaletteItem) -> () -> Void {
    switch item {
    case .applicationAudio: insertApplicationAudio
    case .inputAudio: insertInputAudio
    case .systemOutput: insertSystemOutput
    case .virtualOutput: insertVirtualOutput
    case .outputAudio: insertOutputAudio
    case .virtualInput: insertVirtualInput
    case .visualizer: insertVisualizer
    case .audioMixer: insertAudioMixer
    case .gain: insertGain
    case .channelRouter: insertChannelRouter
    case .peakLevel: insertPeakLevel
    case .signalGenerator: insertSignalGenerator
    case .filePlayback: insertFilePlayback
    case .fileOutput: insertFileOutput
    case .networkSend: insertNetworkSend
    case .networkReceive: insertNetworkReceive
    case .delay: insertDelay
    case .noiseGate: insertNoiseGate
    case .compressor: insertCompressor
    }
  }
}

private struct RoutingPaletteNodeItem: View {
  let item: RoutingPaletteItem
  let title: String
  let subtitle: String
  let systemImage: String
  let foreground: Color
  let veil: Color
  let allowsClickInsertion: Bool
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    interactiveCard
      .draggable(item) {
        RoutingPaletteDragPreview(
          title: title,
          subtitle: subtitle,
          systemImage: systemImage,
          foreground: foreground,
          veil: veil
        )
      }
      .onHover { isHovering = $0 }
      .scaleEffect(isHovering ? 1.012 : 1)
      .padding(.horizontal, RoutingNodePaletteMetrics.cardHoverOutset)
      .animation(.easeOut(duration: 0.14), value: isHovering)
      .help(
        allowsClickInsertion
          ? "Drag or click to add \(title)" : "Drag \(title) onto the canvas"
      )
      .accessibilityHint(
        allowsClickInsertion
          ? "Drag to the canvas or press to add in the visible workspace"
          : "Drag this node onto the canvas"
      )
  }

  @ViewBuilder
  private var interactiveCard: some View {
    if allowsClickInsertion {
      Button(action: action) {
        card
      }
      .buttonStyle(.plain)
    } else {
      card
    }
  }

  private var card: some View {
    FlowingCard(
      spacing: 0,
      contentInsets: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
    ) {
      HStack(spacing: 11) {
        Image(systemName: systemImage)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(foreground)
          .frame(width: 32, height: 32)
          .background(
            veil,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
          )

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(FlowingPalette.ink)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(FlowingPalette.muted)
        }

        Spacer(minLength: 6)
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(isHovering ? foreground.opacity(0.28) : Color.clear)
    }
    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

private struct RoutingPaletteDragPreview: View {
  let title: String
  let subtitle: String
  let systemImage: String
  let foreground: Color
  let veil: Color

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(foreground)
        .frame(width: 32, height: 32)
        .background(veil, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.callout.weight(.semibold))
          .foregroundStyle(FlowingPalette.ink)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }
    }
    .padding(12)
    .background(
      FlowingPalette.control.opacity(0.98),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(foreground.opacity(0.32))
    }
    .shadow(color: .black.opacity(0.1), radius: 12, y: 5)
  }
}

private struct RoutingCanvasDropPreview: View {
  let item: RoutingPaletteItem
  let isExpanded: Bool
  let accent: FlowingAccent

  private var presentation: (String, String, String) {
    switch item {
    case .applicationAudio:
      return (
        "Application Audio",
        "Choose an application",
        "macwindow.on.rectangle"
      )
    case .inputAudio:
      return (
        "Input Audio",
        "Choose an input device",
        "waveform.badge.mic"
      )
    case .systemOutput:
      return (
        "System Output",
        "Choose an output source",
        "speaker.wave.2.circle"
      )
    case .virtualOutput:
      return (
        "Virtual Output",
        "Choose a virtual output",
        "waveform.and.mic"
      )
    case .outputAudio:
      return (
        "Output Audio",
        "Choose an output device",
        "speaker.wave.2"
      )
    case .virtualInput:
      return (
        "Virtual Input",
        "Choose a virtual input",
        "mic.badge.plus"
      )
    case .visualizer:
      return (
        "Visualizer",
        "Waiting for audio input",
        "waveform"
      )
    case .audioMixer:
      return (
        "Audio Mixer",
        "Mix routed channel levels",
        "slider.horizontal.3"
      )
    case .gain:
      return (
        "Gain",
        "0.0 dB",
        "plusminus"
      )
    case .channelRouter:
      return (
        "Channel Router",
        "2 inputs · 2 outputs",
        "arrow.left.arrow.right"
      )
    case .peakLevel:
      return (
        "Peak Level",
        "Waiting for audio input",
        "gauge.with.dots.needle.50percent"
      )
    case .signalGenerator:
      return (
        "Signal Generator",
        "Sine · 440 Hz",
        "waveform.path"
      )
    case .filePlayback:
      return (
        "File Playback",
        "Choose an audio file",
        "music.note.list"
      )
    case .fileOutput:
      return (
        "File Output",
        "Choose a destination",
        "square.and.arrow.down"
      )
    case .networkSend:
      return (
        "Network Send",
        "127.0.0.1:48620",
        "paperplane.fill"
      )
    case .networkReceive:
      return (
        "Network Receive",
        "UDP 48620",
        "network"
      )
    case .delay:
      return (
        "Delay",
        "250 ms · 50% wet",
        "clock.arrow.trianglehead.counterclockwise.rotate.90"
      )
    case .noiseGate:
      return (
        "Noise Gate",
        "−40 dBFS threshold",
        "waveform.badge.minus"
      )
    case .compressor:
      return (
        "Compressor",
        "−18 dBFS · 4:1",
        "arrow.down.right.and.arrow.up.left"
      )
    }
  }

  var body: some View {
    let (title, subtitle, systemImage) = presentation
    VStack(alignment: .leading, spacing: isExpanded ? 11 : 0) {
      HStack(spacing: 11) {
        Image(systemName: systemImage)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(accent.foreground)
          .frame(width: 38, height: 38)
          .background(accent.veil, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(FlowingPalette.muted)
          Text(subtitle)
            .font(.callout.weight(.semibold))
            .foregroundStyle(FlowingPalette.ink)
            .lineLimit(1)
        }
      }

      if isExpanded {
        Text(
          item == .applicationAudio || item == .inputAudio || item == .systemOutput
            || item == .virtualOutput || item == .outputAudio || item == .virtualInput
            ? "Select this node to configure" : "Waiting for audio input"
        )
        .font(.caption)
        .foregroundStyle(FlowingPalette.muted)
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(
          FlowingPalette.field,
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .transition(.opacity)
      }
    }
    .padding(14)
    .frame(
      width: isExpanded ? RoutingCanvasMetrics.baseNodeSize.width : 218,
      height: isExpanded ? RoutingCanvasMetrics.baseNodeSize.height : 62,
      alignment: .topLeading
    )
    .background(
      FlowingPalette.control.opacity(0.98),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(accent.foreground.opacity(0.36))
    }
    .shadow(color: .black.opacity(0.11), radius: 12, y: 5)
    .opacity(isExpanded ? 0 : 0.98)
  }
}

private struct RoutingPaletteSection<Content: View>: View {
  let title: String
  let footer: String?
  let content: Content

  init(
    _ title: String,
    footer: String? = nil,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.footer = footer
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title.uppercased())
        .font(.caption.weight(.semibold))
        .tracking(0.7)
        .foregroundStyle(FlowingPalette.faint)
        .padding(.leading, 4)
        .padding(.bottom, 7)
        .allowsHitTesting(false)

      content

      if let footer {
        Text(footer)
          .font(.caption)
          .foregroundStyle(FlowingPalette.faint)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 12)
          .padding(.top, 7)
          .allowsHitTesting(false)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.clear)
  }
}

private struct RoutingCanvasGrid: View {
  let context: FlowingCanvasRenderContext

  var body: some View {
    let levels = FlowingCanvasGridLevels(
      baseSpacing: 24,
      zoom: context.zoom,
      minimumVisualSpacing: 13,
      scaleFactor: 2
    )
    Canvas { graphics, size in
      draw(levels.coarse, in: &graphics, size: size, radius: 1.1)
      draw(levels.fine, in: &graphics, size: size, radius: 0.8)
    }
    .background(FlowingPalette.canvas)
  }

  private func draw(
    _ level: FlowingCanvasGridLevel,
    in graphics: inout GraphicsContext,
    size: CGSize,
    radius: CGFloat
  ) {
    let spacing = level.spacing
    let startX = context.transform.offset.width.truncatingRemainder(dividingBy: spacing)
    let startY = context.transform.offset.height.truncatingRemainder(dividingBy: spacing)
    var x = startX
    while x < size.width {
      var y = startY
      while y < size.height {
        graphics.fill(
          Path(
            ellipseIn: CGRect(
              x: x - radius,
              y: y - radius,
              width: radius * 2,
              height: radius * 2
            )
          ),
          with: .color(FlowingPalette.faint.opacity(0.18 + 0.18 * level.opacity))
        )
        y += spacing
      }
      x += spacing
    }
  }
}

private struct ApplicationAudioNodeView: View {
  let node: FlowingGraphPresentationNode<RoutingCanvasSchema>
  let context: FlowingGraphCanvasNodeContext<RoutingCanvasSchema>
  let applicationCatalog: InstalledApplicationCatalogController
  let iconResolver: NSWorkspaceInstalledApplicationIconResolver

  @Environment(\.flowingAccent) private var accent

  private var selection: RoutingApplicationSelection? {
    node.value.applicationSelection
  }

  private var selectedCatalogItem: InstalledApplicationCatalogItem? {
    guard let selection else { return nil }
    return catalogItems.first {
      canonicalApplicationURL($0.application.bundleURL)
        == canonicalApplicationURL(selection.applicationURL)
    }
  }

  private var catalogItems: [InstalledApplicationCatalogItem] {
    applicationCatalog.state.snapshot?.items ?? []
  }

  var body: some View {
    let size = RoutingCanvasMetrics.nodeSize(for: node.value)
    nodeCard
      .frame(
        width: size.width, height: size.height
      )
      .scaleEffect(context.renderScale, anchor: .topLeading)
      .frame(
        width: size.width * context.renderScale,
        height: size.height * context.renderScale,
        alignment: .topLeading
      )
  }

  private var nodeCard: some View {
    FlowingCard(
      spacing: 0,
      contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    ) {
      VStack(alignment: .leading, spacing: 11) {
        HStack(spacing: 11) {
          applicationIcon

          VStack(alignment: .leading, spacing: 2) {
            Text("Application Audio")
              .font(.caption.weight(.medium))
              .foregroundStyle(FlowingPalette.muted)
            Text(selection?.displayName ?? "Choose an application")
              .font(.callout.weight(.semibold))
              .foregroundStyle(FlowingPalette.ink)
              .lineLimit(1)
          }

          Spacer(minLength: 6)
        }
        .padding(.trailing, 38)

        if selection == nil {
          nodeStatus
            .padding(.trailing, 38)
        }
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          context.isSelected ? accent.fill : FlowingPalette.hairline,
          lineWidth: context.isSelected ? 2 : 1
        )
    }
    .shadow(color: .black.opacity(context.isBeingDragged ? 0.13 : 0.07), radius: 10, y: 4)
  }

  private var applicationIcon: some View {
    ZStack {
      if let application = selectedCatalogItem?.application {
        DeferredInstalledApplicationIcon(
          application: application,
          iconResolver: iconResolver,
          size: 38,
          cornerRadius: 9
        )
      } else {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .fill(FlowingPalette.field)
        Image(systemName: "macwindow")
          .resizable()
          .scaledToFit()
          .padding(8)
          .foregroundStyle(FlowingPalette.muted)
      }
    }
    .frame(width: 38, height: 38)
    .overlay(alignment: .bottomTrailing) {
      if selectedCatalogItem?.isRunning == true {
        Circle()
          .fill(Color(nsColor: .systemGreen))
          .frame(width: 10, height: 10)
          .overlay {
            Circle().strokeBorder(FlowingPalette.control, lineWidth: 2)
          }
          .accessibilityLabel("Running")
      }
    }
    .accessibilityHidden(true)
  }

  private var nodeStatus: some View {
    HStack(spacing: 7) {
      Image(systemName: selection == nil ? "cursorarrow.click" : "checkmark")
        .font(.system(size: 9, weight: .semibold))
      Text(selection == nil ? "Select this node to configure" : "Application selected")
        .font(.caption)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .foregroundStyle(selection == nil ? accent.foreground : FlowingPalette.muted)
    .padding(.horizontal, 10)
    .frame(height: 30)
    .background(
      selection == nil ? accent.wash : FlowingPalette.field,
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
  }
}

private struct InputAudioNodeView: View {
  let node: FlowingGraphPresentationNode<RoutingCanvasSchema>
  let context: FlowingGraphCanvasNodeContext<RoutingCanvasSchema>

  @Environment(\.flowingAccent) private var accent

  private var selection: RoutingInputDeviceSelection? {
    node.value.inputDeviceSelection
  }

  var body: some View {
    let size = RoutingCanvasMetrics.nodeSize(for: node.value)
    FlowingCard(
      spacing: 0,
      contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    ) {
      VStack(alignment: .leading, spacing: 11) {
        HStack(spacing: 11) {
          Image(systemName: "waveform.badge.mic")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(accent.foreground)
            .frame(width: 38, height: 38)
            .background(
              accent.veil,
              in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )

          VStack(alignment: .leading, spacing: 2) {
            Text("Input Audio")
              .font(.caption.weight(.medium))
              .foregroundStyle(FlowingPalette.muted)
            Text(selection?.displayName ?? "Choose an input device")
              .font(.callout.weight(.semibold))
              .foregroundStyle(FlowingPalette.ink)
              .lineLimit(1)
          }

          Spacer(minLength: 6)
        }
        .padding(.trailing, 38)

        if selection == nil {
          HStack(spacing: 7) {
            Image(systemName: "cursorarrow.click")
              .font(.system(size: 9, weight: .semibold))
            Text("Select this node to configure")
              .font(.caption)
              .lineLimit(1)
            Spacer(minLength: 0)
          }
          .foregroundStyle(accent.foreground)
          .padding(.horizontal, 10)
          .frame(height: 30)
          .background(
            accent.wash,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
          )
          .padding(.trailing, 38)
        }
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          context.isSelected ? accent.fill : FlowingPalette.hairline,
          lineWidth: context.isSelected ? 2 : 1
        )
    }
    .shadow(color: .black.opacity(context.isBeingDragged ? 0.13 : 0.07), radius: 10, y: 4)
    .frame(width: size.width, height: size.height)
    .scaleEffect(context.renderScale, anchor: .topLeading)
    .frame(
      width: size.width * context.renderScale,
      height: size.height * context.renderScale,
      alignment: .topLeading
    )
  }
}

private struct SystemOutputNodeView: View {
  let node: FlowingGraphPresentationNode<RoutingCanvasSchema>
  let context: FlowingGraphCanvasNodeContext<RoutingCanvasSchema>

  @Environment(\.flowingAccent) private var accent

  private var selection: RoutingOutputCaptureSelection? {
    node.value.outputCaptureSelection
  }

  var body: some View {
    let size = RoutingCanvasMetrics.nodeSize(for: node.value)
    FlowingCard(
      spacing: 0,
      contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    ) {
      VStack(alignment: .leading, spacing: 11) {
        HStack(spacing: 11) {
          Image(systemName: "speaker.wave.2.circle")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(accent.foreground)
            .frame(width: 38, height: 38)
            .background(
              accent.veil,
              in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )

          VStack(alignment: .leading, spacing: 2) {
            Text("System Output")
              .font(.caption.weight(.medium))
              .foregroundStyle(FlowingPalette.muted)
            Text(selection?.displayName ?? "Choose an output source")
              .font(.callout.weight(.semibold))
              .foregroundStyle(FlowingPalette.ink)
              .lineLimit(1)
          }

          Spacer(minLength: 6)
        }
        .padding(.trailing, 38)

        if selection == nil {
          HStack(spacing: 7) {
            Image(systemName: "cursorarrow.click")
              .font(.system(size: 9, weight: .semibold))
            Text("Select this node to configure")
              .font(.caption)
              .lineLimit(1)
            Spacer(minLength: 0)
          }
          .foregroundStyle(accent.foreground)
          .padding(.horizontal, 10)
          .frame(height: 30)
          .background(
            accent.wash,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
          )
          .padding(.trailing, 38)
        }
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          context.isSelected ? accent.fill : FlowingPalette.hairline,
          lineWidth: context.isSelected ? 2 : 1
        )
    }
    .shadow(color: .black.opacity(context.isBeingDragged ? 0.13 : 0.07), radius: 10, y: 4)
    .frame(width: size.width, height: size.height)
    .scaleEffect(context.renderScale, anchor: .topLeading)
    .frame(
      width: size.width * context.renderScale,
      height: size.height * context.renderScale,
      alignment: .topLeading
    )
  }
}

private struct VirtualAudioEndpointNodeView: View {
  let node: FlowingGraphPresentationNode<RoutingCanvasSchema>
  let context: FlowingGraphCanvasNodeContext<RoutingCanvasSchema>
  let direction: VirtualAudioEndpointDirection
  let isDriverAvailable: Bool

  @Environment(\.flowingAccent) private var accent

  private var selection: RoutingVirtualAudioEndpointSelection? {
    node.value.virtualAudioEndpointSelection
  }

  private var title: String {
    direction == .output ? "Virtual Output" : "Virtual Input"
  }

  private var placeholder: String {
    direction == .output ? "Choose a virtual output" : "Choose a virtual input"
  }

  private var systemImage: String {
    direction == .output ? "speaker.wave.2.badge.waveform" : "mic.badge.plus"
  }

  var body: some View {
    let size = RoutingCanvasMetrics.nodeSize(for: node.value)
    FlowingCard(
      spacing: 0,
      contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    ) {
      VStack(alignment: .leading, spacing: 11) {
        HStack(spacing: 11) {
          Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(accent.foreground)
            .frame(width: 38, height: 38)
            .background(
              accent.veil,
              in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )

          VStack(alignment: .leading, spacing: 2) {
            Text(title)
              .font(.caption.weight(.medium))
              .foregroundStyle(FlowingPalette.muted)
            Text(selection?.displayName ?? placeholder)
              .font(.callout.weight(.semibold))
              .foregroundStyle(FlowingPalette.ink)
              .lineLimit(1)
          }

          Spacer(minLength: 6)
        }
        .padding(direction == .output ? .trailing : .leading, 38)

        if selection == nil || !isDriverAvailable {
          HStack(spacing: 7) {
            Image(systemName: isDriverAvailable ? "cursorarrow.click" : "externaldrive.badge.plus")
              .font(.system(size: 9, weight: .semibold))
            Text(
              isDriverAvailable ? "Select this node to configure" : "Install virtual audio driver"
            )
            .font(.caption)
            .lineLimit(1)
            Spacer(minLength: 0)
          }
          .foregroundStyle(accent.foreground)
          .padding(.horizontal, 10)
          .frame(height: 30)
          .background(
            accent.wash,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
          )
          .padding(direction == .output ? .trailing : .leading, 38)
        }
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          context.isSelected ? accent.fill : FlowingPalette.hairline,
          lineWidth: context.isSelected ? 2 : 1
        )
    }
    .shadow(color: .black.opacity(context.isBeingDragged ? 0.13 : 0.07), radius: 10, y: 4)
    .frame(width: size.width, height: size.height)
    .scaleEffect(context.renderScale, anchor: .topLeading)
    .frame(
      width: size.width * context.renderScale,
      height: size.height * context.renderScale,
      alignment: .topLeading
    )
  }
}

private struct OutputAudioNodeView: View {
  let node: FlowingGraphPresentationNode<RoutingCanvasSchema>
  let context: FlowingGraphCanvasNodeContext<RoutingCanvasSchema>

  @Environment(\.flowingAccent) private var accent

  private var selection: RoutingOutputDeviceSelection? {
    node.value.outputDeviceSelection
  }

  var body: some View {
    let size = RoutingCanvasMetrics.nodeSize(for: node.value)
    FlowingCard(
      spacing: 0,
      contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    ) {
      VStack(alignment: .leading, spacing: 11) {
        HStack(spacing: 11) {
          Image(systemName: "speaker.wave.2")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(accent.foreground)
            .frame(width: 38, height: 38)
            .background(
              accent.veil,
              in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )

          VStack(alignment: .leading, spacing: 2) {
            Text("Output Audio")
              .font(.caption.weight(.medium))
              .foregroundStyle(FlowingPalette.muted)
            Text(selection?.displayName ?? "Choose an output device")
              .font(.callout.weight(.semibold))
              .foregroundStyle(FlowingPalette.ink)
              .lineLimit(1)
          }

          Spacer(minLength: 6)
        }
        .padding(.leading, 38)

        if selection == nil {
          HStack(spacing: 7) {
            Image(systemName: "cursorarrow.click")
              .font(.system(size: 9, weight: .semibold))
            Text("Select this node to configure")
              .font(.caption)
              .lineLimit(1)
            Spacer(minLength: 0)
          }
          .foregroundStyle(accent.foreground)
          .padding(.horizontal, 10)
          .frame(height: 30)
          .background(
            accent.wash,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
          )
          .padding(.leading, 38)
        }
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          context.isSelected ? accent.fill : FlowingPalette.hairline,
          lineWidth: context.isSelected ? 2 : 1
        )
    }
    .shadow(color: .black.opacity(context.isBeingDragged ? 0.13 : 0.07), radius: 10, y: 4)
    .frame(width: size.width, height: size.height)
    .scaleEffect(context.renderScale, anchor: .topLeading)
    .frame(
      width: size.width * context.renderScale,
      height: size.height * context.renderScale,
      alignment: .topLeading
    )
  }
}

private struct VisualizerNodeView: View {
  let configuration: RoutingVisualizerConfiguration
  let snapshot: RoutingVisualizerSignal?
  let context: FlowingGraphCanvasNodeContext<RoutingCanvasSchema>

  @Environment(\.flowingAccent) private var accent

  var body: some View {
    let size = RoutingCanvasMetrics.nodeSize(for: .visualizer(configuration: configuration))
    FlowingCard(
      spacing: 10,
      contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    ) {
      HStack(spacing: 9) {
        Image(systemName: "waveform")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(accent.foreground)
        VStack(alignment: .leading, spacing: 1) {
          Text("Visualizer")
            .font(.callout.weight(.semibold))
            .foregroundStyle(FlowingPalette.ink)
          Text(configuration.mode == .mixed ? "Mixed waveform" : channelSummary)
            .font(.caption)
            .foregroundStyle(FlowingPalette.muted)
        }
        Spacer(minLength: 0)
      }

      if let snapshot {
        RoutingWaveformDisplay(signal: snapshot, configuration: configuration)
          .padding(.leading, RoutingVisualizerLayout.portLabelGutter)
          .frame(height: RoutingVisualizerLayout.waveformContentHeight(for: configuration))
      } else {
        RoutingWaveformPlaceholder()
          .padding(.leading, RoutingVisualizerLayout.portLabelGutter)
          .frame(height: RoutingVisualizerLayout.waveformContentHeight(for: configuration))
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          context.isSelected ? accent.fill : FlowingPalette.hairline,
          lineWidth: context.isSelected ? 2 : 1
        )
    }
    .shadow(color: .black.opacity(context.isBeingDragged ? 0.13 : 0.07), radius: 10, y: 4)
    .frame(
      width: size.width,
      height: size.height
    )
    .scaleEffect(context.renderScale, anchor: .topLeading)
    .frame(
      width: size.width * context.renderScale,
      height: size.height * context.renderScale,
      alignment: .topLeading
    )
  }

  private var channelSummary: String {
    let count = configuration.normalizedSelectedChannels.count
    return "\(count) selected channel\(count == 1 ? "" : "s")"
  }
}

private struct AudioMixerNodeView: View {
  let configuration: RoutingAudioMixerConfiguration
  let context: FlowingGraphCanvasNodeContext<RoutingCanvasSchema>

  @Environment(\.flowingAccent) private var accent

  var body: some View {
    let size = RoutingCanvasMetrics.nodeSize(for: .audioMixer(configuration: configuration))
    FlowingCard(
      spacing: 10,
      contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    ) {
      HStack(spacing: 9) {
        Image(systemName: "slider.horizontal.3")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(accent.foreground)
        VStack(alignment: .leading, spacing: 1) {
          Text("Audio Mixer")
            .font(.callout.weight(.semibold))
            .foregroundStyle(FlowingPalette.ink)
          Text("\(configuration.channelCount)-channel mix")
            .font(.caption)
            .foregroundStyle(FlowingPalette.muted)
        }
        Spacer(minLength: 0)
      }

      VStack(spacing: RoutingAudioMixerLayout.rowSpacing) {
        ForEach(0..<configuration.channelCount, id: \.self) { channelIndex in
          HStack {
            Text(channelLabel(channelIndex))
              .font(.system(size: 10, weight: .semibold, design: .monospaced))
              .foregroundStyle(FlowingPalette.muted)
            Capsule()
              .fill(FlowingPalette.field)
              .frame(height: 8)
            Text("0 dB")
              .font(.system(size: 9, weight: .medium, design: .monospaced))
              .foregroundStyle(FlowingPalette.muted)
          }
          .frame(height: RoutingAudioMixerLayout.rowHeight)
        }
      }
      .padding(.horizontal, RoutingAudioMixerLayout.portLabelGutter)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          context.isSelected ? accent.fill : FlowingPalette.hairline,
          lineWidth: context.isSelected ? 2 : 1
        )
    }
    .shadow(color: .black.opacity(context.isBeingDragged ? 0.13 : 0.07), radius: 10, y: 4)
    .frame(width: size.width, height: size.height)
    .scaleEffect(context.renderScale, anchor: .topLeading)
    .frame(
      width: size.width * context.renderScale,
      height: size.height * context.renderScale,
      alignment: .topLeading
    )
  }

  private func channelLabel(_ channelIndex: Int) -> String {
    if configuration.channelCount == 2 {
      return channelIndex == 0 ? "L" : "R"
    }
    return "Ch \(channelIndex + 1)"
  }
}

private struct GainNodeView: View {
  let configuration: RoutingGainConfiguration
  let context: FlowingGraphCanvasNodeContext<RoutingCanvasSchema>

  @Environment(\.flowingAccent) private var accent

  var body: some View {
    FlowingCard(
      spacing: 10,
      contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    ) {
      HStack(spacing: 9) {
        Image(systemName: "plusminus")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(accent.foreground)
        VStack(alignment: .leading, spacing: 1) {
          Text("Gain")
            .font(.callout.weight(.semibold))
            .foregroundStyle(FlowingPalette.ink)
          Text(configuration.isPolarityInverted ? "Polarity inverted" : "Level utility")
            .font(.caption)
            .foregroundStyle(FlowingPalette.muted)
        }
        Spacer(minLength: 0)
      }

      HStack(spacing: 8) {
        Text(configuration.isMuted ? "Muted" : configuration.gainDescription)
          .font(.caption.monospacedDigit().weight(.semibold))
          .foregroundStyle(configuration.isMuted ? FlowingPalette.faint : FlowingPalette.muted)
        Spacer(minLength: 4)
        if configuration.isPolarityInverted {
          Text("Ø")
            .font(.callout.weight(.semibold))
            .foregroundStyle(accent.foreground)
        }
      }
      .padding(.horizontal, 12)
      .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
      .background(
        accent.wash.opacity(configuration.isMuted ? 0.55 : 1),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .padding(.horizontal, RoutingVisualizerLayout.portLabelGutter)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          context.isSelected ? accent.fill : FlowingPalette.hairline,
          lineWidth: context.isSelected ? 2 : 1
        )
    }
    .shadow(color: .black.opacity(context.isBeingDragged ? 0.13 : 0.07), radius: 10, y: 4)
    .frame(
      width: RoutingCanvasMetrics.baseNodeSize.width,
      height: RoutingCanvasMetrics.baseNodeSize.height
    )
    .scaleEffect(context.renderScale, anchor: .topLeading)
    .frame(
      width: RoutingCanvasMetrics.baseNodeSize.width * context.renderScale,
      height: RoutingCanvasMetrics.baseNodeSize.height * context.renderScale,
      alignment: .topLeading
    )
  }
}

private struct ChannelRouterNodeView: View {
  let configuration: RoutingChannelRouterConfiguration
  let context: FlowingGraphCanvasNodeContext<RoutingCanvasSchema>

  @Environment(\.flowingAccent) private var accent

  var body: some View {
    let size = RoutingCanvasMetrics.nodeSize(for: .channelRouter(configuration: configuration))
    FlowingCard(
      spacing: 10,
      contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    ) {
      HStack(spacing: 9) {
        Image(systemName: "arrow.left.arrow.right")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(accent.foreground)
        VStack(alignment: .leading, spacing: 1) {
          Text("Channel Router")
            .font(.callout.weight(.semibold))
            .foregroundStyle(FlowingPalette.ink)
          Text("\(configuration.inputChannelCount) in · \(configuration.outputChannelCount) out")
            .font(.caption.monospacedDigit())
            .foregroundStyle(FlowingPalette.muted)
        }
        Spacer(minLength: 0)
      }

      VStack(spacing: RoutingAudioMixerLayout.rowSpacing) {
        ForEach(0..<rowCount, id: \.self) { row in
          HStack(spacing: 8) {
            Text(row < configuration.inputChannelCount ? "In \(row + 1)" : "")
              .frame(width: 30, alignment: .leading)
            Spacer(minLength: 0)
            if row < configuration.outputChannelCount {
              Text(mappingLabel(for: row))
                .foregroundStyle(accent.foreground)
              Image(systemName: "arrow.right")
                .font(.system(size: 8, weight: .semibold))
              Text("Out \(row + 1)")
            }
          }
          .font(.system(size: 9, weight: .semibold, design: .monospaced))
          .foregroundStyle(FlowingPalette.muted)
          .frame(height: RoutingAudioMixerLayout.rowHeight)
        }
      }
      .padding(.horizontal, RoutingAudioMixerLayout.portLabelGutter)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          context.isSelected ? accent.fill : FlowingPalette.hairline,
          lineWidth: context.isSelected ? 2 : 1
        )
    }
    .shadow(color: .black.opacity(context.isBeingDragged ? 0.13 : 0.07), radius: 10, y: 4)
    .frame(width: size.width, height: size.height)
    .scaleEffect(context.renderScale, anchor: .topLeading)
    .frame(
      width: size.width * context.renderScale,
      height: size.height * context.renderScale,
      alignment: .topLeading
    )
  }

  private var rowCount: Int {
    max(configuration.inputChannelCount, configuration.outputChannelCount)
  }

  private func mappingLabel(for outputChannel: Int) -> String {
    guard let source = configuration.outputSources[outputChannel] else { return "Off" }
    return "In \(source + 1)"
  }
}

private struct PeakLevelNodeView: View {
  let signal: RoutingPeakLevelSignal?
  let context: FlowingGraphCanvasNodeContext<RoutingCanvasSchema>

  @Environment(\.flowingAccent) private var accent

  var body: some View {
    FlowingCard(
      spacing: 10,
      contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    ) {
      HStack(spacing: 9) {
        Image(systemName: "gauge.with.dots.needle.50percent")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(accent.foreground)
        VStack(alignment: .leading, spacing: 1) {
          Text("Peak Level")
            .font(.callout.weight(.semibold))
            .foregroundStyle(FlowingPalette.ink)
          Text(signal == nil ? "Waiting for audio" : "Linear full scale")
            .font(.caption)
            .foregroundStyle(FlowingPalette.muted)
        }
        Spacer(minLength: 0)
      }

      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(signal?.linearDescription ?? "—")
          .font(.system(size: 22, weight: .semibold, design: .rounded))
          .foregroundStyle(
            signal?.isClipping == true ? FlowingAccent.poppy.foreground : FlowingPalette.ink
          )
          .monospacedDigit()
        Spacer(minLength: 4)
        Text(signal?.decibelsDescription ?? "Waiting for audio input")
          .font(.caption.monospacedDigit())
          .foregroundStyle(FlowingPalette.muted)
      }
      .padding(.horizontal, 12)
      .frame(height: 38)
      .background(
        FlowingPalette.field,
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .padding(.horizontal, RoutingVisualizerLayout.portLabelGutter)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          context.isSelected ? accent.fill : FlowingPalette.hairline,
          lineWidth: context.isSelected ? 2 : 1
        )
    }
    .shadow(color: .black.opacity(context.isBeingDragged ? 0.13 : 0.07), radius: 10, y: 4)
    .frame(
      width: RoutingCanvasMetrics.baseNodeSize.width,
      height: RoutingCanvasMetrics.baseNodeSize.height
    )
    .scaleEffect(context.renderScale, anchor: .topLeading)
    .frame(
      width: RoutingCanvasMetrics.baseNodeSize.width * context.renderScale,
      height: RoutingCanvasMetrics.baseNodeSize.height * context.renderScale,
      alignment: .topLeading
    )
  }
}

private struct SignalGeneratorNodeView: View {
  let configuration: RoutingSignalGeneratorConfiguration
  let context: FlowingGraphCanvasNodeContext<RoutingCanvasSchema>

  @Environment(\.flowingAccent) private var accent

  var body: some View {
    FlowingCard(
      spacing: 10,
      contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    ) {
      HStack(spacing: 9) {
        Image(systemName: "waveform.path")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(accent.foreground)
        VStack(alignment: .leading, spacing: 1) {
          Text("Signal Generator")
            .font(.callout.weight(.semibold))
            .foregroundStyle(FlowingPalette.ink)
          Text(subtitle)
            .font(.caption)
            .foregroundStyle(FlowingPalette.muted)
        }
        Spacer(minLength: 0)
      }

      Text("\(Int((configuration.amplitude * 100).rounded()))% amplitude")
        .font(.caption.monospacedDigit())
        .foregroundStyle(accent.foreground)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background(
          accent.wash,
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(.trailing, RoutingVisualizerLayout.portLabelGutter)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          context.isSelected ? accent.fill : FlowingPalette.hairline,
          lineWidth: context.isSelected ? 2 : 1
        )
    }
    .shadow(color: .black.opacity(context.isBeingDragged ? 0.13 : 0.07), radius: 10, y: 4)
    .frame(
      width: RoutingCanvasMetrics.baseNodeSize.width,
      height: RoutingCanvasMetrics.baseNodeSize.height
    )
    .scaleEffect(context.renderScale, anchor: .topLeading)
    .frame(
      width: RoutingCanvasMetrics.baseNodeSize.width * context.renderScale,
      height: RoutingCanvasMetrics.baseNodeSize.height * context.renderScale,
      alignment: .topLeading
    )
  }

  private var subtitle: String {
    guard configuration.waveform.usesFrequency else {
      return configuration.waveform.displayName
    }
    return "\(configuration.waveform.displayName) · \(frequencyDescription) Hz"
  }

  private var frequencyDescription: String {
    configuration.frequency.formatted(.number.precision(.fractionLength(0)))
  }
}

private struct FilePlaybackNodeView: View {
  let configuration: RoutingFilePlaybackConfiguration
  let context: FlowingGraphCanvasNodeContext<RoutingCanvasSchema>

  @Environment(\.flowingAccent) private var accent

  var body: some View {
    FlowingCard(
      spacing: 10,
      contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    ) {
      HStack(spacing: 9) {
        Image(systemName: "music.note.list")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(accent.foreground)
        VStack(alignment: .leading, spacing: 1) {
          Text("File Playback")
            .font(.callout.weight(.semibold))
            .foregroundStyle(FlowingPalette.ink)
          Text(configuration.selection?.displayName ?? "Choose an audio file")
            .font(.caption)
            .foregroundStyle(FlowingPalette.muted)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }

      Text(fileDetail)
        .font(.caption.monospacedDigit())
        .foregroundStyle(accent.foreground)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background(
          accent.wash,
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(.trailing, RoutingVisualizerLayout.portLabelGutter)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          context.isSelected ? accent.fill : FlowingPalette.hairline,
          lineWidth: context.isSelected ? 2 : 1
        )
    }
    .shadow(color: .black.opacity(context.isBeingDragged ? 0.13 : 0.07), radius: 10, y: 4)
    .frame(
      width: RoutingCanvasMetrics.baseNodeSize.width,
      height: RoutingCanvasMetrics.baseNodeSize.height
    )
    .scaleEffect(context.renderScale, anchor: .topLeading)
    .frame(
      width: RoutingCanvasMetrics.baseNodeSize.width * context.renderScale,
      height: RoutingCanvasMetrics.baseNodeSize.height * context.renderScale,
      alignment: .topLeading
    )
  }

  private var fileDetail: String {
    guard let selection = configuration.selection else { return "Select this node to configure" }
    return "\(selection.channelCount) ch · \(configuration.loopMode.description)"
  }
}

private struct FileOutputNodeView: View {
  let configuration: RoutingFileOutputConfiguration
  let context: FlowingGraphCanvasNodeContext<RoutingCanvasSchema>

  @Environment(\.flowingAccent) private var accent

  var body: some View {
    FlowingCard(
      spacing: 10,
      contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    ) {
      HStack(spacing: 9) {
        Image(systemName: "square.and.arrow.down")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(accent.foreground)
        VStack(alignment: .leading, spacing: 1) {
          Text("File Output")
            .font(.callout.weight(.semibold))
            .foregroundStyle(FlowingPalette.ink)
          Text(configuration.destination?.displayName ?? "Choose a destination")
            .font(.caption)
            .foregroundStyle(FlowingPalette.muted)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }

      Text(configuration.formatDescription)
        .font(.caption.monospacedDigit())
        .foregroundStyle(accent.foreground)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background(
          accent.wash,
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(.leading, RoutingVisualizerLayout.portLabelGutter)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          context.isSelected ? accent.fill : FlowingPalette.hairline,
          lineWidth: context.isSelected ? 2 : 1
        )
    }
    .shadow(color: .black.opacity(context.isBeingDragged ? 0.13 : 0.07), radius: 10, y: 4)
    .frame(
      width: RoutingCanvasMetrics.baseNodeSize.width,
      height: RoutingCanvasMetrics.baseNodeSize.height
    )
    .scaleEffect(context.renderScale, anchor: .topLeading)
    .frame(
      width: RoutingCanvasMetrics.baseNodeSize.width * context.renderScale,
      height: RoutingCanvasMetrics.baseNodeSize.height * context.renderScale,
      alignment: .topLeading
    )
  }
}

private struct NetworkAudioNodeView: View {
  let title: String
  let subtitle: String
  let sampleRate: Double
  let channelCount: Int
  let systemImage: String
  let context: FlowingGraphCanvasNodeContext<RoutingCanvasSchema>

  @Environment(\.flowingAccent) private var accent

  var body: some View {
    FlowingCard(
      spacing: 10,
      contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    ) {
      HStack(spacing: 9) {
        Image(systemName: systemImage)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(accent.foreground)
        VStack(alignment: .leading, spacing: 1) {
          Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(FlowingPalette.ink)
          Text(subtitle)
            .font(.caption.monospacedDigit())
            .foregroundStyle(FlowingPalette.muted)
            .lineLimit(1)
        }
        Spacer(minLength: 0)
      }

      Text("\(channelCount) ch · \(sampleRateDescription) kHz")
        .font(.caption.monospacedDigit())
        .foregroundStyle(accent.foreground)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background(
          accent.wash,
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(.horizontal, RoutingVisualizerLayout.portLabelGutter)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          context.isSelected ? accent.fill : FlowingPalette.hairline,
          lineWidth: context.isSelected ? 2 : 1
        )
    }
    .shadow(color: .black.opacity(context.isBeingDragged ? 0.13 : 0.07), radius: 10, y: 4)
    .frame(
      width: RoutingCanvasMetrics.baseNodeSize.width,
      height: RoutingCanvasMetrics.baseNodeSize.height
    )
    .scaleEffect(context.renderScale, anchor: .topLeading)
    .frame(
      width: RoutingCanvasMetrics.baseNodeSize.width * context.renderScale,
      height: RoutingCanvasMetrics.baseNodeSize.height * context.renderScale,
      alignment: .topLeading
    )
  }

  private var sampleRateDescription: String {
    let kilohertz = sampleRate / 1_000
    return kilohertz.formatted(
      .number.precision(.fractionLength(kilohertz == kilohertz.rounded() ? 0 : 1))
    )
  }
}

private struct DelayNodeView: View {
  let configuration: RoutingDelayConfiguration
  let context: FlowingGraphCanvasNodeContext<RoutingCanvasSchema>

  @Environment(\.flowingAccent) private var accent

  var body: some View {
    FlowingCard(
      spacing: 10,
      contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    ) {
      HStack(spacing: 9) {
        Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(accent.foreground)
        VStack(alignment: .leading, spacing: 1) {
          Text("Delay")
            .font(.callout.weight(.semibold))
            .foregroundStyle(FlowingPalette.ink)
          Text(delayDescription)
            .font(.caption.monospacedDigit())
            .foregroundStyle(FlowingPalette.muted)
        }
        Spacer(minLength: 0)
      }

      Text("\(Int((configuration.dryWetMix * 100).rounded()))% wet")
        .font(.caption.monospacedDigit())
        .foregroundStyle(accent.foreground)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background(
          accent.wash,
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(.horizontal, RoutingVisualizerLayout.portLabelGutter)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          context.isSelected ? accent.fill : FlowingPalette.hairline,
          lineWidth: context.isSelected ? 2 : 1
        )
    }
    .shadow(color: .black.opacity(context.isBeingDragged ? 0.13 : 0.07), radius: 10, y: 4)
    .frame(
      width: RoutingCanvasMetrics.baseNodeSize.width,
      height: RoutingCanvasMetrics.baseNodeSize.height
    )
    .scaleEffect(context.renderScale, anchor: .topLeading)
    .frame(
      width: RoutingCanvasMetrics.baseNodeSize.width * context.renderScale,
      height: RoutingCanvasMetrics.baseNodeSize.height * context.renderScale,
      alignment: .topLeading
    )
  }

  private var delayDescription: String {
    if configuration.delaySeconds < 1 {
      return "\(Int((configuration.delaySeconds * 1_000).rounded())) ms"
    }
    return configuration.delaySeconds.formatted(
      .number.precision(.fractionLength(2))
    ) + " s"
  }
}

private struct NoiseGateNodeView: View {
  let configuration: RoutingNoiseGateConfiguration
  let context: FlowingGraphCanvasNodeContext<RoutingCanvasSchema>

  @Environment(\.flowingAccent) private var accent

  var body: some View {
    FlowingCard(
      spacing: 10,
      contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    ) {
      HStack(spacing: 9) {
        Image(systemName: "waveform.badge.minus")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(accent.foreground)
        VStack(alignment: .leading, spacing: 1) {
          Text("Noise Gate")
            .font(.callout.weight(.semibold))
            .foregroundStyle(FlowingPalette.ink)
          Text("\(Int(configuration.thresholdDecibels.rounded())) dBFS threshold")
            .font(.caption.monospacedDigit())
            .foregroundStyle(FlowingPalette.muted)
        }
        Spacer(minLength: 0)
      }

      Text("\(Int(configuration.reductionDecibels.rounded())) dB reduction")
        .font(.caption.monospacedDigit())
        .foregroundStyle(accent.foreground)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background(
          accent.wash,
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(.horizontal, RoutingVisualizerLayout.portLabelGutter)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          context.isSelected ? accent.fill : FlowingPalette.hairline,
          lineWidth: context.isSelected ? 2 : 1
        )
    }
    .shadow(color: .black.opacity(context.isBeingDragged ? 0.13 : 0.07), radius: 10, y: 4)
    .frame(
      width: RoutingCanvasMetrics.baseNodeSize.width,
      height: RoutingCanvasMetrics.baseNodeSize.height
    )
    .scaleEffect(context.renderScale, anchor: .topLeading)
    .frame(
      width: RoutingCanvasMetrics.baseNodeSize.width * context.renderScale,
      height: RoutingCanvasMetrics.baseNodeSize.height * context.renderScale,
      alignment: .topLeading
    )
  }
}

private struct CompressorNodeView: View {
  let configuration: RoutingCompressorConfiguration
  let context: FlowingGraphCanvasNodeContext<RoutingCanvasSchema>

  @Environment(\.flowingAccent) private var accent

  var body: some View {
    FlowingCard(
      spacing: 10,
      contentInsets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    ) {
      HStack(spacing: 9) {
        Image(systemName: "arrow.down.right.and.arrow.up.left")
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(accent.foreground)
        VStack(alignment: .leading, spacing: 1) {
          Text("Compressor")
            .font(.callout.weight(.semibold))
            .foregroundStyle(FlowingPalette.ink)
          Text("\(Int(configuration.thresholdDecibels.rounded())) dBFS threshold")
            .font(.caption.monospacedDigit())
            .foregroundStyle(FlowingPalette.muted)
        }
        Spacer(minLength: 0)
      }

      Text("\(configuration.ratio.formatted(.number.precision(.fractionLength(1)))):1 ratio")
        .font(.caption.monospacedDigit())
        .foregroundStyle(accent.foreground)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        .background(
          accent.wash,
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .padding(.horizontal, RoutingVisualizerLayout.portLabelGutter)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(
          context.isSelected ? accent.fill : FlowingPalette.hairline,
          lineWidth: context.isSelected ? 2 : 1
        )
    }
    .shadow(color: .black.opacity(context.isBeingDragged ? 0.13 : 0.07), radius: 10, y: 4)
    .frame(
      width: RoutingCanvasMetrics.baseNodeSize.width,
      height: RoutingCanvasMetrics.baseNodeSize.height
    )
    .scaleEffect(context.renderScale, anchor: .topLeading)
    .frame(
      width: RoutingCanvasMetrics.baseNodeSize.width * context.renderScale,
      height: RoutingCanvasMetrics.baseNodeSize.height * context.renderScale,
      alignment: .topLeading
    )
  }
}

private struct RoutingWaveformDisplay: View {
  let signal: RoutingVisualizerSignal
  let configuration: RoutingVisualizerConfiguration

  @Environment(\.flowingAccent) private var accent

  var body: some View {
    VStack(spacing: RoutingVisualizerLayout.laneSpacing) {
      ForEach(signal.lanes) { lane in
        HStack(spacing: 5) {
          Canvas { graphics, size in
            let samples = RoutingWaveformDisplayTransform.normalizedSamples(lane.samples)
            guard samples.count > 1 else { return }
            let middle = size.height / 2
            let amplitude = size.height * 0.42
            var path = Path()
            for (sampleIndex, sample) in samples.enumerated() {
              let x = size.width * CGFloat(sampleIndex) / CGFloat(samples.count - 1)
              let y = middle - CGFloat(sample) * amplitude
              if sampleIndex == 0 {
                path.move(to: CGPoint(x: x, y: y))
              } else {
                path.addLine(to: CGPoint(x: x, y: y))
              }
            }
            graphics.stroke(
              path,
              with: .color(accent.fill.opacity(0.92)),
              style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
          }
          .padding(.vertical, 3)
        }
        .padding(.horizontal, 8)
        .frame(height: RoutingVisualizerLayout.laneHeight(for: configuration))
        .background(
          FlowingPalette.field,
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
      }
    }
    .accessibilityElement()
    .accessibilityLabel("Waveform")
    .accessibilityValue("Live audio")
  }

}

private struct RoutingWaveformPlaceholder: View {
  var body: some View {
    Text("Waiting for audio input")
      .font(.system(size: 9, weight: .medium))
      .foregroundStyle(FlowingPalette.faint)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityElement()
      .accessibilityLabel("Waveform")
      .accessibilityValue("Waiting for audio")
  }
}

private struct RoutingAudioPortView: View {
  let port: FlowingGraphPresentationPort<RoutingCanvasSchema>
  let context: FlowingGraphCanvasPortContext<RoutingCanvasSchema>

  @Environment(\.flowingAccent) private var accent

  var body: some View {
    ZStack {
      Circle()
        .fill(fillColor)
        .overlay {
          Circle().strokeBorder(strokeColor, lineWidth: 1.5)
        }
        .frame(width: 11 * context.renderScale, height: 11 * context.renderScale)

      Text(port.value.shortLabel)
        .font(
          .system(
            size: 8 * context.renderScale,
            weight: .semibold,
            design: .monospaced
          )
        )
        .foregroundStyle(FlowingPalette.muted.opacity(0.76))
        .lineLimit(1)
        .frame(
          width: 40 * context.renderScale,
          alignment: port.value.direction == .input ? .leading : .trailing
        )
        .offset(
          x: (port.value.direction == .input ? 1 : -1) * 30 * context.renderScale
        )
        .allowsHitTesting(false)
    }
    .frame(width: 26 * context.renderScale, height: 26 * context.renderScale)
    .contentShape(Rectangle())
    .help(port.value.label)
    .accessibilityElement()
    .accessibilityLabel(port.value.label)
  }

  private var fillColor: Color {
    switch context.connectionState {
    case .source:
      accent.fill
    case .target(.valid, let isCandidate):
      isCandidate ? Color.green.opacity(0.35) : Color.green.opacity(0.14)
    case .target(.invalid, let isCandidate):
      isCandidate ? Color.red.opacity(0.3) : FlowingPalette.control
    case .idle:
      context.isSelected ? accent.fill : FlowingPalette.control
    }
  }

  private var strokeColor: Color {
    switch context.connectionState {
    case .target(.valid, _):
      return .green
    case .target(.invalid, let isCandidate):
      return isCandidate ? .red : accent.fill.opacity(0.5)
    case .idle, .source:
      return accent.fill
    }
  }
}

private enum RoutingPortDisplayMode: Hashable {
  case aggregate
  case separate
}

private struct RoutingNodeColorOverrideCard: View {
  let selection: RoutingAccentID?
  let inheritedAccentID: RoutingAccentID
  @Binding var isExpanded: Bool
  let setSelection: (RoutingAccentID?) -> Void

  var body: some View {
    FlowingCard(
      spacing: 0,
      contentInsets: EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
    ) {
      FlowingDisclosure(
        isExpanded: $isExpanded,
        minimumHeaderHeight: 38,
        contentInsets: EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
      ) {
        HStack(spacing: 8) {
          RoutingAccentSwatch(accentID: selection ?? inheritedAccentID)
          Text("Node Color")
            .font(.caption.weight(.semibold))
            .foregroundStyle(FlowingPalette.ink)
          Text(currentColorDescription)
            .font(.caption2)
            .foregroundStyle(FlowingPalette.muted)
            .lineLimit(1)
        }
      } content: {
        RoutingAccentGrid(
          selection: selection,
          inheritedAccentID: inheritedAccentID,
          inheritedLabel: "Use Node Default",
          setSelection: setSelection
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
      }
    }
    .shadow(color: .black.opacity(0.035), radius: 6, y: 2)
  }

  private var currentColorDescription: String {
    selection == nil ? "Node default" : "Custom"
  }
}

private struct SelectedApplicationInspector: View {
  let nodeID: UUID
  let selection: RoutingApplicationSelection?
  let channelPresentation: RoutingChannelPresentation
  let isRouted: Bool
  let applicationCatalog: InstalledApplicationCatalogController
  let iconResolver: NSWorkspaceInstalledApplicationIconResolver
  let captureController: RoutingCaptureController
  let channelControls: [Int: RoutingAudioChannelControl]
  let selectApplication: (RoutingApplicationSelection?) -> Void
  let setChannelPresentation: (RoutingChannelPresentation) -> Void
  let setChannelGain: (Int, Double) -> Void
  let setChannelMuted: (Int, Bool) -> Void

  private var catalogItems: [InstalledApplicationCatalogItem] {
    applicationCatalog.state.snapshot?.items ?? []
  }

  private var selectedCatalogItem: InstalledApplicationCatalogItem? {
    guard let selection else { return nil }
    return catalogItems.first {
      canonicalApplicationURL($0.application.bundleURL)
        == canonicalApplicationURL(selection.applicationURL)
    }
  }

  private var runningProcessID: AudioProcessID? {
    selectedCatalogItem?.runningApplications
      .map(\.processIdentifier)
      .min()
      .flatMap(AudioProcessID.init(rawValue:))
  }

  var body: some View {
    FlowingCard(
      spacing: 14,
      contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    ) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Application Audio")
            .font(.headline)
            .foregroundStyle(FlowingPalette.ink)
          Text("Choose the application this node follows.")
            .font(.caption)
            .foregroundStyle(FlowingPalette.muted)
        }

        Spacer(minLength: 4)

        if selectedCatalogItem?.isRunning == true {
          Circle()
            .fill(Color(nsColor: .systemGreen))
            .frame(width: 9, height: 9)
            .accessibilityLabel("Running")
        }
      }

      applicationPickerContent

      captureContent

      Divider()
        .overlay(FlowingPalette.hairline)

      VStack(alignment: .leading, spacing: 9) {
        Text("Output Ports")
          .font(.caption.weight(.semibold))
          .foregroundStyle(FlowingPalette.muted)

        FlowingSegmentedControl(
          label: "Output port presentation",
          selection: portDisplayMode,
          options: [
            FlowingSegmentOption(.aggregate, label: "All Channels"),
            FlowingSegmentOption(.separate, label: "Separate"),
          ]
        )

        if case .separate = channelPresentation {
          HStack {
            Text("Channels")
              .font(.caption)
              .foregroundStyle(FlowingPalette.muted)
            Spacer(minLength: 8)
            FlowingStepper(
              "Output channel count",
              value: separateChannelCount,
              in: 1...RoutingVisualizerConfiguration.maximumAvailableChannelCount,
              step: 1
            )
          }
        }

        Text("The native channel count will replace this preview when capture starts.")
          .font(.caption2)
          .foregroundStyle(FlowingPalette.faint)
      }

      if case .separate(let channelCount) = channelPresentation {
        Divider()
          .overlay(FlowingPalette.hairline)
        RoutingAudioChannelControlsView(
          channelCount: channelCount,
          controls: channelControls,
          setGain: setChannelGain,
          setMuted: setChannelMuted
        )
      }
    }
    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
  }

  @ViewBuilder
  private var captureContent: some View {
    switch captureController.state(for: nodeID) {
    case .idle:
      if isRouted, let processID = runningProcessID {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text("Connected for Capture")
              .font(.caption.weight(.semibold))
              .foregroundStyle(FlowingPalette.ink)
            Text("Starting PID \(processID.rawValue) automatically · playback stays audible")
              .font(.caption2)
              .foregroundStyle(FlowingPalette.muted)
            if let runningApplicationCount, runningApplicationCount > 1 {
              Text("\(runningApplicationCount) instances are running; using the lowest PID")
                .font(.caption2)
                .foregroundStyle(FlowingPalette.faint)
            }
          }
        }
      } else if isRouted, selection != nil {
        FlowingCallout(
          "Launch the selected application; its connected output will begin capturing automatically.",
          title: "Application is not running",
          systemImage: "play.circle",
          tone: .neutral
        )
      } else if selection != nil {
        FlowingCallout(
          "Connect an output port to another audio node to begin capture.",
          title: "Ready to Route",
          systemImage: "point.3.connected.trianglepath.dotted",
          tone: .neutral
        )
      }
    case .starting:
      HStack(spacing: 9) {
        ProgressView()
          .controlSize(.small)
        Text("Creating the native audio tap…")
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    case .running(let format):
      HStack {
        Circle()
          .fill(Color(nsColor: .systemGreen))
          .frame(width: 9, height: 9)
        VStack(alignment: .leading, spacing: 2) {
          Text("Capturing \(format.channelIDs.count) channels")
            .font(.caption.weight(.semibold))
            .foregroundStyle(FlowingPalette.ink)
          Text("\(format.sampleRate.formatted()) Hz")
            .font(.caption2)
            .foregroundStyle(FlowingPalette.muted)
          if captureController.consumerCount(for: nodeID) > 1 {
            Text("Shared by \(captureController.consumerCount(for: nodeID)) nodes")
              .font(.caption2)
              .foregroundStyle(FlowingPalette.faint)
          }
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Capturing application audio")
    case .failed(let failure):
      VStack(alignment: .leading, spacing: 8) {
        FlowingCallout(
          failure.message,
          title: "Capture failed",
          systemImage: "exclamationmark.triangle",
          tone: .warning
        )
        if isRouted, runningProcessID != nil {
          Button("Try Again") {
            captureController.retry(nodeID: nodeID)
          }
          .buttonStyle(FlowingSoftButtonStyle())
        }
      }
    }
  }

  private var runningApplicationCount: Int? {
    selectedCatalogItem?.runningApplications.count
  }

  private var portDisplayMode: Binding<RoutingPortDisplayMode> {
    Binding(
      get: {
        switch channelPresentation {
        case .aggregate: .aggregate
        case .separate: .separate
        }
      },
      set: { mode in
        switch mode {
        case .aggregate:
          setChannelPresentation(.aggregate)
        case .separate:
          setChannelPresentation(.separate(channelCount: channelPresentation.channelCount ?? 2))
        }
      }
    )
  }

  private var separateChannelCount: Binding<Int> {
    Binding(
      get: { channelPresentation.channelCount ?? 2 },
      set: { setChannelPresentation(.separate(channelCount: $0)) }
    )
  }

  @ViewBuilder
  private var applicationPickerContent: some View {
    if applicationCatalog.state.isLoading, catalogItems.isEmpty {
      HStack(spacing: 9) {
        ProgressView()
          .controlSize(.small)
        Text("Discovering applications…")
          .foregroundStyle(FlowingPalette.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else if let errorMessage = applicationCatalog.state.rootErrorMessage, catalogItems.isEmpty {
      FlowingCallout(
        errorMessage,
        title: "Applications unavailable",
        tone: .warning
      )
    } else {
      InstalledApplicationSearchPicker(
        items: catalogItems,
        selection: pickerSelection,
        iconResolver: iconResolver,
        maximumVisibleOptions: 8
      )
    }
  }

  private var pickerSelection: Binding<String> {
    Binding(
      get: { selectedCatalogItem?.application.bundleURL.absoluteString ?? "" },
      set: { selectedID in
        guard selectedID != selectedCatalogItem?.application.bundleURL.absoluteString else {
          return
        }
        selectApplication(selection(for: selectedID))
      }
    )
  }

  private func selection(for selectedID: String) -> RoutingApplicationSelection? {
    guard !selectedID.isEmpty,
      let application = catalogItems.first(where: {
        $0.application.bundleURL.absoluteString == selectedID
      })?.application
    else {
      return nil
    }
    return RoutingApplicationSelection(
      stableID: application.bundleURL.absoluteString,
      applicationURL: application.bundleURL,
      bundleIdentifier: application.bundleIdentifier,
      displayName: application.displayName
    )
  }
}

private struct SelectedInputAudioInspector: View {
  let nodeID: UUID
  let selection: RoutingInputDeviceSelection?
  let channelPresentation: RoutingChannelPresentation
  let isWorkflowRunning: Bool
  let isRouted: Bool
  let audioCatalog: AudioCatalogController
  let captureController: RoutingInputCaptureController
  let channelControls: [Int: RoutingAudioChannelControl]
  let selectDevice: (RoutingInputDeviceSelection?) -> Void
  let setChannelPresentation: (RoutingChannelPresentation) -> Void
  let setChannelGain: (Int, Double) -> Void
  let setChannelMuted: (Int, Bool) -> Void

  private var devices: [AudioDevice] {
    audioCatalog.state.snapshot?.inputDevices ?? []
  }

  private var selectedDevice: AudioDevice? {
    guard let selection else { return nil }
    return devices.first { $0.id == selection.id }
  }

  var body: some View {
    FlowingCard(
      spacing: 14,
      contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    ) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Input Audio")
            .font(.headline)
            .foregroundStyle(FlowingPalette.ink)
          Text("Choose any hardware or virtual input device.")
            .font(.caption)
            .foregroundStyle(FlowingPalette.muted)
        }

        Spacer(minLength: 4)

        if selectedDevice?.isAlive == true {
          Circle()
            .fill(Color(nsColor: .systemGreen))
            .frame(width: 9, height: 9)
            .accessibilityLabel("Available")
        }
      }

      devicePickerContent

      if let selectedDevice, let endpoint = selectedDevice.input {
        Text(
          "\(endpoint.channelCount) ch · "
            + "\(selectedDevice.nominalSampleRate.formatted()) Hz"
            + (endpoint.isDefault ? " · Default Input" : "")
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(FlowingPalette.muted)
      }

      captureContent

      if let mutedChannelDescription {
        FlowingCallout(
          "Unmute the channel or raise its gain before expecting audible output.",
          title: "\(mutedChannelDescription) muted",
          systemImage: "speaker.slash.fill",
          tone: .neutral
        )
      }

      Divider()
        .overlay(FlowingPalette.hairline)

      VStack(alignment: .leading, spacing: 9) {
        Text("Output Ports")
          .font(.caption.weight(.semibold))
          .foregroundStyle(FlowingPalette.muted)

        FlowingSegmentedControl(
          label: "Output port presentation",
          selection: portDisplayMode,
          options: [
            FlowingSegmentOption(.aggregate, label: "All Channels"),
            FlowingSegmentOption(.separate, label: "Separate"),
          ]
        )

        if case .separate = channelPresentation {
          HStack {
            Text("Channels")
              .font(.caption)
              .foregroundStyle(FlowingPalette.muted)
            Spacer(minLength: 8)
            FlowingStepper(
              "Output channel count",
              value: separateChannelCount,
              in: 1...RoutingVisualizerConfiguration.maximumAvailableChannelCount,
              step: 1
            )
          }
        }

        Text("The device's live format replaces this preview when capture starts.")
          .font(.caption2)
          .foregroundStyle(FlowingPalette.faint)
      }

      if case .separate(let channelCount) = channelPresentation {
        Divider()
          .overlay(FlowingPalette.hairline)
        RoutingAudioChannelControlsView(
          channelCount: channelCount,
          controls: channelControls,
          setGain: setChannelGain,
          setMuted: setChannelMuted
        )
      }
    }
    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
  }

  @ViewBuilder
  private var devicePickerContent: some View {
    if audioCatalog.state.isInitialLoad, devices.isEmpty {
      HStack(spacing: 9) {
        ProgressView()
          .controlSize(.small)
        Text("Discovering input devices…")
          .foregroundStyle(FlowingPalette.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else if let errorMessage = audioCatalog.state.rootErrorMessage, devices.isEmpty {
      FlowingCallout(
        errorMessage,
        title: "Input devices unavailable",
        tone: .warning
      )
    } else {
      FlowingSearchPicker(
        label: "Input Devices",
        selection: pickerSelection,
        options: pickerOptions,
        maximumVisibleOptions: 8
      )
    }
  }

  @ViewBuilder
  private var captureContent: some View {
    if !isWorkflowRunning, isRouted, selection != nil {
      FlowingCallout(
        "Run this workflow to open the input device and start routed playback.",
        title: "Workflow Paused",
        systemImage: "pause.circle",
        tone: .neutral
      )
    } else {
      captureStateContent
    }
  }

  @ViewBuilder
  private var captureStateContent: some View {
    switch captureController.state(for: nodeID) {
    case .idle:
      if isRouted, selectedDevice?.isAlive == true {
        HStack(spacing: 9) {
          ProgressView()
            .controlSize(.small)
          Text("Preparing input capture…")
            .font(.caption)
            .foregroundStyle(FlowingPalette.muted)
        }
      } else if isRouted, selection != nil {
        FlowingCallout(
          "Reconnect or enable the selected device to resume this route.",
          title: "Input device unavailable",
          systemImage: "waveform.badge.exclamationmark",
          tone: .neutral
        )
      } else if selection != nil {
        FlowingCallout(
          "Connect an output port to another audio node to begin capture.",
          title: "Ready to Route",
          systemImage: "point.3.connected.trianglepath.dotted",
          tone: .neutral
        )
      }
    case .starting:
      HStack(spacing: 9) {
        ProgressView()
          .controlSize(.small)
        Text("Opening the input device…")
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }
    case .running(let format):
      HStack(spacing: 9) {
        Circle()
          .fill(Color(nsColor: .systemGreen))
          .frame(width: 9, height: 9)
        VStack(alignment: .leading, spacing: 2) {
          Text("Capturing \(format.channelIDs.count) channels")
            .font(.caption.weight(.semibold))
            .foregroundStyle(FlowingPalette.ink)
          Text("\(format.sampleRate.formatted()) Hz")
            .font(.caption2)
            .foregroundStyle(FlowingPalette.muted)
          if captureController.consumerCount(for: nodeID) > 1 {
            Text("Shared by \(captureController.consumerCount(for: nodeID)) nodes")
              .font(.caption2)
              .foregroundStyle(FlowingPalette.faint)
          }
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Capturing input audio")
    case .failed(let failure):
      VStack(alignment: .leading, spacing: 8) {
        FlowingCallout(
          failure.message,
          title: "Input capture failed",
          systemImage: "exclamationmark.triangle",
          tone: .warning
        )
        if isRouted, selection?.id != nil {
          Button("Try Again") {
            captureController.retry(nodeID: nodeID)
          }
          .buttonStyle(FlowingSoftButtonStyle())
        }
      }
    }
  }

  private var mutedChannelDescription: String? {
    let mutedChannels =
      channelControls
      .filter(\.value.isMuted)
      .keys
      .sorted()
      .map { mutedChannelLabel($0, channelCount: channelPresentation.channelCount ?? 1) }
    guard !mutedChannels.isEmpty else { return nil }
    return mutedChannels.formatted(.list(type: .and))
  }

  private func mutedChannelLabel(_ index: Int, channelCount: Int) -> String {
    if channelCount == 2 {
      return index == 0 ? "Left channel" : "Right channel"
    }
    return "Channel \(index + 1)"
  }

  private var pickerSelection: Binding<String> {
    Binding(
      get: { selection?.id.rawValue ?? "" },
      set: { selectedID in
        guard selectedID != selection?.id.rawValue else { return }
        selectDevice(selection(for: selectedID))
      }
    )
  }

  private var pickerOptions: [FlowingSelectOption<String>] {
    [FlowingSelectOption("", label: "No Input Device")]
      + devices.map { device in
        let suffix = device.input?.isDefault == true ? " · Default" : ""
        return FlowingSelectOption(
          device.id.rawValue,
          label: device.name + suffix
        )
      }
  }

  private var portDisplayMode: Binding<RoutingPortDisplayMode> {
    Binding(
      get: {
        switch channelPresentation {
        case .aggregate: .aggregate
        case .separate: .separate
        }
      },
      set: { mode in
        switch mode {
        case .aggregate:
          setChannelPresentation(.aggregate)
        case .separate:
          let deviceChannels = selectedDevice?.input?.channelCount
          setChannelPresentation(
            .separate(channelCount: channelPresentation.channelCount ?? deviceChannels ?? 2)
          )
        }
      }
    )
  }

  private var separateChannelCount: Binding<Int> {
    Binding(
      get: { channelPresentation.channelCount ?? selectedDevice?.input?.channelCount ?? 2 },
      set: { setChannelPresentation(.separate(channelCount: $0)) }
    )
  }

  private func selection(for selectedID: String) -> RoutingInputDeviceSelection? {
    guard !selectedID.isEmpty,
      let device = devices.first(where: { $0.id.rawValue == selectedID })
    else { return nil }
    return RoutingInputDeviceSelection(id: device.id, displayName: device.name)
  }
}

private enum RoutingOutputCapturePickerValue: Hashable {
  case none
  case systemDefault
  case device(AudioDeviceID)
}

private struct SelectedSystemOutputInspector: View {
  let nodeID: UUID
  let selection: RoutingOutputCaptureSelection?
  let channelPresentation: RoutingChannelPresentation
  let isWorkflowRunning: Bool
  let isRouted: Bool
  let audioCatalog: AudioCatalogController
  let captureController: RoutingOutputCaptureController
  let channelControls: [Int: RoutingAudioChannelControl]
  let selectOutput: (RoutingOutputCaptureSelection?) -> Void
  let setChannelPresentation: (RoutingChannelPresentation) -> Void
  let setChannelGain: (Int, Double) -> Void
  let setChannelMuted: (Int, Bool) -> Void

  private var devices: [AudioDevice] {
    audioCatalog.state.snapshot?.outputDevices ?? []
  }

  private var defaultDevice: AudioDevice? {
    devices.first { $0.output?.isDefault == true }
  }

  private var selectedDevice: AudioDevice? {
    switch selection {
    case .systemDefault:
      defaultDevice
    case .device(let selection):
      devices.first { $0.id == selection.id }
    case nil:
      nil
    }
  }

  private var selectedDeviceName: String? {
    selectedDevice?.name ?? selection?.displayName
  }

  var body: some View {
    FlowingCard(
      spacing: 14,
      contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    ) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("System Output")
            .font(.headline)
            .foregroundStyle(FlowingPalette.ink)
          Text("Capture the mix playing through the system default or a specific output device.")
            .font(.caption)
            .foregroundStyle(FlowingPalette.muted)
        }

        Spacer(minLength: 4)

        if selectedDevice?.isAlive == true {
          Circle()
            .fill(Color(nsColor: .systemGreen))
            .frame(width: 9, height: 9)
            .accessibilityLabel("Output source available")
        }
      }

      pickerContent

      if let selectedDevice, let endpoint = selectedDevice.output {
        Text(
          "\(streamZeroChannelCount(for: selectedDevice, endpoint: endpoint)) ch · "
            + "\(selectedDevice.nominalSampleRate.formatted()) Hz"
            + (endpoint.isDefault ? " · Current Default" : "")
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(FlowingPalette.muted)
      } else if selection != nil, let selectedDeviceName {
        Text("\(selectedDeviceName) · Unavailable")
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }

      captureContent

      if let mutedChannelDescription {
        FlowingCallout(
          "Unmute the channel or raise its gain before expecting audible output.",
          title: "\(mutedChannelDescription) muted",
          systemImage: "speaker.slash.fill",
          tone: .neutral
        )
      }

      Divider()
        .overlay(FlowingPalette.hairline)

      VStack(alignment: .leading, spacing: 9) {
        Text("Output Ports")
          .font(.caption.weight(.semibold))
          .foregroundStyle(FlowingPalette.muted)

        FlowingSegmentedControl(
          label: "Output port presentation",
          selection: portDisplayMode,
          options: [
            FlowingSegmentOption(.aggregate, label: "All Channels"),
            FlowingSegmentOption(.separate, label: "Separate"),
          ]
        )

        if case .separate = channelPresentation {
          HStack {
            Text("Channels")
              .font(.caption)
              .foregroundStyle(FlowingPalette.muted)
            Spacer(minLength: 8)
            FlowingStepper(
              "Output channel count",
              value: separateChannelCount,
              in: 1...RoutingVisualizerConfiguration.maximumAvailableChannelCount,
              step: 1
            )
          }
        }

        Text("The captured stream's live format replaces this preview when capture starts.")
          .font(.caption2)
          .foregroundStyle(FlowingPalette.faint)
      }

      if case .separate(let channelCount) = channelPresentation {
        Divider()
          .overlay(FlowingPalette.hairline)
        RoutingAudioChannelControlsView(
          channelCount: channelCount,
          controls: channelControls,
          setGain: setChannelGain,
          setMuted: setChannelMuted
        )
      }
    }
    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
  }

  @ViewBuilder
  private var pickerContent: some View {
    if audioCatalog.state.isInitialLoad, devices.isEmpty {
      HStack(spacing: 9) {
        ProgressView()
          .controlSize(.small)
        Text("Discovering output devices…")
          .foregroundStyle(FlowingPalette.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else if let errorMessage = audioCatalog.state.rootErrorMessage, devices.isEmpty {
      FlowingCallout(errorMessage, title: "Output devices unavailable", tone: .warning)
    } else {
      FlowingSearchPicker(
        label: "Output Capture Source",
        selection: pickerSelection,
        options: pickerOptions,
        maximumVisibleOptions: 8
      )
    }
  }

  @ViewBuilder
  private var captureContent: some View {
    if !isWorkflowRunning, isRouted, selection != nil {
      FlowingCallout(
        "Run this workflow to start capturing the selected output source.",
        title: "Workflow Paused",
        systemImage: "pause.circle",
        tone: .neutral
      )
    } else {
      captureStateContent
    }
  }

  @ViewBuilder
  private var captureStateContent: some View {
    switch captureController.state(for: nodeID) {
    case .idle:
      if isRouted, selectedDevice?.isAlive == true {
        HStack(spacing: 9) {
          ProgressView()
            .controlSize(.small)
          Text("Preparing system output capture…")
            .font(.caption)
            .foregroundStyle(FlowingPalette.muted)
        }
      } else if isRouted, selection != nil {
        FlowingCallout(
          "Choose an available output device or wait for a system default to become available.",
          title: "Output source unavailable",
          systemImage: "speaker.badge.exclamationmark",
          tone: .neutral
        )
      } else if selection != nil {
        FlowingCallout(
          "Connect an output port to another audio node to begin capture.",
          title: "Ready to Route",
          systemImage: "point.3.connected.trianglepath.dotted",
          tone: .neutral
        )
      }
    case .starting:
      HStack(spacing: 9) {
        ProgressView()
          .controlSize(.small)
        Text("Opening the output-device tap…")
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }
    case .running(let format):
      HStack(spacing: 9) {
        Circle()
          .fill(Color(nsColor: .systemGreen))
          .frame(width: 9, height: 9)
        VStack(alignment: .leading, spacing: 2) {
          Text("Capturing \(format.channelIDs.count) channels")
            .font(.caption.weight(.semibold))
            .foregroundStyle(FlowingPalette.ink)
          Text("\(format.sampleRate.formatted()) Hz")
            .font(.caption2)
            .foregroundStyle(FlowingPalette.muted)
          if captureController.consumerCount(for: nodeID) > 1 {
            Text("Shared by \(captureController.consumerCount(for: nodeID)) nodes")
              .font(.caption2)
              .foregroundStyle(FlowingPalette.faint)
          }
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel("Capturing system output audio")
    case .failed(let failure):
      VStack(alignment: .leading, spacing: 8) {
        FlowingCallout(
          failure.message,
          title: "System output capture failed",
          systemImage: "exclamationmark.triangle",
          tone: .warning
        )
        if isRouted {
          Button("Try Again") {
            captureController.retry(nodeID: nodeID)
          }
          .buttonStyle(FlowingSoftButtonStyle())
        }
      }
    }
  }

  private var pickerSelection: Binding<RoutingOutputCapturePickerValue> {
    Binding(
      get: {
        switch selection {
        case .systemDefault: .systemDefault
        case .device(let device): .device(device.id)
        case nil: .none
        }
      },
      set: { value in
        switch value {
        case .none:
          selectOutput(nil)
        case .systemDefault:
          selectOutput(.systemDefault)
        case .device(let deviceID):
          guard let device = devices.first(where: { $0.id == deviceID }) else { return }
          selectOutput(
            .device(RoutingOutputDeviceSelection(id: device.id, displayName: device.name))
          )
        }
      }
    )
  }

  private var pickerOptions: [FlowingSelectOption<RoutingOutputCapturePickerValue>] {
    var options: [FlowingSelectOption<RoutingOutputCapturePickerValue>] = [
      FlowingSelectOption(.none, label: "No Output Source"),
      FlowingSelectOption(
        .systemDefault,
        label: defaultDevice.map { "Follow System Default · \($0.name)" }
          ?? "Follow System Default · Unavailable"
      ),
    ]
    if case .device(let pinned) = selection,
      !devices.contains(where: { $0.id == pinned.id })
    {
      options.append(
        FlowingSelectOption(.device(pinned.id), label: "\(pinned.displayName) · Unavailable")
      )
    }
    options.append(
      contentsOf: devices.map { device in
        FlowingSelectOption(
          .device(device.id),
          label: device.name + (device.output?.isDefault == true ? " · Current Default" : "")
        )
      }
    )
    return options
  }

  private var portDisplayMode: Binding<RoutingPortDisplayMode> {
    Binding(
      get: {
        switch channelPresentation {
        case .aggregate: .aggregate
        case .separate: .separate
        }
      },
      set: { mode in
        switch mode {
        case .aggregate:
          setChannelPresentation(.aggregate)
        case .separate:
          setChannelPresentation(
            .separate(channelCount: channelPresentation.channelCount ?? previewChannelCount)
          )
        }
      }
    )
  }

  private var separateChannelCount: Binding<Int> {
    Binding(
      get: { channelPresentation.channelCount ?? previewChannelCount },
      set: { setChannelPresentation(.separate(channelCount: $0)) }
    )
  }

  private var previewChannelCount: Int {
    guard let device = selectedDevice, let endpoint = device.output else { return 2 }
    return max(1, streamZeroChannelCount(for: device, endpoint: endpoint))
  }

  private func streamZeroChannelCount(
    for device: AudioDevice,
    endpoint: AudioDeviceEndpoint
  ) -> Int {
    if let count = endpoint.streams.first?.virtualFormat?.channelsPerFrame, count > 0 {
      return Int(count)
    }
    let mappedCount = endpoint.channels.count {
      $0.streamID?.index == AudioStreamIndex(rawValue: 0)
    }
    return mappedCount > 0 ? mappedCount : endpoint.channelCount
  }

  private var mutedChannelDescription: String? {
    let mutedChannels = channelControls.filter(\.value.isMuted).keys.sorted().map { index in
      if channelPresentation.channelCount == 2 {
        return index == 0 ? "Left channel" : "Right channel"
      }
      return "Channel \(index + 1)"
    }
    guard !mutedChannels.isEmpty else { return nil }
    return mutedChannels.formatted(.list(type: .and))
  }
}

private struct SelectedVirtualAudioEndpointInspector: View {
  let direction: VirtualAudioEndpointDirection
  let selection: RoutingVirtualAudioEndpointSelection?
  let channelPresentation: RoutingChannelPresentation
  let controller: RilliyaVirtualAudioController
  let state: RoutingInputCaptureState?
  let selectEndpoint: (RoutingVirtualAudioEndpointSelection?) -> Void
  let setChannelPresentation: (RoutingChannelPresentation) -> Void

  private var title: String {
    direction == .output ? "Virtual Output" : "Virtual Input"
  }

  private var endpoints: [VirtualAudioEndpoint] {
    controller.catalog.endpoints.filter { $0.configuration.direction == direction }
  }

  private var selectedEndpoint: VirtualAudioEndpoint? {
    guard let selection else { return nil }
    return endpoints.first { $0.id == selection.id }
  }

  var body: some View {
    FlowingCard(
      spacing: 14,
      contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    ) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
          .foregroundStyle(FlowingPalette.ink)
        Text(
          direction == .output
            ? "Receive audio played by other applications."
            : "Expose routed audio as an input for other applications."
        )
        .font(.caption)
        .foregroundStyle(FlowingPalette.muted)
      }

      driverContent

      if controller.availability == .available {
        endpointPicker

        if let selectedEndpoint {
          let format = selectedEndpoint.configuration.format
          Text("\(format.channelCount) ch · \(format.sampleRate.formatted()) Hz")
            .font(.caption.monospacedDigit())
            .foregroundStyle(FlowingPalette.muted)

          captureStateContent

          Divider()
            .overlay(FlowingPalette.hairline)

          VStack(alignment: .leading, spacing: 9) {
            Text(direction == .output ? "Output Ports" : "Input Ports")
              .font(.caption.weight(.semibold))
              .foregroundStyle(FlowingPalette.muted)

            FlowingSegmentedControl(
              label: "Port presentation",
              selection: portDisplayMode,
              options: [
                FlowingSegmentOption(.aggregate, label: "All Channels"),
                FlowingSegmentOption(.separate, label: "Separate"),
              ]
            )

            Text(
              "Separate uses the endpoint's configured \(format.channelCount) channels. "
                + "Change its format in Virtual Devices preferences."
            )
            .font(.caption2)
            .foregroundStyle(FlowingPalette.faint)
          }
        }
      }

      Button("Manage Virtual Devices") {
        RilliyaPreferencesWindowController.shared.showPreferences()
      }
      .buttonStyle(FlowingSoftButtonStyle())

      if let issue = controller.issue {
        FlowingCallout(issue, title: "Virtual audio unavailable", tone: .warning)
      }
    }
    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
    .task {
      await controller.refresh()
    }
  }

  @ViewBuilder
  private var driverContent: some View {
    switch controller.availability {
    case .available:
      if endpoints.isEmpty {
        FlowingCallout(
          "Create a \(direction == .output ? "virtual output" : "virtual input") in Preferences before selecting it here.",
          title: "No compatible virtual devices",
          systemImage: "waveform.badge.plus",
          tone: .neutral
        )
      }
    case .notInstalled:
      FlowingCallout(
        "Install Rilliya's clean-room audio driver before creating virtual devices.",
        title: "Driver required",
        systemImage: "externaldrive.badge.plus",
        tone: .warning
      )
      if controller.isInstallerBundled {
        Button("Open Driver Installer") {
          controller.openInstaller()
        }
        .buttonStyle(FlowingSoftButtonStyle())
      }
    case nil:
      HStack(spacing: 9) {
        ProgressView()
          .controlSize(.small)
        Text("Checking the virtual audio driver…")
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }
    }
  }

  private var endpointPicker: some View {
    FlowingSearchPicker(
      label: title,
      selection: pickerSelection,
      options: pickerOptions,
      maximumVisibleOptions: 8
    )
  }

  private var pickerSelection: Binding<String> {
    Binding(
      get: { selection?.id.rawValue.uuidString ?? "" },
      set: { selectedID in
        guard selectedID != selection?.id.rawValue.uuidString else { return }
        guard
          let endpoint = endpoints.first(where: {
            $0.id.rawValue.uuidString == selectedID
          })
        else {
          selectEndpoint(nil)
          return
        }
        selectEndpoint(
          RoutingVirtualAudioEndpointSelection(
            id: endpoint.id,
            displayName: endpoint.configuration.name
          )
        )
        if case .separate = channelPresentation {
          setChannelPresentation(
            .separate(channelCount: endpoint.configuration.format.channelCount)
          )
        }
      }
    )
  }

  private var pickerOptions: [FlowingSelectOption<String>] {
    [FlowingSelectOption("", label: "No \(title)")]
      + endpoints.map { endpoint in
        FlowingSelectOption(
          endpoint.id.rawValue.uuidString,
          label: endpoint.configuration.name
        )
      }
  }

  private var portDisplayMode: Binding<RoutingPortDisplayMode> {
    Binding(
      get: {
        switch channelPresentation {
        case .aggregate: .aggregate
        case .separate: .separate
        }
      },
      set: { mode in
        switch mode {
        case .aggregate:
          setChannelPresentation(.aggregate)
        case .separate:
          let channelCount = selectedEndpoint?.configuration.format.channelCount ?? 2
          setChannelPresentation(.separate(channelCount: channelCount))
        }
      }
    )
  }

  @ViewBuilder
  private var captureStateContent: some View {
    if let state {
      switch state {
      case .idle:
        EmptyView()
      case .starting:
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Preparing virtual output capture…")
            .font(.caption)
            .foregroundStyle(FlowingPalette.muted)
        }
      case .running(let format):
        Label(
          "Capturing \(format.channelIDs.count) ch · \(format.sampleRate.formatted()) Hz",
          systemImage: "waveform"
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(FlowingAccent.lagoon.foreground)
      case .failed(let failure):
        FlowingCallout(failure.message, title: "Virtual output stopped", tone: .warning)
      }
    }
  }
}

private struct SelectedOutputAudioInspector: View {
  let selection: RoutingOutputDeviceSelection?
  let channelPresentation: RoutingChannelPresentation
  let state: RoutingAudioOutputState
  let audioCatalog: AudioCatalogController
  let selectDevice: (RoutingOutputDeviceSelection?) -> Void
  let setChannelPresentation: (RoutingChannelPresentation) -> Void

  private var devices: [AudioDevice] {
    audioCatalog.state.snapshot?.outputDevices ?? []
  }

  private var selectedDevice: AudioDevice? {
    guard let selection else { return nil }
    return devices.first { $0.id == selection.id }
  }

  var body: some View {
    FlowingCard(
      spacing: 14,
      contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    ) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Output Audio")
            .font(.headline)
            .foregroundStyle(FlowingPalette.ink)
          Text("Choose any hardware or virtual output device.")
            .font(.caption)
            .foregroundStyle(FlowingPalette.muted)
        }

        Spacer(minLength: 4)

        if selectedDevice?.isAlive == true {
          Circle()
            .fill(Color(nsColor: .systemGreen))
            .frame(width: 9, height: 9)
            .accessibilityLabel("Available")
        }
      }

      devicePickerContent

      if let selectedDevice, let endpoint = selectedDevice.output {
        Text(
          "\(endpoint.channelCount) ch · "
            + "\(selectedDevice.nominalSampleRate.formatted()) Hz"
            + (endpoint.isDefault ? " · Default Output" : "")
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(FlowingPalette.muted)
      }

      outputStateContent

      Divider()
        .overlay(FlowingPalette.hairline)

      VStack(alignment: .leading, spacing: 9) {
        Text("Input Ports")
          .font(.caption.weight(.semibold))
          .foregroundStyle(FlowingPalette.muted)

        FlowingSegmentedControl(
          label: "Input port presentation",
          selection: portDisplayMode,
          options: [
            FlowingSegmentOption(.aggregate, label: "All Channels"),
            FlowingSegmentOption(.separate, label: "Separate"),
          ]
        )

        if case .separate = channelPresentation {
          HStack {
            Text("Channels")
              .font(.caption)
              .foregroundStyle(FlowingPalette.muted)
            Spacer(minLength: 8)
            FlowingStepper(
              "Input channel count",
              value: separateChannelCount,
              in: 1...RoutingVisualizerConfiguration.maximumAvailableChannelCount,
              step: 1
            )
          }
        }

        Text("Playback uses the selected device's live format when the route starts.")
          .font(.caption2)
          .foregroundStyle(FlowingPalette.faint)
      }
    }
    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
  }

  @ViewBuilder
  private var outputStateContent: some View {
    switch state {
    case .idle:
      EmptyView()
    case .waitingForCapture:
      Label("Waiting for routed capture", systemImage: "hourglass")
        .font(.caption)
        .foregroundStyle(FlowingPalette.muted)
    case .starting:
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Preparing output device…")
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }
    case .running(let format):
      Label(
        "Playing \(format.channelIDs.count) ch · \(format.sampleRate.formatted()) Hz",
        systemImage: "speaker.wave.2.fill"
      )
      .font(.caption.monospacedDigit())
      .foregroundStyle(FlowingAccent.fern.foreground)
    case .failed(let failure):
      FlowingCallout(failure.message, title: "Output stopped", tone: .warning)
    }
  }

  @ViewBuilder
  private var devicePickerContent: some View {
    if audioCatalog.state.isInitialLoad, devices.isEmpty {
      HStack(spacing: 9) {
        ProgressView()
          .controlSize(.small)
        Text("Discovering output devices…")
          .foregroundStyle(FlowingPalette.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    } else if let errorMessage = audioCatalog.state.rootErrorMessage, devices.isEmpty {
      FlowingCallout(
        errorMessage,
        title: "Output devices unavailable",
        tone: .warning
      )
    } else {
      FlowingSearchPicker(
        label: "Output Devices",
        selection: pickerSelection,
        options: pickerOptions,
        maximumVisibleOptions: 8
      )
    }
  }

  private var pickerSelection: Binding<String> {
    Binding(
      get: { selection?.id.rawValue ?? "" },
      set: { selectedID in
        guard selectedID != selection?.id.rawValue else { return }
        selectDevice(selection(for: selectedID))
      }
    )
  }

  private var pickerOptions: [FlowingSelectOption<String>] {
    [FlowingSelectOption("", label: "No Output Device")]
      + devices.map { device in
        let suffix = device.output?.isDefault == true ? " · Default" : ""
        return FlowingSelectOption(
          device.id.rawValue,
          label: device.name + suffix
        )
      }
  }

  private var portDisplayMode: Binding<RoutingPortDisplayMode> {
    Binding(
      get: {
        switch channelPresentation {
        case .aggregate: .aggregate
        case .separate: .separate
        }
      },
      set: { mode in
        switch mode {
        case .aggregate:
          setChannelPresentation(.aggregate)
        case .separate:
          let deviceChannels = selectedDevice?.output?.channelCount
          setChannelPresentation(
            .separate(channelCount: channelPresentation.channelCount ?? deviceChannels ?? 2)
          )
        }
      }
    )
  }

  private var separateChannelCount: Binding<Int> {
    Binding(
      get: { channelPresentation.channelCount ?? selectedDevice?.output?.channelCount ?? 2 },
      set: { setChannelPresentation(.separate(channelCount: $0)) }
    )
  }

  private func selection(for selectedID: String) -> RoutingOutputDeviceSelection? {
    guard !selectedID.isEmpty,
      let device = devices.first(where: { $0.id.rawValue == selectedID })
    else { return nil }
    return RoutingOutputDeviceSelection(id: device.id, displayName: device.name)
  }
}

private struct RoutingAudioChannelControlsView: View {
  let channelCount: Int
  let controls: [Int: RoutingAudioChannelControl]
  let setGain: (Int, Double) -> Void
  let setMuted: (Int, Bool) -> Void
  var footer = "Gain and mute belong to this node; shared captures remain unchanged."

  private var gainRange: ClosedRange<Double> {
    ClosedRange(
      uncheckedBounds: (
        lower: RoutingAudioChannelControl.minimumGainDecibels,
        upper: RoutingAudioChannelControl.maximumGainDecibels
      )
    )
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      Text("Channel Levels")
        .font(.caption.weight(.semibold))
        .foregroundStyle(FlowingPalette.muted)

      ScrollView {
        LazyVStack(spacing: 7) {
          ForEach(0..<max(channelCount, 1), id: \.self) { channelIndex in
            channelRow(channelIndex)
          }
        }
      }
      .scrollIndicators(channelCount > 5 ? .visible : .hidden)
      .frame(height: min(CGFloat(max(channelCount, 1)) * 37, 198))

      Text(footer)
        .font(.caption2)
        .foregroundStyle(FlowingPalette.faint)
    }
  }

  private func channelRow(_ channelIndex: Int) -> some View {
    let control = controls[channelIndex] ?? .unity
    return HStack(spacing: 8) {
      Text(channelLabel(channelIndex))
        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
        .foregroundStyle(FlowingPalette.muted)
        .frame(width: 34, alignment: .leading)

      FlowingSlider(
        "\(channelLabel(channelIndex)) gain",
        value: Binding(
          get: { control.gainDecibels },
          set: { setGain(channelIndex, $0) }
        ),
        in: gainRange,
        step: 1,
        formatValue: { value in
          String(format: "%+.0f dB", locale: Locale(identifier: "en_US_POSIX"), value)
        }
      )

      Text(control.gainDescription)
        .font(.system(size: 9, weight: .medium, design: .monospaced))
        .foregroundStyle(control.isMuted ? FlowingPalette.faint : FlowingPalette.muted)
        .frame(width: 42, alignment: .trailing)

      FlowingIconButton(
        control.isMuted
          ? "Unmute \(channelLabel(channelIndex))" : "Mute \(channelLabel(channelIndex))",
        systemImage: control.isMuted ? "speaker.slash.fill" : "speaker.wave.1",
        isSelected: control.isMuted
      ) {
        setMuted(channelIndex, !control.isMuted)
      }
    }
  }

  private func channelLabel(_ channelIndex: Int) -> String {
    if channelCount == 2 {
      return channelIndex == 0 ? "L" : "R"
    }
    return "Ch \(channelIndex + 1)"
  }
}

private struct SelectedAudioMixerInspector: View {
  let configuration: RoutingAudioMixerConfiguration
  let channelControls: [Int: RoutingAudioChannelControl]
  let updateConfiguration: (RoutingAudioMixerConfiguration) -> Void
  let setChannelGain: (Int, Double) -> Void
  let setChannelMuted: (Int, Bool) -> Void

  var body: some View {
    FlowingCard(
      spacing: 14,
      contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    ) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Audio Mixer")
          .font(.headline)
          .foregroundStyle(FlowingPalette.ink)
        Text("Sum independent sources into aligned output channels.")
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 7) {
        Text("Channel Layout")
          .font(.caption.weight(.semibold))
          .foregroundStyle(FlowingPalette.muted)
        FlowingSelect(
          label: "Mixer channel layout",
          selection: channelCount,
          options: [
            FlowingSelectOption(1, label: "Mono · 1 ch"),
            FlowingSelectOption(2, label: "Stereo · 2 ch"),
            FlowingSelectOption(4, label: "Quad · 4 ch"),
            FlowingSelectOption(6, label: "5.1 · 6 ch"),
            FlowingSelectOption(8, label: "7.1 · 8 ch"),
          ],
          minimumWidth: 164
        )
        .fixedSize(horizontal: false, vertical: true)
      }

      Divider()
        .overlay(FlowingPalette.hairline)

      RoutingAudioChannelControlsView(
        channelCount: configuration.channelCount,
        controls: channelControls,
        setGain: setChannelGain,
        setMuted: setChannelMuted,
        footer: "Gain and mute apply after summing this mixer output channel."
      )

      Text(
        "Inputs are summed without hidden normalization. Reduce channel gain to preserve headroom when combining correlated signals."
      )
      .font(.caption2)
      .foregroundStyle(FlowingPalette.faint)
    }
    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
  }

  private var channelCount: Binding<Int> {
    Binding(
      get: { configuration.channelCount },
      set: { channelCount in edit { $0.channelCount = channelCount } }
    )
  }

  /// Edits a copy rather than rebuilding, so a field this control does not know about cannot be
  /// dropped by editing an unrelated one.
  private func edit(_ change: (inout RoutingAudioMixerConfiguration) -> Void) {
    var updated = configuration
    change(&updated)
    updateConfiguration(updated)
  }
}

private struct SelectedGainInspector: View {
  let configuration: RoutingGainConfiguration
  let updateConfiguration: (RoutingGainConfiguration) -> Void

  var body: some View {
    FlowingCard(
      spacing: 14,
      contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    ) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Gain")
          .font(.headline)
          .foregroundStyle(FlowingPalette.ink)
        Text("Adjust an audio bus without changing its channel layout.")
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 7) {
        HStack {
          Text("Level")
            .font(.caption.weight(.semibold))
            .foregroundStyle(FlowingPalette.muted)
          Spacer(minLength: 8)
          Text(configuration.gainDescription)
            .font(.caption.monospacedDigit())
            .foregroundStyle(FlowingPalette.ink)
        }
        FlowingSlider(
          "Gain level",
          value: gain,
          in: (RoutingGainConfiguration
            .minimumGainDecibels...RoutingGainConfiguration.maximumGainDecibels),
          formatValue: { value in
            value <= RoutingGainConfiguration.minimumGainDecibels
              ? "negative infinity decibels"
              : "\(value.formatted(.number.precision(.fractionLength(1)))) decibels"
          }
        )
      }

      Divider()
        .overlay(FlowingPalette.hairline)

      FlowingSwitch("Mute output", isOn: isMuted)
      FlowingSwitch("Invert polarity", isOn: isPolarityInverted)

      FlowingCallout(
        "Level and mute changes use a short realtime ramp to avoid clicks. Polarity inversion changes sample sign and adds no extra render pass.",
        title: "Realtime Utility",
        systemImage: "plusminus",
        tone: .neutral
      )
    }
    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
  }

  private var gain: Binding<Double> {
    Binding(
      get: { configuration.gainDecibels },
      set: { gain in
        edit {
          $0.gainDecibels = min(
            max(gain, RoutingGainConfiguration.minimumGainDecibels),
            RoutingGainConfiguration.maximumGainDecibels
          )
        }
      }
    )
  }

  private var isMuted: Binding<Bool> {
    Binding(
      get: { configuration.isMuted },
      set: { isMuted in edit { $0.isMuted = isMuted } }
    )
  }

  private var isPolarityInverted: Binding<Bool> {
    Binding(
      get: { configuration.isPolarityInverted },
      set: { isPolarityInverted in edit { $0.isPolarityInverted = isPolarityInverted } }
    )
  }

  /// Edits a copy rather than rebuilding, so a field this control does not know about cannot be
  /// dropped by editing an unrelated one.
  private func edit(_ change: (inout RoutingGainConfiguration) -> Void) {
    var updated = configuration
    change(&updated)
    updateConfiguration(updated)
  }
}

private struct SelectedChannelRouterInspector: View {
  let configuration: RoutingChannelRouterConfiguration
  let updateConfiguration: (RoutingChannelRouterConfiguration) -> Void

  private let channelCountOptions = Array(
    RoutingChannelRouterConfiguration
      .minimumChannelCount...RoutingChannelRouterConfiguration.maximumChannelCount
  )

  var body: some View {
    FlowingCard(
      spacing: 14,
      contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    ) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Channel Router")
          .font(.headline)
          .foregroundStyle(FlowingPalette.ink)
        Text("Reorder, duplicate, or silence channels without mixing them.")
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(alignment: .top, spacing: 12) {
        channelCountPicker("Inputs", selection: inputChannelCount)
        channelCountPicker("Outputs", selection: outputChannelCount)
      }

      Divider()
        .overlay(FlowingPalette.hairline)

      VStack(alignment: .leading, spacing: 8) {
        Text("Output Mapping")
          .font(.caption.weight(.semibold))
          .foregroundStyle(FlowingPalette.muted)
        ForEach(0..<configuration.outputChannelCount, id: \.self) { outputChannel in
          HStack(spacing: 10) {
            Text("Out \(outputChannel + 1)")
              .font(.system(.caption, design: .monospaced, weight: .semibold))
              .foregroundStyle(FlowingPalette.muted)
              .frame(width: 42, alignment: .leading)
            FlowingSelect(
              label: "Source for output channel \(outputChannel + 1)",
              selection: sourceBinding(for: outputChannel),
              options: sourceOptions,
              minimumWidth: 146
            )
            .fixedSize(horizontal: false, vertical: true)
          }
        }
      }

      FlowingCallout(
        "One input may feed several outputs. Choose Silence to drop an output. Combining multiple inputs belongs to Audio Mixer, so routing never changes level implicitly.",
        title: "Deterministic Mapping",
        systemImage: "arrow.left.arrow.right",
        tone: .neutral
      )
    }
    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
  }

  private func channelCountPicker(_ title: String, selection: Binding<Int>) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(FlowingPalette.muted)
      FlowingSelect(
        label: "\(title) channel count",
        selection: selection,
        options: channelCountOptions.map { count in
          FlowingSelectOption(count, label: channelCountLabel(count))
        },
        minimumWidth: 128
      )
      .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var inputChannelCount: Binding<Int> {
    Binding(
      get: { configuration.inputChannelCount },
      set: { count in
        updateConfiguration(
          configuration.resized(
            inputChannelCount: count,
            outputChannelCount: configuration.outputChannelCount
          )
        )
      }
    )
  }

  private var outputChannelCount: Binding<Int> {
    Binding(
      get: { configuration.outputChannelCount },
      set: { count in
        updateConfiguration(
          configuration.resized(
            inputChannelCount: configuration.inputChannelCount,
            outputChannelCount: count
          )
        )
      }
    )
  }

  private var sourceOptions: [FlowingSelectOption<Int?>] {
    [FlowingSelectOption(nil, label: "Silence")]
      + (0..<configuration.inputChannelCount).map { channel in
        FlowingSelectOption(Optional(channel), label: "Input \(channel + 1)")
      }
  }

  private func sourceBinding(for outputChannel: Int) -> Binding<Int?> {
    Binding(
      get: { configuration.outputSources[outputChannel] },
      set: { source in
        updateConfiguration(configuration.routing(sourceChannel: source, to: outputChannel))
      }
    )
  }

  private func channelCountLabel(_ count: Int) -> String {
    switch count {
    case 1: "Mono · 1 ch"
    case 2: "Stereo · 2 ch"
    case 4: "Quad · 4 ch"
    case 6: "5.1 · 6 ch"
    case 8: "7.1 · 8 ch"
    default: "\(count) channels"
    }
  }
}

private struct SelectedPeakLevelInspector: View {
  let signal: RoutingPeakLevelSignal?

  var body: some View {
    FlowingCard(
      spacing: 14,
      contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    ) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Peak Level")
          .font(.headline)
          .foregroundStyle(FlowingPalette.ink)
        Text("Greatest absolute sample across the connected audio bus.")
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 10) {
        peakValue("Linear", value: signal?.linearDescription ?? "—")
        peakValue("Level", value: signal?.decibelsDescription ?? "Waiting")
      }

      FlowingCallout(
        signal == nil
          ? "Connect one audio output to begin measuring."
          : "The graph outputs the unsmoothed linear value. dBFS is shown only for reference.",
        title: signal?.isClipping == true ? "Clipping" : "Current Block",
        systemImage: signal?.isClipping == true ? "exclamationmark.triangle" : "waveform.path",
        tone: signal?.isClipping == true ? .warning : .neutral
      )
    }
    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
  }

  private func peakValue(_ label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(label.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(FlowingPalette.faint)
      Text(value)
        .font(.system(.callout, design: .monospaced, weight: .semibold))
        .foregroundStyle(FlowingPalette.ink)
        .lineLimit(1)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      FlowingPalette.field,
      in: RoundedRectangle(cornerRadius: 9, style: .continuous)
    )
  }
}

private struct SelectedSignalGeneratorInspector: View {
  let configuration: RoutingSignalGeneratorConfiguration
  let updateConfiguration: (RoutingSignalGeneratorConfiguration) -> Void

  var body: some View {
    FlowingCard(
      spacing: 14,
      contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    ) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Signal Generator")
          .font(.headline)
          .foregroundStyle(FlowingPalette.ink)
        Text("Create a realtime test tone or a deterministic noise source.")
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 7) {
        Text("Waveform")
          .font(.caption.weight(.semibold))
          .foregroundStyle(FlowingPalette.muted)
        FlowingSelect(
          label: "Generator waveform",
          selection: waveform,
          options: AudioSignalGeneratorWaveform.allCases.map {
            FlowingSelectOption($0, label: $0.displayName)
          },
          minimumWidth: 164
        )
        .fixedSize(horizontal: false, vertical: true)
      }

      if configuration.waveform.usesFrequency {
        generatorSlider(
          title: "Frequency",
          value: frequencyPosition,
          range: 0...1,
          formattedValue: "\(frequencyDescription) Hz",
          accessibilityFormat: { _ in "\(frequencyDescription) hertz" }
        )
      }

      generatorSlider(
        title: "Amplitude",
        value: amplitude,
        range: 0...1,
        formattedValue: "\(Int((configuration.amplitude * 100).rounded()))%",
        accessibilityFormat: { value in "\(Int((value * 100).rounded())) percent" }
      )

      FlowingCallout(
        "Connect the mono output to an Output Audio node to render it. Keep amplitude below full scale when mixing sources.",
        title: "Realtime Source",
        systemImage: "waveform.path",
        tone: .neutral
      )
    }
    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
  }

  private func generatorSlider(
    title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    formattedValue: String,
    accessibilityFormat: @escaping (Double) -> String
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(FlowingPalette.muted)
        Spacer(minLength: 8)
        Text(formattedValue)
          .font(.caption.monospacedDigit())
          .foregroundStyle(FlowingPalette.ink)
      }
      FlowingSlider(
        title,
        value: value,
        in: range,
        formatValue: accessibilityFormat
      )
    }
  }

  private var waveform: Binding<AudioSignalGeneratorWaveform> {
    Binding(
      get: { configuration.waveform },
      set: { waveform in
        var updated = configuration
        updated.waveform = waveform
        updateConfiguration(updated)
      }
    )
  }

  private var frequencyPosition: Binding<Double> {
    let minimum = RoutingSignalGeneratorConfiguration.minimumFrequency
    let maximum = RoutingSignalGeneratorConfiguration.maximumFrequency
    let span = log(maximum / minimum)
    return Binding(
      get: { log(configuration.frequency / minimum) / span },
      set: { position in
        var updated = configuration
        updated.frequency = minimum * exp(min(max(position, 0), 1) * span)
        updateConfiguration(updated)
      }
    )
  }

  private var amplitude: Binding<Double> {
    Binding(
      get: { Double(configuration.amplitude) },
      set: { amplitude in
        var updated = configuration
        updated.amplitude = Float(min(max(amplitude, 0), 1))
        updateConfiguration(updated)
      }
    )
  }

  private var frequencyDescription: String {
    configuration.frequency.formatted(.number.precision(.fractionLength(0)))
  }
}

private struct SelectedFilePlaybackInspector: View {
  private enum LoopChoice: String, CaseIterable, Hashable {
    case once
    case finite
    case infinite

    var title: String {
      switch self {
      case .once: "Once"
      case .finite: "Repeat"
      case .infinite: "Continuous"
      }
    }
  }

  let configuration: RoutingFilePlaybackConfiguration
  let state: RoutingFilePlaybackState
  let channelControls: [Int: RoutingAudioChannelControl]
  let onRetry: () -> Void
  let updateConfiguration: (RoutingFilePlaybackConfiguration) -> Void
  let setVolume: (Double) -> Void
  let setMuted: (Bool) -> Void

  @State private var isInspectingFile = false
  @State private var fileIssue: String?

  var body: some View {
    FlowingCard(
      spacing: 14,
      contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    ) {
      VStack(alignment: .leading, spacing: 2) {
        Text("File Playback")
          .font(.headline)
          .foregroundStyle(FlowingPalette.ink)
        Text("Stream a Core Audio supported file without loading it all into memory.")
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(configuration.selection?.displayName ?? "No audio file selected")
            .font(.callout.weight(.medium))
            .foregroundStyle(FlowingPalette.ink)
            .lineLimit(1)
          if let selection = configuration.selection {
            Text(
              "\(selection.channelCount) ch · "
                + "\(selection.nativeSampleRate.formatted(.number.precision(.fractionLength(0)))) Hz"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(FlowingPalette.muted)
          }
        }
        Spacer(minLength: 8)
        if isInspectingFile {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Inspecting audio file")
        }
        Button {
          chooseFile()
        } label: {
          Label("Choose File", systemImage: "folder")
        }
        .buttonStyle(FlowingSoftButtonStyle())
        .disabled(isInspectingFile)
      }
      .padding(12)
      .background(
        FlowingPalette.field,
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )

      if let fileIssue {
        FlowingCallout(
          fileIssue,
          title: "File unavailable",
          systemImage: "exclamationmark.triangle",
          tone: .critical
        )
      }

      VStack(alignment: .leading, spacing: 7) {
        Text("Playback")
          .font(.caption.weight(.semibold))
          .foregroundStyle(FlowingPalette.muted)
        FlowingSelect(
          label: "File playback mode",
          selection: loopChoice,
          options: LoopChoice.allCases.map { FlowingSelectOption($0, label: $0.title) },
          minimumWidth: 164
        )
        .fixedSize(horizontal: false, vertical: true)
      }

      if loopChoice.wrappedValue == .finite {
        HStack {
          Text("Play count")
            .font(.caption.weight(.semibold))
            .foregroundStyle(FlowingPalette.muted)
          Spacer(minLength: 8)
          FlowingStepper(
            "File play count",
            value: playCount,
            in: RoutingFilePlaybackLoopMode.repeatedPlayCountRange,
            step: 1,
            formatValue: { "\($0)×" }
          )
        }
      }

      VStack(alignment: .leading, spacing: 7) {
        HStack {
          Text("Volume")
            .font(.caption.weight(.semibold))
            .foregroundStyle(FlowingPalette.muted)
          Spacer(minLength: 8)
          Text("\(Int(currentGain.rounded())) dB")
            .font(.caption.monospacedDigit())
            .foregroundStyle(FlowingPalette.ink)
        }
        FlowingSlider(
          "File volume",
          value: volume,
          in: volumeRange,
          formatValue: { "\(Int($0.rounded())) decibels" }
        )
        FlowingSwitch("Mute file playback", isOn: muted)
      }
      .disabled(configuration.selection == nil)

      FlowingCallout(
        statusDescription,
        title: statusTitle,
        systemImage: statusSymbol,
        tone: statusTone
      )
      if case .failed = state {
        Button("Try Again", action: onRetry)
          .buttonStyle(FlowingSoftButtonStyle())
      }
    }
    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
  }

  private var loopChoice: Binding<LoopChoice> {
    Binding(
      get: {
        switch configuration.loopMode {
        case .once: .once
        case .playCount: .finite
        case .infinite: .infinite
        }
      },
      set: { choice in
        var updated = configuration
        updated.loopMode =
          switch choice {
          case .once: .once
          case .finite: .playCount(2)
          case .infinite: .infinite
          }
        updateConfiguration(updated)
      }
    )
  }

  private var playCount: Binding<Int> {
    Binding(
      get: {
        guard case .playCount(let count) = configuration.loopMode else { return 2 }
        return count
      },
      set: { count in
        var updated = configuration
        updated.loopMode = .playCount(
          min(
            max(count, RoutingFilePlaybackLoopMode.repeatedPlayCountRange.lowerBound),
            RoutingFilePlaybackLoopMode.repeatedPlayCountRange.upperBound
          )
        )
        updateConfiguration(updated)
      }
    )
  }

  private var currentGain: Double {
    channelControls[0]?.gainDecibels ?? 0
  }

  private var volume: Binding<Double> {
    Binding(
      get: { currentGain },
      set: { value in setVolume(value) }
    )
  }

  private var volumeRange: ClosedRange<Double> {
    ClosedRange(
      uncheckedBounds: (
        RoutingAudioChannelControl.minimumGainDecibels,
        RoutingAudioChannelControl.maximumGainDecibels
      )
    )
  }

  private var muted: Binding<Bool> {
    Binding(
      get: { channelControls[0]?.isMuted ?? false },
      set: { value in setMuted(value) }
    )
  }

  private var statusTitle: String {
    switch state {
    case .idle: "Waiting for a route"
    case .preparing: "Preparing file"
    case .streaming: "Streaming"
    case .completed: "Playback complete"
    case .failed: "Playback stopped"
    }
  }

  private var statusDescription: String {
    switch state {
    case .idle:
      configuration.selection == nil
        ? "Choose a file, connect it to an output, then run the workflow."
        : "Connect this source to an Output Audio node and run the workflow."
    case .preparing:
      "Opening the file and preparing a bounded decoded-audio queue."
    case .streaming(let description):
      "Decoding \(description.channelCount) channels away from the realtime audio thread."
    case .completed:
      "Every requested file pass has reached the end. Run the workflow again to replay it."
    case .failed(let failure):
      failure.message
    }
  }

  private var statusSymbol: String {
    switch state {
    case .idle: "cable.connector"
    case .preparing: "hourglass"
    case .streaming: "play.fill"
    case .completed: "checkmark.circle"
    case .failed: "exclamationmark.triangle"
    }
  }

  private var statusTone: FlowingStatusTone {
    if case .failed = state { return .critical }
    return .neutral
  }

  private func chooseFile() {
    let panel = NSOpenPanel()
    panel.title = "Choose an Audio File"
    panel.prompt = "Choose"
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.audio]
    guard panel.runModal() == .OK, let url = panel.url else { return }

    isInspectingFile = true
    fileIssue = nil
    Task {
      do {
        let description = try await Task.detached(priority: .userInitiated) {
          try AudioFileFrameStream.inspect(url)
        }.value
        var updated = configuration
        updated.selection = RoutingAudioFileSelection(
          url: url,
          displayName: FileManager.default.displayName(atPath: url.path),
          channelCount: description.channelCount,
          nativeSampleRate: description.sampleRate
        )
        updateConfiguration(updated)
      } catch {
        fileIssue = error.localizedDescription
      }
      isInspectingFile = false
    }
  }
}

private struct SelectedFileOutputInspector: View {
  private enum EncodingChoice: String, CaseIterable, Hashable {
    case pcm16
    case pcm24
    case float32
    case aac
    case appleLossless

    var title: String {
      switch self {
      case .pcm16: "PCM 16-bit"
      case .pcm24: "PCM 24-bit"
      case .float32: "Float32 PCM"
      case .aac: "AAC"
      case .appleLossless: "Apple Lossless"
      }
    }
  }

  let configuration: RoutingFileOutputConfiguration
  let state: RoutingFileOutputState
  let onRetry: () -> Void
  let updateConfiguration: (RoutingFileOutputConfiguration) -> Void

  private let capabilities = AudioFileWritingCapabilities.current()

  var body: some View {
    FlowingCard(
      spacing: 14,
      contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    ) {
      VStack(alignment: .leading, spacing: 2) {
        Text("File Output")
          .font(.headline)
          .foregroundStyle(FlowingPalette.ink)
        Text("Encode routed audio on a bounded background writer.")
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text(configuration.destination?.displayName ?? "No destination selected")
            .font(.callout.weight(.medium))
            .foregroundStyle(FlowingPalette.ink)
            .lineLimit(1)
          Text("Existing recordings receive an unused numeric suffix.")
            .font(.caption2)
            .foregroundStyle(FlowingPalette.muted)
        }
        Spacer(minLength: 8)
        Button {
          chooseDestination()
        } label: {
          Label("Choose File", systemImage: "folder")
        }
        .buttonStyle(FlowingSoftButtonStyle())
      }
      .padding(12)
      .background(
        FlowingPalette.field,
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )

      VStack(alignment: .leading, spacing: 10) {
        labeledFileOutputControl("Container") {
          FlowingSelect(
            label: "File container",
            selection: container,
            options: availableContainers.map {
              FlowingSelectOption($0, label: $0.displayName)
            },
            minimumWidth: 150
          )
          .fixedSize(horizontal: false, vertical: true)
        }

        labeledFileOutputControl("Encoding") {
          FlowingSelect(
            label: "File encoding",
            selection: encodingChoice,
            options: availableEncodingChoices.map {
              FlowingSelectOption($0, label: $0.title)
            },
            minimumWidth: 150
          )
          .fixedSize(horizontal: false, vertical: true)
        }

        if case .aac = configuration.encoding {
          labeledFileOutputControl("Target Bitrate") {
            FlowingSelect(
              label: "AAC target bitrate",
              selection: aacBitRate,
              options: availableAACBitRates.map {
                FlowingSelectOption($0, label: "\($0 / 1_000) kbps")
              },
              minimumWidth: 150
            )
            .fixedSize(horizontal: false, vertical: true)
          }
        }

        if case .appleLossless = configuration.encoding {
          labeledFileOutputControl("Bit Depth") {
            FlowingSelect(
              label: "Apple Lossless bit depth",
              selection: losslessBitDepth,
              options: RoutingFileOutputConfiguration.losslessBitDepths.map {
                FlowingSelectOption($0, label: "\($0)-bit")
              },
              minimumWidth: 150
            )
            .fixedSize(horizontal: false, vertical: true)
          }
        }

        labeledFileOutputControl("Sample Rate") {
          FlowingSelect(
            label: "File sample rate",
            selection: sampleRate,
            options: RoutingFileOutputConfiguration.commonSampleRates.map {
              FlowingSelectOption(
                $0,
                label: sampleRateLabel($0)
              )
            },
            minimumWidth: 150
          )
          .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
          Text("Channels")
            .font(.caption.weight(.semibold))
            .foregroundStyle(FlowingPalette.muted)
          Spacer(minLength: 8)
          FlowingStepper(
            "File channel count",
            value: channelCount,
            in: 1...RoutingFileOutputConfiguration.maximumEditableChannelCount,
            step: 1
          )
        }
      }

      FlowingCallout(
        statusDescription,
        title: statusTitle,
        systemImage: statusSymbol,
        tone: statusTone
      )
      if case .failed = state {
        Button("Try Again", action: onRetry)
          .buttonStyle(FlowingSoftButtonStyle())
      }
    }
    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
  }

  private var availableEncodingChoices: [EncodingChoice] {
    switch configuration.container {
    case .wave:
      [.pcm16, .pcm24, .float32]
    case .aiff:
      [.pcm16, .pcm24]
    case .coreAudioFormat:
      [.pcm16, .pcm24, .float32]
    case .m4a:
      [
        capabilities.supportsAAC ? .aac : nil,
        capabilities.supportsAppleLossless ? .appleLossless : nil,
      ].compactMap { $0 }
    }
  }

  private var availableContainers: [AudioFileContainer] {
    AudioFileContainer.allCases.filter { container in
      container != .m4a || capabilities.supportsAAC || capabilities.supportsAppleLossless
    }
  }

  private var availableAACBitRates: [Int] {
    let common = capabilities.supportedAACBitRates(
      from: RoutingFileOutputConfiguration.commonAACBitRates
    )
    if !common.isEmpty { return common }
    return capabilities.aacBitRateRanges.first.map { [$0.lowerBound] } ?? []
  }

  private var preferredAACBitRate: Int {
    if availableAACBitRates.contains(RoutingFileOutputConfiguration.defaultAACBitRate) {
      return RoutingFileOutputConfiguration.defaultAACBitRate
    }
    return availableAACBitRates.first ?? RoutingFileOutputConfiguration.defaultAACBitRate
  }

  private var container: Binding<AudioFileContainer> {
    Binding(
      get: { configuration.container },
      set: { newContainer in
        var updated = configuration
        updated.container = newContainer
        updated.encoding = defaultEncoding(for: newContainer)
        if let destination = updated.destination {
          let url = destination.url.deletingPathExtension()
            .appendingPathExtension(newContainer.filenameExtension)
          updated.destination = RoutingAudioFileDestination(
            url: url,
            displayName: url.lastPathComponent
          )
        }
        updateConfiguration(updated)
      }
    )
  }

  private var encodingChoice: Binding<EncodingChoice> {
    Binding(
      get: {
        switch configuration.encoding {
        case .integerPCM(bitDepth: 16): .pcm16
        case .integerPCM: .pcm24
        case .float32PCM: .float32
        case .aac: .aac
        case .appleLossless: .appleLossless
        }
      },
      set: { choice in
        var updated = configuration
        updated.encoding = encoding(for: choice)
        updateConfiguration(updated)
      }
    )
  }

  private var aacBitRate: Binding<Int> {
    Binding(
      get: {
        guard case .aac(let bitRate) = configuration.encoding else {
          return preferredAACBitRate
        }
        return bitRate
      },
      set: { bitRate in
        var updated = configuration
        updated.encoding = .aac(bitRate: bitRate)
        updateConfiguration(updated)
      }
    )
  }

  private var losslessBitDepth: Binding<Int> {
    Binding(
      get: {
        guard case .appleLossless(let bitDepth) = configuration.encoding else {
          return RoutingFileOutputConfiguration.defaultBitDepth
        }
        return bitDepth
      },
      set: { bitDepth in
        var updated = configuration
        updated.encoding = .appleLossless(bitDepth: bitDepth)
        updateConfiguration(updated)
      }
    )
  }

  private var sampleRate: Binding<Double> {
    Binding(
      get: { configuration.sampleRate },
      set: { sampleRate in
        var updated = configuration
        updated.sampleRate = sampleRate
        updateConfiguration(updated)
      }
    )
  }

  private var channelCount: Binding<Int> {
    Binding(
      get: { configuration.channelCount },
      set: { count in
        var updated = configuration
        updated.channelCount = min(
          max(count, 1),
          RoutingFileOutputConfiguration.maximumEditableChannelCount
        )
        updateConfiguration(updated)
      }
    )
  }

  private func defaultEncoding(for container: AudioFileContainer) -> AudioFileEncoding {
    switch container {
    case .wave, .aiff, .coreAudioFormat:
      .integerPCM(bitDepth: RoutingFileOutputConfiguration.defaultBitDepth)
    case .m4a:
      capabilities.supportsAAC
        ? .aac(bitRate: preferredAACBitRate)
        : .appleLossless(bitDepth: RoutingFileOutputConfiguration.defaultBitDepth)
    }
  }

  private func encoding(for choice: EncodingChoice) -> AudioFileEncoding {
    switch choice {
    case .pcm16: .integerPCM(bitDepth: 16)
    case .pcm24: .integerPCM(bitDepth: RoutingFileOutputConfiguration.defaultBitDepth)
    case .float32: .float32PCM
    case .aac: .aac(bitRate: preferredAACBitRate)
    case .appleLossless:
      .appleLossless(bitDepth: RoutingFileOutputConfiguration.defaultBitDepth)
    }
  }

  private func sampleRateLabel(_ sampleRate: Double) -> String {
    let kilohertz = sampleRate / 1_000
    let fractionLength = kilohertz == kilohertz.rounded() ? 0 : 1
    return kilohertz.formatted(
      .number.precision(.fractionLength(fractionLength))
    ) + " kHz"
  }

  private var statusTitle: String {
    switch state {
    case .idle: "Ready to record"
    case .waitingForSource: "Waiting for audio"
    case .starting: "Preparing file"
    case .running: "Recording"
    case .failed: "Recording stopped"
    }
  }

  private var statusDescription: String {
    switch state {
    case .idle:
      configuration.destination == nil
        ? "Choose a destination, connect audio, then run the workflow."
        : "Connect routed audio and run the workflow to create a recording."
    case .waitingForSource:
      "The destination is ready when its upstream capture or stream becomes available."
    case .starting:
      "Creating the file and preparing a bounded encoder queue."
    case .running(let url):
      "Writing \(url.lastPathComponent) away from the realtime audio thread."
    case .failed(let failure):
      failure.message
    }
  }

  private var statusSymbol: String {
    switch state {
    case .idle: "cable.connector"
    case .waitingForSource: "hourglass"
    case .starting: "externaldrive.badge.timemachine"
    case .running: "record.circle.fill"
    case .failed: "exclamationmark.triangle"
    }
  }

  private var statusTone: FlowingStatusTone {
    if case .failed = state { return .critical }
    return .neutral
  }

  private func chooseDestination() {
    let panel = NSSavePanel()
    panel.title = "Choose an Audio File Destination"
    panel.prompt = "Choose"
    panel.nameFieldStringValue =
      configuration.destination?.url.deletingPathExtension().lastPathComponent
      ?? "Rilliya Recording"
    panel.allowedContentTypes = [
      UTType(filenameExtension: configuration.container.filenameExtension) ?? .audio
    ]
    guard panel.runModal() == .OK, var url = panel.url else { return }
    if url.pathExtension.lowercased() != configuration.container.filenameExtension {
      url = url.deletingPathExtension()
        .appendingPathExtension(configuration.container.filenameExtension)
    }
    var updated = configuration
    updated.destination = RoutingAudioFileDestination(
      url: url,
      displayName: url.lastPathComponent
    )
    updateConfiguration(updated)
  }
}

@ViewBuilder
private func labeledFileOutputControl<Content: View>(
  _ label: String,
  @ViewBuilder content: () -> Content
) -> some View {
  HStack(spacing: 10) {
    Text(label)
      .font(.caption.weight(.semibold))
      .foregroundStyle(FlowingPalette.muted)
    Spacer(minLength: 8)
    content()
  }
}

private struct SelectedNetworkSendInspector: View {
  let configuration: RoutingNetworkSendConfiguration
  let state: RoutingNetworkSendState
  let onRetry: () -> Void
  let updateConfiguration: (RoutingNetworkSendConfiguration) -> Void

  @State private var hostText: String
  @State private var portText: String

  init(
    configuration: RoutingNetworkSendConfiguration,
    state: RoutingNetworkSendState,
    onRetry: @escaping () -> Void,
    updateConfiguration: @escaping (RoutingNetworkSendConfiguration) -> Void
  ) {
    self.configuration = configuration
    self.state = state
    self.onRetry = onRetry
    self.updateConfiguration = updateConfiguration
    _hostText = State(initialValue: configuration.host)
    _portText = State(initialValue: String(configuration.port))
  }

  var body: some View {
    NetworkAudioInspectorCard(
      title: "Network Send",
      subtitle: "Send realtime PCM audio to one trusted LAN peer."
    ) {
      VStack(alignment: .leading, spacing: 12) {
        labeledField("Host") {
          FlowingTextField(
            "Destination host",
            text: $hostText,
            placeholder: "127.0.0.1",
            systemImage: "network",
            validation: hostIsValid ? .none : .error("Enter a host name or IP address."),
            onSubmit: commitAddress
          )
        }
        labeledField("UDP Port") {
          FlowingTextField(
            "Destination UDP port",
            text: $portText,
            placeholder: "48620",
            systemImage: "number",
            validation: parsedPort == nil ? .error("Use a port from 1 through 65535.") : .none,
            onSubmit: commitAddress
          )
        }
      }

      NetworkAudioFormatControls(
        sampleRate: sampleRate,
        channelCount: channelCount
      )

      NetworkAudioSecretControls(secret: configuration.secret) { secret in
        edit { $0.secret = secret }
      }

      FlowingCallout(
        stateDescription,
        title: stateTitle,
        systemImage: stateSymbol,
        tone: stateTone
      )
      if case .failed = state {
        Button("Try Again", action: onRetry)
          .buttonStyle(FlowingSoftButtonStyle())
      }

      Text(
        "Audio travels over UDP on a network you trust. It is never sent while the workflow is paused or the node has no connected source."
      )
      .font(.caption2)
      .foregroundStyle(FlowingPalette.faint)
    }
    .onChange(of: configuration) { _, updated in
      hostText = updated.host
      portText = String(updated.port)
    }
  }

  private var hostIsValid: Bool {
    !hostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var parsedPort: UInt16? {
    guard let value = UInt16(portText), value > 0 else { return nil }
    return value
  }

  /// Edits a copy rather than rebuilding, so a field this control does not know about — the
  /// shared key above all — cannot be dropped by editing an unrelated one.
  private func edit(_ change: (inout RoutingNetworkSendConfiguration) -> Void) {
    var updated = configuration
    change(&updated)
    updateConfiguration(updated)
  }

  private func commitAddress() {
    let host = hostText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !host.isEmpty, let port = parsedPort else { return }
    edit {
      $0.host = host
      $0.port = port
    }
  }

  private var sampleRate: Binding<Double> {
    Binding(
      get: { configuration.sampleRate },
      set: { sampleRate in edit { $0.sampleRate = sampleRate } }
    )
  }

  private var channelCount: Binding<Int> {
    Binding(
      get: { configuration.channelCount },
      set: { channelCount in edit { $0.channelCount = channelCount } }
    )
  }

  private var stateTitle: String {
    switch state {
    case .idle: "Waiting for workflow"
    case .waitingForSource: "Waiting for audio"
    case .starting: "Preparing sender"
    case .running: "Sending"
    case .failed: "Send stopped"
    }
  }

  private var stateDescription: String {
    switch state {
    case .idle: "Run the workflow to make this destination available."
    case .waitingForSource: "Connect an audio output to begin sending."
    case .starting: "Resolving the destination and preparing a bounded realtime queue."
    case .running(let format):
      "Sending \(format.channelCount) ch at \(Int(format.sampleRate.rounded())) Hz."
    case .failed(let failure): failure.message
    }
  }

  private var stateSymbol: String {
    switch state {
    case .idle, .waitingForSource: "cable.connector"
    case .starting: "hourglass"
    case .running: "paperplane.fill"
    case .failed: "exclamationmark.triangle"
    }
  }

  private var stateTone: FlowingStatusTone {
    if case .failed = state { return .critical }
    return .neutral
  }
}

private struct SelectedNetworkReceiveInspector: View {
  let configuration: RoutingNetworkReceiveConfiguration
  let state: RoutingNetworkReceiveState
  let onRetry: () -> Void
  let updateConfiguration: (RoutingNetworkReceiveConfiguration) -> Void

  @State private var portText: String

  init(
    configuration: RoutingNetworkReceiveConfiguration,
    state: RoutingNetworkReceiveState,
    onRetry: @escaping () -> Void,
    updateConfiguration: @escaping (RoutingNetworkReceiveConfiguration) -> Void
  ) {
    self.configuration = configuration
    self.state = state
    self.onRetry = onRetry
    self.updateConfiguration = updateConfiguration
    _portText = State(initialValue: String(configuration.port))
  }

  var body: some View {
    NetworkAudioInspectorCard(
      title: "Network Receive",
      subtitle: "Receive realtime PCM audio from one trusted LAN peer."
    ) {
      labeledField("UDP Port") {
        FlowingTextField(
          "Listening UDP port",
          text: $portText,
          placeholder: "48620",
          systemImage: "number",
          validation: parsedPort == nil ? .error("Use a port from 1 through 65535.") : .none,
          onSubmit: commitPort
        )
      }

      NetworkAudioFormatControls(
        sampleRate: sampleRate,
        channelCount: channelCount
      )

      NetworkAudioSecretControls(secret: configuration.secret) { secret in
        edit { $0.secret = secret }
      }

      FlowingCallout(
        stateDescription,
        title: stateTitle,
        systemImage: stateSymbol,
        tone: stateTone
      )
      if case .failed = state {
        Button("Try Again", action: onRetry)
          .buttonStyle(FlowingSoftButtonStyle())
      }

      Text(
        "Packets with an unexpected version, format, size, key, or active session are rejected before they reach the audio graph. Missing packets become silence."
      )
      .font(.caption2)
      .foregroundStyle(FlowingPalette.faint)
    }
    .onChange(of: configuration) { _, updated in
      portText = String(updated.port)
    }
  }

  private var parsedPort: UInt16? {
    guard let value = UInt16(portText), value > 0 else { return nil }
    return value
  }

  /// Edits a copy rather than rebuilding, so a field this control does not know about — the
  /// shared key above all — cannot be dropped by editing an unrelated one.
  private func edit(_ change: (inout RoutingNetworkReceiveConfiguration) -> Void) {
    var updated = configuration
    change(&updated)
    updateConfiguration(updated)
  }

  private func commitPort() {
    guard let port = parsedPort else { return }
    edit { $0.port = port }
  }

  private var sampleRate: Binding<Double> {
    Binding(
      get: { configuration.sampleRate },
      set: { sampleRate in edit { $0.sampleRate = sampleRate } }
    )
  }

  private var channelCount: Binding<Int> {
    Binding(
      get: { configuration.channelCount },
      set: { channelCount in edit { $0.channelCount = channelCount } }
    )
  }

  private var stateTitle: String {
    switch state {
    case .idle: "Waiting for workflow"
    case .starting: "Preparing receiver"
    case .running: "Listening"
    case .failed: "Receive stopped"
    }
  }

  private var stateDescription: String {
    switch state {
    case .idle: "Run the workflow and connect this source to start listening."
    case .starting: "Binding the UDP port and preparing a bounded jitter queue."
    case .running(let format):
      "Listening for \(format.channelCount) ch at \(Int(format.sampleRate.rounded())) Hz."
    case .failed(let failure): failure.message
    }
  }

  private var stateSymbol: String {
    switch state {
    case .idle: "cable.connector"
    case .starting: "hourglass"
    case .running: "network"
    case .failed: "exclamationmark.triangle"
    }
  }

  private var stateTone: FlowingStatusTone {
    if case .failed = state { return .critical }
    return .neutral
  }
}

private struct NetworkAudioFormatControls: View {
  @Binding var sampleRate: Double
  @Binding var channelCount: Int

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      labeledField("Sample Rate") {
        FlowingSelect(
          label: "Network sample rate",
          selection: $sampleRate,
          options: [44_100.0, 48_000.0, 96_000.0].map { rate in
            FlowingSelectOption(rate, label: "\(Int(rate / 1_000)) kHz")
          },
          minimumWidth: 116
        )
        .fixedSize(horizontal: false, vertical: true)
      }
      labeledField("Channels") {
        FlowingSelect(
          label: "Network channel count",
          selection: $channelCount,
          options: [1, 2, 4, 6, 8].map { count in
            FlowingSelectOption(count, label: count == 1 ? "Mono" : "\(count) ch")
          },
          minimumWidth: 104
        )
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

private struct NetworkAudioInspectorCard<Content: View>: View {
  let title: String
  let subtitle: String
  @ViewBuilder let content: Content

  var body: some View {
    FlowingCard(
      spacing: 14,
      contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    ) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
          .foregroundStyle(FlowingPalette.ink)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      content
    }
    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
  }
}

private func labeledField<Content: View>(
  _ label: String,
  @ViewBuilder content: () -> Content
) -> some View {
  VStack(alignment: .leading, spacing: 7) {
    Text(label)
      .font(.caption.weight(.semibold))
      .foregroundStyle(FlowingPalette.muted)
    content()
  }
  .frame(maxWidth: .infinity, alignment: .leading)
}

private struct SelectedDelayInspector: View {
  let configuration: RoutingDelayConfiguration
  let updateConfiguration: (RoutingDelayConfiguration) -> Void

  var body: some View {
    FlowingCard(
      spacing: 14,
      contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    ) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Delay")
          .font(.headline)
          .foregroundStyle(FlowingPalette.ink)
        Text("Delay an audio bus with bounded realtime feedback.")
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      parameterSlider(
        title: "Time",
        value: delayPosition,
        range: 0...1,
        formattedValue: delayDescription,
        accessibilityFormat: { _ in delayDescription }
      )

      parameterSlider(
        title: "Feedback",
        value: feedback,
        range: feedbackRange,
        formattedValue: "\(Int((configuration.feedback * 100).rounded()))%",
        accessibilityFormat: { value in "\(Int((value * 100).rounded())) percent" }
      )

      parameterSlider(
        title: "Dry / Wet",
        value: dryWetMix,
        range: 0...1,
        formattedValue: "\(Int((configuration.dryWetMix * 100).rounded()))% wet",
        accessibilityFormat: { value in "\(Int((value * 100).rounded())) percent wet" }
      )

      FlowingCallout(
        "Feedback remains below self-oscillation, and the delay line has a fixed memory budget prepared before playback begins.",
        title: "Realtime Effect",
        systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90",
        tone: .neutral
      )
    }
    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
  }

  private func parameterSlider(
    title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    formattedValue: String,
    accessibilityFormat: @escaping (Double) -> String
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(FlowingPalette.muted)
        Spacer(minLength: 8)
        Text(formattedValue)
          .font(.caption.monospacedDigit())
          .foregroundStyle(FlowingPalette.ink)
      }
      FlowingSlider(
        title,
        value: value,
        in: range,
        formatValue: accessibilityFormat
      )
    }
  }

  private var delayPosition: Binding<Double> {
    let minimum = RoutingDelayConfiguration.minimumDelaySeconds
    let maximum = RoutingDelayConfiguration.maximumDelaySeconds
    let span = log(maximum / minimum)
    return Binding(
      get: { log(configuration.delaySeconds / minimum) / span },
      set: { position in
        var updated = configuration
        updated.delaySeconds = minimum * exp(min(max(position, 0), 1) * span)
        updateConfiguration(updated)
      }
    )
  }

  private var feedback: Binding<Double> {
    Binding(
      get: { Double(configuration.feedback) },
      set: { feedback in
        var updated = configuration
        updated.feedback = Float(
          min(
            max(feedback, -Double(RoutingDelayConfiguration.maximumFeedback)),
            Double(RoutingDelayConfiguration.maximumFeedback)
          )
        )
        updateConfiguration(updated)
      }
    )
  }

  private var feedbackRange: ClosedRange<Double> {
    let limit = Double(RoutingDelayConfiguration.maximumFeedback)
    return -limit...limit
  }

  private var dryWetMix: Binding<Double> {
    Binding(
      get: { Double(configuration.dryWetMix) },
      set: { mix in
        var updated = configuration
        updated.dryWetMix = Float(min(max(mix, 0), 1))
        updateConfiguration(updated)
      }
    )
  }

  private var delayDescription: String {
    if configuration.delaySeconds < 1 {
      return "\(Int((configuration.delaySeconds * 1_000).rounded())) milliseconds"
    }
    return configuration.delaySeconds.formatted(
      .number.precision(.fractionLength(2))
    ) + " seconds"
  }
}

private struct SelectedNoiseGateInspector: View {
  let configuration: RoutingNoiseGateConfiguration
  let updateConfiguration: (RoutingNoiseGateConfiguration) -> Void

  var body: some View {
    FlowingCard(
      spacing: 14,
      contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    ) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Noise Gate")
          .font(.headline)
          .foregroundStyle(FlowingPalette.ink)
        Text("Attenuate quiet passages without changing channel balance.")
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      parameterSlider(
        title: "Threshold",
        value: threshold,
        range: thresholdRange,
        formattedValue: "\(Int(configuration.thresholdDecibels.rounded())) dBFS",
        accessibilityFormat: { "\(Int($0.rounded())) decibels full scale" }
      )
      parameterSlider(
        title: "Hysteresis",
        value: hysteresis,
        range: 0...Double(RoutingNoiseGateConfiguration.maximumHysteresisDecibels),
        formattedValue: "\(Int(configuration.hysteresisDecibels.rounded())) dB",
        accessibilityFormat: { "\(Int($0.rounded())) decibels" }
      )
      parameterSlider(
        title: "Attack",
        value: attack,
        range: 0...RoutingNoiseGateConfiguration.maximumAttackSeconds,
        formattedValue: durationDescription(configuration.attackSeconds),
        accessibilityFormat: durationDescription
      )
      parameterSlider(
        title: "Hold",
        value: hold,
        range: 0...RoutingNoiseGateConfiguration.maximumHoldSeconds,
        formattedValue: durationDescription(configuration.holdSeconds),
        accessibilityFormat: durationDescription
      )
      parameterSlider(
        title: "Release",
        value: release,
        range: 0...RoutingNoiseGateConfiguration.maximumReleaseSeconds,
        formattedValue: durationDescription(configuration.releaseSeconds),
        accessibilityFormat: durationDescription
      )
      parameterSlider(
        title: "Reduction",
        value: reduction,
        range: 0...Double(RoutingNoiseGateConfiguration.maximumReductionDecibels),
        formattedValue: "\(Int(configuration.reductionDecibels.rounded())) dB",
        accessibilityFormat: { "\(Int($0.rounded())) decibels" }
      )

      FlowingCallout(
        "A gate quiets low-level passages; it does not remove noise while wanted audio is present. Detection is linked across every routed channel to preserve the sound image.",
        title: "Realtime Gate",
        systemImage: "waveform.badge.minus",
        tone: .neutral
      )
    }
    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
  }

  private func parameterSlider(
    title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    formattedValue: String,
    accessibilityFormat: @escaping (Double) -> String
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(FlowingPalette.muted)
        Spacer(minLength: 8)
        Text(formattedValue)
          .font(.caption.monospacedDigit())
          .foregroundStyle(FlowingPalette.ink)
      }
      FlowingSlider(title, value: value, in: range, formatValue: accessibilityFormat)
    }
  }

  private var threshold: Binding<Double> {
    Binding(
      get: { Double(configuration.thresholdDecibels) },
      set: { value in
        var updated = configuration
        updated.thresholdDecibels = Float(
          min(
            max(value, Double(RoutingNoiseGateConfiguration.minimumThresholdDecibels)),
            Double(RoutingNoiseGateConfiguration.maximumThresholdDecibels)
          )
        )
        updateConfiguration(updated)
      }
    )
  }

  private var thresholdRange: ClosedRange<Double> {
    let minimum = Double(RoutingNoiseGateConfiguration.minimumThresholdDecibels)
    let maximum = Double(RoutingNoiseGateConfiguration.maximumThresholdDecibels)
    return minimum...maximum
  }

  private var hysteresis: Binding<Double> {
    boundedFloatBinding(
      keyPath: \.hysteresisDecibels,
      range: 0...Double(RoutingNoiseGateConfiguration.maximumHysteresisDecibels)
    )
  }

  private var reduction: Binding<Double> {
    boundedFloatBinding(
      keyPath: \.reductionDecibels,
      range: 0...Double(RoutingNoiseGateConfiguration.maximumReductionDecibels)
    )
  }

  private var attack: Binding<Double> {
    boundedDoubleBinding(
      keyPath: \.attackSeconds,
      range: 0...RoutingNoiseGateConfiguration.maximumAttackSeconds
    )
  }

  private var hold: Binding<Double> {
    boundedDoubleBinding(
      keyPath: \.holdSeconds,
      range: 0...RoutingNoiseGateConfiguration.maximumHoldSeconds
    )
  }

  private var release: Binding<Double> {
    boundedDoubleBinding(
      keyPath: \.releaseSeconds,
      range: 0...RoutingNoiseGateConfiguration.maximumReleaseSeconds
    )
  }

  private func boundedFloatBinding(
    keyPath: WritableKeyPath<RoutingNoiseGateConfiguration, Float>,
    range: ClosedRange<Double>
  ) -> Binding<Double> {
    Binding(
      get: { Double(configuration[keyPath: keyPath]) },
      set: { value in
        var updated = configuration
        updated[keyPath: keyPath] = Float(min(max(value, range.lowerBound), range.upperBound))
        updateConfiguration(updated)
      }
    )
  }

  private func boundedDoubleBinding(
    keyPath: WritableKeyPath<RoutingNoiseGateConfiguration, Double>,
    range: ClosedRange<Double>
  ) -> Binding<Double> {
    Binding(
      get: { configuration[keyPath: keyPath] },
      set: { value in
        var updated = configuration
        updated[keyPath: keyPath] = min(max(value, range.lowerBound), range.upperBound)
        updateConfiguration(updated)
      }
    )
  }

  private func durationDescription(_ seconds: Double) -> String {
    if seconds < 1 {
      return "\(Int((seconds * 1_000).rounded())) ms"
    }
    return seconds.formatted(.number.precision(.fractionLength(2))) + " s"
  }
}

private struct SelectedCompressorInspector: View {
  let configuration: RoutingCompressorConfiguration
  let updateConfiguration: (RoutingCompressorConfiguration) -> Void

  var body: some View {
    FlowingCard(
      spacing: 14,
      contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    ) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Compressor")
          .font(.headline)
          .foregroundStyle(FlowingPalette.ink)
        Text("Control dynamic range while preserving the routed channel balance.")
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      parameterSlider(
        title: "Threshold",
        value: threshold,
        range: thresholdRange,
        formattedValue: "\(Int(configuration.thresholdDecibels.rounded())) dBFS",
        accessibilityFormat: { "\(Int($0.rounded())) decibels full scale" }
      )
      parameterSlider(
        title: "Ratio",
        value: ratio,
        range: ratioRange,
        formattedValue: configuration.ratio.formatted(
          .number.precision(.fractionLength(1))
        ) + ":1",
        accessibilityFormat: { value in
          value.formatted(.number.precision(.fractionLength(1))) + " to one"
        }
      )
      parameterSlider(
        title: "Knee",
        value: knee,
        range: 0...Double(RoutingCompressorConfiguration.maximumKneeDecibels),
        formattedValue: "\(Int(configuration.kneeDecibels.rounded())) dB",
        accessibilityFormat: { "\(Int($0.rounded())) decibels" }
      )
      parameterSlider(
        title: "Attack",
        value: attack,
        range: 0...RoutingCompressorConfiguration.maximumAttackSeconds,
        formattedValue: durationDescription(configuration.attackSeconds),
        accessibilityFormat: durationDescription
      )
      parameterSlider(
        title: "Release",
        value: release,
        range: 0...RoutingCompressorConfiguration.maximumReleaseSeconds,
        formattedValue: durationDescription(configuration.releaseSeconds),
        accessibilityFormat: durationDescription
      )
      parameterSlider(
        title: "Makeup Gain",
        value: makeupGain,
        range: makeupGainRange,
        formattedValue: String(
          format: "%+.0f dB",
          locale: Locale(identifier: "en_US_POSIX"),
          configuration.makeupGainDecibels
        ),
        accessibilityFormat: { "\(Int($0.rounded())) decibels" }
      )

      FlowingCallout(
        "Detection is linked across every routed channel, so compression cannot pull the stereo image toward one side. The processor retains Float32 headroom and does not clip internally.",
        title: "Linked Dynamics",
        systemImage: "arrow.down.right.and.arrow.up.left",
        tone: .neutral
      )
    }
    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
  }

  private func parameterSlider(
    title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    formattedValue: String,
    accessibilityFormat: @escaping (Double) -> String
  ) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(FlowingPalette.muted)
        Spacer(minLength: 8)
        Text(formattedValue)
          .font(.caption.monospacedDigit())
          .foregroundStyle(FlowingPalette.ink)
      }
      FlowingSlider(title, value: value, in: range, formatValue: accessibilityFormat)
    }
  }

  private var thresholdRange: ClosedRange<Double> {
    ClosedRange(
      uncheckedBounds: (
        lower: Double(RoutingCompressorConfiguration.minimumThresholdDecibels),
        upper: Double(RoutingCompressorConfiguration.maximumThresholdDecibels)
      )
    )
  }

  private var ratioRange: ClosedRange<Double> {
    ClosedRange(
      uncheckedBounds: (
        lower: Double(RoutingCompressorConfiguration.minimumRatio),
        upper: Double(RoutingCompressorConfiguration.maximumRatio)
      )
    )
  }

  private var makeupGainRange: ClosedRange<Double> {
    ClosedRange(
      uncheckedBounds: (
        lower: Double(RoutingCompressorConfiguration.minimumMakeupGainDecibels),
        upper: Double(RoutingCompressorConfiguration.maximumMakeupGainDecibels)
      )
    )
  }

  private var threshold: Binding<Double> {
    boundedFloatBinding(keyPath: \.thresholdDecibels, range: thresholdRange)
  }

  private var ratio: Binding<Double> {
    boundedFloatBinding(
      keyPath: \.ratio,
      range: ratioRange
    )
  }

  private var knee: Binding<Double> {
    boundedFloatBinding(
      keyPath: \.kneeDecibels,
      range: 0...Double(RoutingCompressorConfiguration.maximumKneeDecibels)
    )
  }

  private var attack: Binding<Double> {
    boundedDoubleBinding(
      keyPath: \.attackSeconds,
      range: 0...RoutingCompressorConfiguration.maximumAttackSeconds
    )
  }

  private var release: Binding<Double> {
    boundedDoubleBinding(
      keyPath: \.releaseSeconds,
      range: 0...RoutingCompressorConfiguration.maximumReleaseSeconds
    )
  }

  private var makeupGain: Binding<Double> {
    boundedFloatBinding(
      keyPath: \.makeupGainDecibels,
      range: makeupGainRange
    )
  }

  private func boundedFloatBinding(
    keyPath: WritableKeyPath<RoutingCompressorConfiguration, Float>,
    range: ClosedRange<Double>
  ) -> Binding<Double> {
    Binding(
      get: { Double(configuration[keyPath: keyPath]) },
      set: { value in
        var updated = configuration
        updated[keyPath: keyPath] = Float(min(max(value, range.lowerBound), range.upperBound))
        updateConfiguration(updated)
      }
    )
  }

  private func boundedDoubleBinding(
    keyPath: WritableKeyPath<RoutingCompressorConfiguration, Double>,
    range: ClosedRange<Double>
  ) -> Binding<Double> {
    Binding(
      get: { configuration[keyPath: keyPath] },
      set: { value in
        var updated = configuration
        updated[keyPath: keyPath] = min(max(value, range.lowerBound), range.upperBound)
        updateConfiguration(updated)
      }
    )
  }

  private func durationDescription(_ seconds: Double) -> String {
    if seconds < 1 {
      return "\(Int((seconds * 1_000).rounded())) ms"
    }
    return seconds.formatted(.number.precision(.fractionLength(2))) + " s"
  }
}

private struct SelectedVisualizerInspector: View {
  let configuration: RoutingVisualizerConfiguration
  let updateConfiguration: (RoutingVisualizerConfiguration) -> Void

  var body: some View {
    FlowingCard(
      spacing: 14,
      contentInsets: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    ) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Visualizer")
          .font(.headline)
          .foregroundStyle(FlowingPalette.ink)
        Text("Choose how routed channels appear.")
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      FlowingSegmentedControl(
        label: "Waveform presentation",
        selection: mode,
        options: [
          FlowingSegmentOption(.mixed, label: "Mixed"),
          FlowingSegmentOption(.separate, label: "Separate"),
        ]
      )

      if configuration.mode == .separate {
        VStack(alignment: .leading, spacing: 9) {
          Text("Channel Set")
            .font(.caption.weight(.semibold))
            .foregroundStyle(FlowingPalette.muted)

          FlowingSelect(
            label: "Visualizer channel set",
            selection: channelSelection,
            options: channelSelectionOptions,
            minimumWidth: 164
          )
          .fixedSize(horizontal: false, vertical: true)

          if case .custom = configuration.channelSelection {
            HStack {
              Text("Channels")
                .font(.caption)
                .foregroundStyle(FlowingPalette.muted)
              Spacer(minLength: 8)
              FlowingStepper(
                "Custom channel count",
                value: customChannelCount,
                in: 1...RoutingVisualizerConfiguration.maximumSeparateLaneCount,
                step: 1
              )
            }
          }

          Text(channelAvailabilityDescription)
            .font(.caption2)
            .foregroundStyle(FlowingPalette.faint)
        }

        Text(
          "A visualizer shows at most \(RoutingVisualizerConfiguration.maximumSeparateLaneCount) leading channels. Add another visualizer for additional lanes."
        )
        .font(.caption2)
        .foregroundStyle(FlowingPalette.faint)

        Divider()
          .overlay(FlowingPalette.hairline)

        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Mixed Output")
              .font(.caption.weight(.semibold))
              .foregroundStyle(FlowingPalette.ink)
            Text("Add one normalized mono convenience output.")
              .font(.caption2)
              .foregroundStyle(FlowingPalette.muted)
          }
          Spacer(minLength: 8)
          FlowingSwitch("Mixed output", isOn: includesMixedOutput)
        }
      }
    }
    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
  }

  private var mode: Binding<RoutingVisualizerMode> {
    Binding(
      get: { configuration.mode },
      set: { newMode in
        var updated = configuration
        updated.mode = newMode
        updateConfiguration(updated)
      }
    )
  }

  private var channelSelection: Binding<RoutingVisualizerChannelSelection> {
    Binding(
      get: { configuration.channelSelection },
      set: { selection in
        var updated = configuration
        updated.channelSelection = selection
        updateConfiguration(updated)
      }
    )
  }

  private var customChannelCount: Binding<Int> {
    Binding(
      get: {
        max(
          configuration.channelSelection.requestedChannels.max().map { $0 + 1 } ?? 1,
          1
        )
      },
      set: { count in
        var updated = configuration
        updated.channelSelection = .custom(Set(0..<count))
        updateConfiguration(updated)
      }
    )
  }

  private var includesMixedOutput: Binding<Bool> {
    Binding(
      get: { configuration.includesMixedOutput },
      set: { includesMixedOutput in
        var updated = configuration
        updated.includesMixedOutput = includesMixedOutput
        updateConfiguration(updated)
      }
    )
  }

  private var channelSelectionOptions: [FlowingSelectOption<RoutingVisualizerChannelSelection>] {
    let presetOptions = RoutingVisualizerChannelPreset.allCases.map { preset in
      FlowingSelectOption(
        RoutingVisualizerChannelSelection.preset(preset),
        label: presetLabel(preset)
      )
    }
    let customSelection: RoutingVisualizerChannelSelection
    if case .custom = configuration.channelSelection {
      customSelection = configuration.channelSelection
    } else {
      customSelection = .custom(configuration.channelSelection.requestedChannels)
    }
    return presetOptions + [FlowingSelectOption(customSelection, label: "Custom")]
  }

  private var channelAvailabilityDescription: String {
    let available = configuration.availableChannelCount
    let visible = configuration.normalizedSelectedChannels.count
    return "\(visible) of \(available) available channel\(available == 1 ? "" : "s") will be shown."
  }

  private func presetLabel(_ preset: RoutingVisualizerChannelPreset) -> String {
    switch preset {
    case .mono: "Mono · 1 ch"
    case .stereo: "Stereo · 2 ch"
    case .quadraphonic: "Quad · 4 ch"
    case .surround51: "5.1 · 6 ch"
    case .surround71: "7.1 · 8 ch"
    }
  }
}

/// Pairing controls shared by both network audio inspectors.
///
/// A key both ends hold turns an open UDP port into one that only the paired machine can feed or
/// read. Without one the audio is readable by anything on the path, which is why the absence is
/// stated rather than left implied.
private struct NetworkAudioSecretControls: View {
  let secret: RoutingNetworkAudioSecret?
  let update: (RoutingNetworkAudioSecret?) -> Void

  @State private var keyText: String
  @State private var didCopy = false

  init(
    secret: RoutingNetworkAudioSecret?,
    update: @escaping (RoutingNetworkAudioSecret?) -> Void
  ) {
    self.secret = secret
    self.update = update
    _keyText = State(initialValue: secret?.base64EncodedString ?? "")
  }

  var body: some View {
    labeledField("Shared Key") {
      VStack(alignment: .leading, spacing: 8) {
        FlowingTextField(
          "Shared key",
          text: $keyText,
          placeholder: "Paste the key from the other Mac",
          systemImage: "key",
          validation: validation,
          onSubmit: commit
        )
        HStack(spacing: 6) {
          FlowingIconButton("Generate Key", systemImage: "sparkles", emphasis: .standard) {
            let generated = RoutingNetworkAudioSecret.generated()
            keyText = generated.base64EncodedString
            update(generated)
          }
          if secret?.isValid == true {
            FlowingIconButton(
              didCopy ? "Copied" : "Copy Key",
              systemImage: didCopy ? "checkmark" : "doc.on.doc",
              emphasis: .standard
            ) {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(keyText, forType: .string)
              didCopy = true
            }
          }
          if secret != nil {
            FlowingIconButton("Remove", systemImage: "xmark", emphasis: .standard) {
              keyText = ""
              didCopy = false
              update(nil)
            }
          }
        }
        FlowingCallout(
          statusDescription,
          title: statusTitle,
          systemImage: secret?.isValid == true ? "lock.fill" : "lock.open",
          tone: secret?.isValid == true ? .success : .warning
        )
      }
    }
    .onChange(of: keyText) { _, _ in
      didCopy = false
      commit()
    }
  }

  private var validation: FlowingFieldValidation {
    guard !keyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .none }
    return RoutingNetworkAudioSecret.inline(base64: keyText).isValid
      ? .none
      : .error("Paste the whole key exactly as the other Mac shows it.")
  }

  private var statusTitle: String {
    secret?.isValid == true ? "Encrypted" : "Not encrypted"
  }

  private var statusDescription: String {
    secret?.isValid == true
      ? "Only a peer holding this key can send or read this audio."
      : "Anyone who can reach this port can send or read this audio. Generate a key here and paste it on the other Mac to change that."
  }

  private func commit() {
    let trimmed = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      if secret != nil { update(nil) }
      return
    }
    let candidate = RoutingNetworkAudioSecret.inline(base64: trimmed)
    guard candidate.isValid, candidate != secret else { return }
    update(candidate)
  }
}

