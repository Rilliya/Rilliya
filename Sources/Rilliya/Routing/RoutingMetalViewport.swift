import FlowingDayCanvas
import FlowingDayControls
import FlowingDayGraphCanvas
import SwiftUI

struct RoutingMetalViewport: View {
  let context: FlowingGraphCanvasBackendContext<RoutingCanvasSchema>
  let scene: RoutingMetalScene
  let inspector: AnyView

  @StateObject private var controller: RoutingMetalCanvasController

  init(
    context: FlowingGraphCanvasBackendContext<RoutingCanvasSchema>,
    scene: RoutingMetalScene,
    inspector: AnyView
  ) {
    self.context = context
    self.scene = scene
    self.inspector = inspector
    _controller = StateObject(
      wrappedValue: RoutingMetalCanvasController(
        initialZoom: context.configuration.canvas.initialZoom
      )
    )
  }

  var body: some View {
    GeometryReader { _ in
      ZStack {
        RoutingMetalCanvas(
          scene: scene,
          selection: context.session.wrappedValue.selection,
          configuration: context.configuration,
          contentInsets: context.contentInsets,
          controller: controller,
          onSelectionChange: updateSelection,
          onMoveNode: moveNode,
          onConnect: connect,
          onViewportChange: updateViewport
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        FlowingCanvasViewportOverlay(
          alignment: .topTrailing,
          insets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        ) {
          VStack(alignment: .trailing, spacing: 12) {
            if !scene.nodes.isEmpty {
              miniMap
            }
            inspector
          }
        }

        FlowingCanvasViewportOverlay(
          alignment: .bottomTrailing,
          insets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        ) {
          viewportControls
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .clipped()
    }
  }

  private var miniMap: some View {
    let styleIndices = Dictionary(
      uniqueKeysWithValues: scene.nodes.map { ($0.id, $0.miniMapStyleIndex) })
    let visibleBounds = controller.viewport.visibleWorldRect
    let overviewBounds = scene.contentBounds.union(visibleBounds)
    return FlowingGraphCanvasMiniMap(
      content: context.content,
      viewportDriver: FlowingGraphMiniMapViewportDriver(
        viewport: controller.viewport,
        center: { controller.center(on: $0, phase: $1) },
        setZoom: { controller.setZoom($0, phase: $1) }
      ),
      configuration: FlowingGraphMiniMapConfiguration(
        size: CGSize(width: 184, height: 116),
        contentPadding: 10,
        visibility: .always,
        scope: .custom(overviewBounds),
        representation: .adaptive,
        interaction: .panAndZoom,
        refreshPolicy: .adaptiveLive,
        accessibilityLabel: "Audio routing overview"
      ),
      style: FlowingGraphMiniMapStyle(
        background: FlowingPalette.control.opacity(0.94),
        border: FlowingPalette.hairline,
        edge: FlowingAccent.fern.fill.opacity(0.28),
        viewportFill: FlowingAccent.fern.fill.opacity(0.1),
        viewportStroke: FlowingAccent.fern.fill.opacity(0.9),
        nodeStyles: [
          FlowingGraphMiniMapNodeStyle(fill: FlowingAccent.fern.fill.opacity(0.78)),
          FlowingGraphMiniMapNodeStyle(fill: FlowingAccent.seafoam.fill.opacity(0.78)),
        ],
        cornerRadius: 12
      ),
      nodeStyleIndex: { styleIndices[$0.id] ?? 0 }
    )
    .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
  }

  private var viewportControls: some View {
    HStack(spacing: 0) {
      RoutingViewportControlButton(
        systemImage: "minus",
        accessibilityLabel: "Zoom out"
      ) {
        controller.adjustZoom(by: -0.12)
      }

      Text("\(Int((controller.zoom * 100).rounded()))%")
        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
        .foregroundStyle(FlowingPalette.muted)
        .frame(width: 48)
        .accessibilityLabel("Zoom level")
        .accessibilityValue("\(Int((controller.zoom * 100).rounded())) percent")

      RoutingViewportControlButton(
        systemImage: "plus",
        accessibilityLabel: "Zoom in"
      ) {
        controller.adjustZoom(by: 0.12)
      }

      Rectangle()
        .fill(FlowingPalette.hairline)
        .frame(width: 1, height: 18)
        .padding(.horizontal, 3)

      RoutingViewportControlButton(
        systemImage: "viewfinder",
        accessibilityLabel: "Fit routing graph"
      ) {
        controller.fit()
      }
    }
    .padding(4)
    .background(
      FlowingPalette.control.opacity(0.94),
      in: RoundedRectangle(cornerRadius: 13, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 13, style: .continuous)
        .strokeBorder(FlowingPalette.hairline)
    }
    .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
  }

  private func updateSelection(_ selection: Set<RoutingCanvasElementID>) {
    context.session.wrappedValue.selection = selection
    context.session.wrappedValue.focusedElementID = selection.first
  }

  private func moveNode(_ nodeID: RoutingCanvasElementID, translation: CGSize) {
    context.send(
      .nodeDragCompleted(
        FlowingGraphCanvasNodeDragIntent(
          nodeID: nodeID,
          basePresentationSnapshotID: scene.presentationSnapshotID,
          baseLayoutInputID: scene.contentID,
          translation: translation
        )
      )
    )
  }

  private func connect(
    sourceID: RoutingCanvasElementID,
    targetID: RoutingCanvasElementID
  ) {
    context.send(
      .connectionCompleted(
        FlowingGraphCanvasConnectionCompletionIntent(
          operation: .create(sourcePortID: sourceID, targetPortID: targetID),
          basePresentationSnapshotID: scene.presentationSnapshotID,
          baseLayoutInputID: scene.contentID
        )
      )
    )
  }

  private func updateViewport(
    _ viewport: FlowingCanvasViewport,
    phase: FlowingCanvasViewportChangePhase
  ) {
    guard context.session.wrappedValue.viewport != viewport else { return }
    context.session.wrappedValue.viewport = viewport
    context.viewportDidChange(viewport, phase: phase)
  }
}

private struct RoutingViewportControlButton: View {
  let systemImage: String
  let accessibilityLabel: String
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 9.5, weight: .bold))
        .foregroundStyle(FlowingPalette.muted)
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
    .help(accessibilityLabel)
  }
}
