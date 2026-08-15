import AppKit
import FlowingDayCanvas
import FlowingDayControls
import FlowingDayGraphCanvas
import FlowingDayGraphComposition
import RilliyaKit
import SwiftUI

private enum RoutingPaletteItem: String, Codable, Transferable {
  case applicationAudio = "moe.uwucocoa.rilliya.node.application-audio"
  case visualizer = "moe.uwucocoa.rilliya.node.visualizer"

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .plainText)
  }
}

private struct RoutingDropPreviewState: Identifiable, Equatable {
  let id: UUID
  let item: RoutingPaletteItem
  let location: CGPoint
  var isExpanded: Bool
}

struct RoutingCanvasView: View {
  let workspace: RoutingWorkspaceModel
  let settings: RilliyaSettings
  let applicationCatalog: InstalledApplicationCatalogController
  let iconResolver: NSWorkspaceInstalledApplicationIconResolver
  let captureController: RoutingCaptureController
  let sessionID: FlowingGraphCanvasSessionID

  @Binding var session: FlowingGraphCanvasSessionState<RoutingCanvasSchema>

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var isDropTargeted = false
  @State private var dropPreview: RoutingDropPreviewState?
  @State private var dropTask: Task<Void, Never>?

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
          isExpanded: dropPreview.isExpanded
        )
        .position(dropPreview.location)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(
          isDropTargeted ? FlowingAccent.fern.fill : Color.clear,
          lineWidth: 2
        )
        .padding(6)
        .allowsHitTesting(false)
    }
    .dropDestination(for: RoutingPaletteItem.self) { items, location in
      guard let item = items.first else { return false }
      beginDrop(item, at: location)
      return true
    } isTargeted: {
      isDropTargeted = $0
    }
    .onDisappear {
      dropTask?.cancel()
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
          inspector: AnyView(selectedNodeInspector)
        )
      },
      accessibilitySnapshot: workspace.accessibilitySnapshot,
      interactionPolicy: FlowingGraphCanvasInteractionPolicy(
        connectionPolicy: FlowingGraphCanvasConnectionPolicy(
          canBegin: workspace.canBeginConnection,
          validate: workspace.validateConnection
        )
      ),
      onIntent: workspace.send,
      background: { RoutingCanvasGrid(context: $0) },
      node: { node, context in
        switch node.value {
        case .applicationAudio:
          ApplicationAudioNodeView(
            node: node,
            context: context,
            applicationCatalog: applicationCatalog,
            iconResolver: iconResolver
          )
          .zIndex(context.isSelected ? 2 : 1)
        case .visualizer(let configuration):
          VisualizerNodeView(
            configuration: configuration,
            snapshot: visualizerSnapshot(for: node),
            context: context
          )
          .zIndex(context.isSelected ? 2 : 1)
        }
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
  }

  private func metalScene(for content: RoutingCanvasContent) -> RoutingMetalScene {
    var supplements: [UUID: RoutingMetalNodeSupplement] = [:]
    for node in workspace.nodes {
      switch node.value {
      case .applicationAudio(let selection, _):
        let state = captureController.state(for: node.id)
        let isCapturing: Bool
        let captureFormat: ProcessOutputCaptureFormat?
        switch state {
        case .starting:
          isCapturing = true
          captureFormat = nil
        case .running(let format):
          isCapturing = true
          captureFormat = format
        case .idle, .failed:
          isCapturing = false
          captureFormat = nil
        }
        supplements[node.id] = RoutingMetalNodeSupplement(
          isRunning: isRunning(selection),
          isCapturing: isCapturing,
          captureConsumerCount: captureController.consumerCount(for: node.id),
          visualizerSignal: nil,
          captureFormat: captureFormat
        )
      case .visualizer(let configuration):
        supplements[node.id] = RoutingMetalNodeSupplement(
          isRunning: false,
          isCapturing: false,
          captureConsumerCount: 0,
          visualizerSignal: RoutingVisualizerSignalBuilder.build(
            configuration: configuration,
            incomingEdges: workspace.incomingEdges(for: node.id),
            snapshotForNode: captureController.snapshot
          )
        )
      }
    }
    return RoutingMetalScene(
      content: content,
      supplements: supplements,
      connectionInformationLevel: settings.connectionInformationLevel
    )
  }

  private func isRunning(_ selection: RoutingApplicationSelection?) -> Bool {
    guard let selection else { return false }
    return applicationCatalog.state.snapshot?.items.contains { item in
      item.isRunning
        && canonicalApplicationURL(item.application.bundleURL)
          == canonicalApplicationURL(selection.applicationURL)
    } == true
  }

  @ViewBuilder
  private var selectedNodeInspector: some View {
    if let nodeID = selectedWorkspaceNodeID,
      let node = workspace.node(id: nodeID)
    {
      selectedNodeInspectorContent(node: node)
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
        isRouted: workspace.edges.contains { $0.source.nodeID == node.id },
        applicationCatalog: applicationCatalog,
        captureController: captureController,
        selectApplication: { selection in
          workspace.selectApplication(selection, for: node.id)
        },
        setChannelPresentation: { presentation in
          workspace.setApplicationChannelPresentation(presentation, for: node.id)
        }
      )
    case .visualizer(let configuration):
      SelectedVisualizerInspector(configuration: configuration) { updated in
        workspace.configureVisualizer(updated, for: node.id)
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
      snapshotForNode: captureController.snapshot
    )
  }

  private func selectNode(_ nodeID: UUID) {
    guard let elementID = workspace.elementID(for: nodeID) else { return }
    session.selection = [elementID]
    session.focusedElementID = elementID
  }

  private func beginDrop(_ item: RoutingPaletteItem, at location: CGPoint) {
    dropTask?.cancel()
    let previewID = UUID()
    let worldPoint = session.viewport.transform.removing(from: location)
    dropPreview = RoutingDropPreviewState(
      id: previewID,
      item: item,
      location: location,
      isExpanded: false
    )

    dropTask = Task { @MainActor in
      await Task.yield()
      guard !Task.isCancelled, dropPreview?.id == previewID else { return }

      let nodeID: UUID
      switch item {
      case .applicationAudio:
        nodeID = workspace.addApplicationAudioNode(centeredAt: worldPoint)
      case .visualizer:
        nodeID = workspace.addVisualizerNode(centeredAt: worldPoint)
      }
      selectNode(nodeID)

      withAnimation(
        reduceMotion
          ? .easeOut(duration: 0.12)
          : .spring(response: 0.28, dampingFraction: 0.9)
      ) {
        guard dropPreview?.id == previewID else { return }
        dropPreview?.isExpanded = true
      }

      try? await Task.sleep(for: .milliseconds(220))
      guard !Task.isCancelled, dropPreview?.id == previewID else { return }
      withAnimation(.easeOut(duration: 0.1)) {
        dropPreview = nil
      }
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

struct RoutingNodePaletteView: View {
  private enum Metrics {
    static let listHeight: CGFloat = 300
  }

  let applicationCatalog: InstalledApplicationCatalogController
  let insertApplicationAudio: () -> Void
  let insertVisualizer: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header

      Divider()
        .overlay(FlowingPalette.hairline)
        .padding(.vertical, 14)

      ScrollView {
        VStack(spacing: 0) {
          RoutingPaletteSection(
            "Audio Nodes",
            footer:
              "Drag a node onto the canvas, then choose the source or visualization it should use."
          ) {
            VStack(spacing: 10) {
              applicationAudioItem
              visualizerItem
            }
          }

          catalogStatus
            .padding(.top, 14)
        }
        .padding(.horizontal, 4)
      }
      .scrollContentBackground(.hidden)
      .background(Color.clear)
      .frame(height: Metrics.listHeight)

      NativeWindowDragRegion()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }
    .padding(14)
    .background {
      ZStack {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(FlowingPalette.control.opacity(0.94))
        NativeWindowDragRegion()
          .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
          .accessibilityHidden(true)
      }
    }
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(FlowingPalette.hairline)
    }
    .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
    .padding(.leading, 12)
    .padding(.trailing, 10)
    .padding(.vertical, 12)
    .frame(width: 286)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Color.clear)
  }

  private var visualizerItem: some View {
    RoutingPaletteNodeItem(
      item: .visualizer,
      title: "Visualizer",
      subtitle: "Inspect routed channels",
      systemImage: "waveform",
      foreground: FlowingAccent.seafoam.foreground,
      veil: FlowingAccent.seafoam.veil,
      action: insertVisualizer
    )
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

      Spacer(minLength: 8)

      if applicationCatalog.state.isLoading {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Refreshing installed applications")
      }

      FlowingIconButton("Refresh Applications", systemImage: "arrow.clockwise") {
        Task {
          await applicationCatalog.refresh()
        }
      }
    }
    .background(NativeWindowDragRegion().accessibilityHidden(true))
  }

  private var applicationAudioItem: some View {
    RoutingPaletteNodeItem(
      item: .applicationAudio,
      title: "Application Audio",
      subtitle: "Capture an app output",
      systemImage: "macwindow.on.rectangle",
      foreground: FlowingAccent.fern.foreground,
      veil: FlowingAccent.fern.veil,
      action: insertApplicationAudio
    )
  }

  @ViewBuilder
  private var catalogStatus: some View {
    if let errorMessage = applicationCatalog.state.rootErrorMessage {
      FlowingCallout(
        errorMessage,
        title: "Applications unavailable",
        systemImage: "exclamationmark.triangle",
        tone: .warning
      )
    } else if let snapshot = applicationCatalog.state.snapshot {
      Text("\(snapshot.items.count) installed applications available")
        .font(.caption)
        .foregroundStyle(FlowingPalette.faint)
        .padding(.horizontal, 4)
    } else {
      Text("Discovering installed applications…")
        .font(.caption)
        .foregroundStyle(FlowingPalette.faint)
        .padding(.horizontal, 4)
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
  let action: () -> Void

  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
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

          Image(systemName: "line.3.horizontal")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(isHovering ? foreground : FlowingPalette.faint)
            .accessibilityHidden(true)
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .strokeBorder(isHovering ? foreground.opacity(0.28) : Color.clear)
      }
      .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
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
    .offset(x: isHovering ? 2 : 0)
    .animation(.easeOut(duration: 0.14), value: isHovering)
    .help("Drag \(title) onto the canvas")
    .accessibilityHint("Drag to the canvas or press to add in the visible workspace")
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

  private var presentation: (String, String, String, Color, Color) {
    switch item {
    case .applicationAudio:
      return (
        "Application Audio",
        "Choose an application",
        "macwindow.on.rectangle",
        FlowingAccent.fern.foreground,
        FlowingAccent.fern.veil
      )
    case .visualizer:
      return (
        "Visualizer",
        "Waiting for audio input",
        "waveform",
        FlowingAccent.seafoam.foreground,
        FlowingAccent.seafoam.veil
      )
    }
  }

  var body: some View {
    let (title, subtitle, systemImage, foreground, veil) = presentation
    VStack(alignment: .leading, spacing: isExpanded ? 11 : 0) {
      HStack(spacing: 11) {
        Image(systemName: systemImage)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(foreground)
          .frame(width: 38, height: 38)
          .background(veil, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

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
          item == .applicationAudio ? "Select this node to configure" : "Waiting for audio input"
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
        .strokeBorder(foreground.opacity(0.36))
    }
    .shadow(color: .black.opacity(0.11), radius: 12, y: 5)
    .opacity(isExpanded ? 0 : 0.98)
  }
}

private struct RoutingPaletteSection<Content: View>: View {
  let title: String
  let footer: String
  let content: Content

  init(
    _ title: String,
    footer: String,
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

      content

      Text(footer)
        .font(.caption)
        .foregroundStyle(FlowingPalette.faint)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.top, 7)
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

        nodeStatus
          .padding(.trailing, 38)
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
        Image(nsImage: iconResolver.icon(for: application))
          .resizable()
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
          .frame(height: RoutingVisualizerLayout.waveformContentHeight(for: configuration))
      } else {
        RoutingWaveformPlaceholder()
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

private struct RoutingWaveformDisplay: View {
  let signal: RoutingVisualizerSignal
  let configuration: RoutingVisualizerConfiguration

  @Environment(\.flowingAccent) private var accent

  var body: some View {
    VStack(spacing: RoutingVisualizerLayout.laneSpacing) {
      ForEach(signal.lanes) { lane in
        HStack(spacing: 5) {
          if configuration.mode == .separate {
            Color.clear
              .frame(width: 28)
          }
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

private struct SelectedApplicationInspector: View {
  let nodeID: UUID
  let selection: RoutingApplicationSelection?
  let channelPresentation: RoutingChannelPresentation
  let isRouted: Bool
  let applicationCatalog: InstalledApplicationCatalogController
  let captureController: RoutingCaptureController
  let selectApplication: (RoutingApplicationSelection?) -> Void
  let setChannelPresentation: (RoutingChannelPresentation) -> Void

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
    case .failed(let message):
      VStack(alignment: .leading, spacing: 8) {
        FlowingCallout(
          message,
          title: "Capture failed",
          systemImage: "exclamationmark.triangle",
          tone: .warning
        )
        if isRouted, let processID = runningProcessID {
          Button("Try Again") {
            captureController.start(nodeID: nodeID, processID: processID)
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
      FlowingSearchPicker(
        label: "Installed Applications",
        selection: pickerSelection,
        options: pickerOptions,
        maximumVisibleOptions: 8
      )
    }
  }

  private var pickerSelection: Binding<String> {
    Binding(
      get: { selectedCatalogItem?.application.bundleURL.absoluteString ?? "" },
      set: { selectedID in
        captureController.stop(nodeID: nodeID)
        selectApplication(selection(for: selectedID))
      }
    )
  }

  private var pickerOptions: [FlowingSelectOption<String>] {
    [FlowingSelectOption("", label: "No Application")]
      + catalogItems.map { item in
        FlowingSelectOption(
          item.application.bundleURL.absoluteString,
          label: item.application.displayName
        )
      }
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
        HStack {
          Text("Available Channels")
            .font(.caption.weight(.semibold))
            .foregroundStyle(FlowingPalette.muted)
          Spacer(minLength: 8)
          FlowingStepper(
            "Available channel count",
            value: availableChannelCount,
            in: 1...RoutingVisualizerConfiguration.maximumAvailableChannelCount,
            step: 1
          )
        }

        ScrollView {
          FlowingMultiSelect(
            axis: .vertical,
            itemWidthPolicy: .fitContent(),
            contentAlignment: .leading,
            options: channelOptions
          )
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)

        Text(
          "Show up to \(RoutingVisualizerConfiguration.maximumSeparateLaneCount) channels per visualizer. Add another visualizer for more lanes."
        )
        .font(.caption2)
        .foregroundStyle(FlowingPalette.faint)
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

  private var availableChannelCount: Binding<Int> {
    Binding(
      get: { configuration.availableChannelCount },
      set: { count in
        var updated = configuration
        updated.availableChannelCount = count
        updateConfiguration(updated)
      }
    )
  }

  private var channelOptions: [FlowingMultiSelectOption] {
    (0..<configuration.availableChannelCount).map { channel in
      FlowingMultiSelectOption(
        "Channel \(channel + 1)",
        id: "visualizer-channel-\(channel)",
        isOn: Binding(
          get: { configuration.selectedChannels.contains(channel) },
          set: { isSelected in
            var updated = configuration
            if isSelected {
              if updated.selectedChannels.contains(channel)
                || updated.canSelectAnotherChannel
              {
                updated.selectedChannels.insert(channel)
              }
            } else {
              updated.selectedChannels.remove(channel)
            }
            updateConfiguration(updated)
          }
        )
      )
    }
  }
}
