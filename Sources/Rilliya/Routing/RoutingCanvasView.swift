import AppKit
import FlowingDayCanvas
import FlowingDayControls
import FlowingDayGraphCanvas
import FlowingDayGraphComposition
import SwiftUI

private enum RoutingPaletteItem: String, Codable, Transferable {
  case applicationAudio = "moe.uwucocoa.rilliya.node.application-audio"

  static var transferRepresentation: some TransferRepresentation {
    CodableRepresentation(contentType: .plainText)
  }
}

struct RoutingCanvasView: View {
  let workspace: RoutingWorkspaceModel
  let applicationCatalog: InstalledApplicationCatalogController
  let iconResolver: NSWorkspaceInstalledApplicationIconResolver
  let sessionID: FlowingGraphCanvasSessionID

  @Binding var session: FlowingGraphCanvasSessionState<RoutingCanvasSchema>
  @Binding var inspectedNodeID: UUID?

  @State private var command: FlowingGraphCanvasSessionCommand<RoutingCanvasSchema>?
  @State private var isDropTargeted = false

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
      guard items.contains(.applicationAudio) else { return false }
      let worldPoint = session.viewport.transform.removing(from: location)
      let nodeID = workspace.addApplicationAudioNode(centeredAt: worldPoint)
      inspectedNodeID = nodeID
      return true
    } isTargeted: {
      isDropTargeted = $0
    }
    .onChange(of: session.selection) { _, _ in
      if let selectedWorkspaceNodeID {
        inspectedNodeID = selectedWorkspaceNodeID
      } else if session.selection.isEmpty {
        Task { @MainActor in
          await Task.yield()
          if session.selection.isEmpty {
            inspectedNodeID = nil
          }
        }
      }
    }
    .onChange(of: inspectedNodeID) { _, nodeID in
      guard let nodeID else { return }
      Task { @MainActor in
        await Task.yield()
        guard inspectedNodeID == nodeID,
          let elementID = workspace.elementID(for: nodeID)
        else {
          return
        }
        command = FlowingGraphCanvasSessionCommand(
          targetSessionID: sessionID,
          action: .select(.replace([elementID])),
          animated: false
        )
      }
    }
  }

  private func canvas(_ content: RoutingCanvasContent) -> some View {
    FlowingGraphCanvas(
      content: content,
      sessionID: sessionID,
      session: $session,
      configuration: FlowingGraphCanvasConfiguration(
        canvas: FlowingCanvasConfiguration(
          initialZoom: 1,
          focusedZoom: 1.12,
          zoomRange: 0.3...3
        ),
        nodeDraggingMode: .single,
        nodeResizing: .disabled,
        connectionEditing: .disabled,
        snapping: FlowingGraphCanvasSnappingConfiguration(
          isEnabled: true,
          grid: FlowingGraphCanvasGridConfiguration(
            majorCellSize: CGSize(width: 24, height: 24)
          )
        ),
        rendersDefaultGuides: false,
        allowsArrangementCommands: false
      ),
      accessibilitySnapshot: workspace.accessibilitySnapshot,
      command: command,
      onIntent: workspace.send,
      background: { RoutingCanvasGrid(context: $0) },
      node: { node, context in
        ApplicationAudioNodeView(
          node: node,
          context: context,
          applicationCatalog: applicationCatalog,
          iconResolver: iconResolver
        )
      },
      edge: { _, _ in EmptyView() },
      decorations: { _ in EmptyView() },
      overlays: { _ in selectedNodeInspector }
    )
  }

  @ViewBuilder
  private var selectedNodeInspector: some View {
    if let nodeID = inspectedNodeID,
      workspace.node(id: nodeID) != nil
    {
      FlowingCanvasViewportOverlay(
        alignment: .topTrailing,
        insets: EdgeInsets(top: 18, leading: 0, bottom: 0, trailing: 18)
      ) {
        SelectedApplicationInspector(
          selection: workspace.node(id: nodeID)?.value.applicationSelection,
          applicationCatalog: applicationCatalog,
          selectApplication: { selection in
            workspace.selectApplication(selection, for: nodeID)
          }
        )
        .frame(width: 330)
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
  let applicationCatalog: InstalledApplicationCatalogController
  let insertApplicationAudio: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      header

      FlowingSection(
        "Audio Nodes",
        footer: "Drag a node onto the canvas, then choose the application it should follow."
      ) {
        applicationAudioItem
      }

      catalogStatus
      Spacer(minLength: 0)
    }
    .padding(18)
    .frame(width: 286)
    .background(FlowingPalette.card)
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
  }

  private var applicationAudioItem: some View {
    Button(action: insertApplicationAudio) {
      FlowingCard(
        spacing: 0,
        contentInsets: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
      ) {
        HStack(spacing: 11) {
          Image(systemName: "macwindow.on.rectangle")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(FlowingAccent.fern.foreground)
            .frame(width: 32, height: 32)
            .background(
              FlowingAccent.fern.veil,
              in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )

          VStack(alignment: .leading, spacing: 2) {
            Text("Application Audio")
              .font(.callout.weight(.semibold))
              .foregroundStyle(FlowingPalette.ink)
            Text("Capture an app output")
              .font(.caption)
              .foregroundStyle(FlowingPalette.muted)
          }

          Spacer(minLength: 6)

          Image(systemName: "line.3.horizontal")
            .foregroundStyle(FlowingPalette.faint)
            .accessibilityHidden(true)
        }
      }
    }
    .buttonStyle(.plain)
    .draggable(RoutingPaletteItem.applicationAudio)
    .help("Drag Application Audio onto the canvas")
    .accessibilityHint("Drag to the canvas or press to add at the visible workspace center")
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
    nodeCard
      .frame(
        width: RoutingCanvasMetrics.nodeSize.width, height: RoutingCanvasMetrics.nodeSize.height
      )
      .scaleEffect(context.renderScale, anchor: .topLeading)
      .frame(
        width: RoutingCanvasMetrics.nodeSize.width * context.renderScale,
        height: RoutingCanvasMetrics.nodeSize.height * context.renderScale,
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

        nodeStatus
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
    Group {
      if let application = selectedCatalogItem?.application {
        Image(nsImage: iconResolver.icon(for: application))
          .resizable()
      } else {
        Image(systemName: "macwindow")
          .resizable()
          .scaledToFit()
          .padding(8)
          .foregroundStyle(FlowingPalette.muted)
      }
    }
    .frame(width: 38, height: 38)
    .background(
      FlowingPalette.field,
      in: RoundedRectangle(cornerRadius: 9, style: .continuous)
    )
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

private struct SelectedApplicationInspector: View {
  let selection: RoutingApplicationSelection?
  let applicationCatalog: InstalledApplicationCatalogController
  let selectApplication: (RoutingApplicationSelection?) -> Void

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
    }
    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
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
