import FlowingDayCanvas
import FlowingDayControls
import FlowingDayGraphCanvas
import SwiftUI

struct RoutingMetalViewport: View {
  let context: FlowingGraphCanvasBackendContext<RoutingCanvasSchema>
  let scene: RoutingMetalScene
  let inspectorID: UUID?
  let inspector: AnyView
  let removeNodes: (Set<UUID>) -> Void
  let removeEdges: (Set<UUID>) -> Void
  let toggleEdgeEnabled: (UUID) -> Void
  let togglePortEnabled: (UUID, RoutingGraphPortID) -> Void
  let setAudioChannelGain: (UUID, Int, Double) -> Void
  let toggleAudioChannelMuted: (UUID, Int) -> Void
  let showsDisabledPortCrosses: Bool
  let isMiniMapVisible: Bool
  let setMiniMapVisible: (Bool) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @StateObject private var controller: RoutingMetalCanvasController

  init(
    context: FlowingGraphCanvasBackendContext<RoutingCanvasSchema>,
    scene: RoutingMetalScene,
    inspectorID: UUID?,
    inspector: AnyView,
    removeNodes: @escaping (Set<UUID>) -> Void,
    removeEdges: @escaping (Set<UUID>) -> Void,
    toggleEdgeEnabled: @escaping (UUID) -> Void,
    togglePortEnabled: @escaping (UUID, RoutingGraphPortID) -> Void,
    setAudioChannelGain: @escaping (UUID, Int, Double) -> Void,
    toggleAudioChannelMuted: @escaping (UUID, Int) -> Void,
    showsDisabledPortCrosses: Bool,
    isMiniMapVisible: Bool,
    setMiniMapVisible: @escaping (Bool) -> Void
  ) {
    self.context = context
    self.scene = scene
    self.inspectorID = inspectorID
    self.inspector = inspector
    self.removeNodes = removeNodes
    self.removeEdges = removeEdges
    self.toggleEdgeEnabled = toggleEdgeEnabled
    self.togglePortEnabled = togglePortEnabled
    self.setAudioChannelGain = setAudioChannelGain
    self.toggleAudioChannelMuted = toggleAudioChannelMuted
    self.showsDisabledPortCrosses = showsDisabledPortCrosses
    self.isMiniMapVisible = isMiniMapVisible
    self.setMiniMapVisible = setMiniMapVisible
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
          mouseTool: controller.mouseTool,
          onSelectionChange: updateSelection,
          onMoveNodes: moveNodes,
          onConnect: connect,
          onDeleteNodes: removeNodes,
          onDeleteEdges: removeEdges,
          onToggleEdgeEnabled: toggleEdgeEnabled,
          onTogglePortEnabled: togglePortEnabled,
          onSetAudioChannelGain: setAudioChannelGain,
          onToggleAudioChannelMuted: toggleAudioChannelMuted,
          showsDisabledPortCrosses: showsDisabledPortCrosses,
          onViewportChange: updateViewport
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        FlowingCanvasViewportOverlay(
          alignment: .topTrailing,
          insets: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
        ) {
          VStack(alignment: .trailing, spacing: 12) {
            if isMiniMapVisible, !scene.nodes.isEmpty {
              miniMap
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }
            ZStack(alignment: .topTrailing) {
              if let inspectorID {
                inspector
                  .id(inspectorID)
                  .compositingGroup()
                  .transition(inspectorTransition)
              }
            }
          }
        }
        .animation(inspectorAnimation, value: inspectorID)
        .animation(inspectorAnimation, value: isMiniMapVisible)

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

  private var inspectorAnimation: Animation {
    reduceMotion
      ? .easeOut(duration: 0.12)
      : .spring(response: 0.34, dampingFraction: 0.88)
  }

  private var inspectorTransition: AnyTransition {
    reduceMotion
      ? .opacity
      : .opacity.combined(with: .move(edge: .trailing))
  }

  private var miniMap: some View {
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
        refreshPolicy: .afterChangesSettle,
        accessibilityLabel: "Audio routing overview"
      ),
      style: FlowingGraphMiniMapStyle(
        background: FlowingPalette.control.opacity(0.94),
        border: FlowingPalette.hairline,
        edge: FlowingAccent.fern.fill.opacity(0.28),
        viewportFill: FlowingAccent.fern.fill.opacity(0.1),
        viewportStroke: FlowingAccent.fern.fill.opacity(0.9),
        nodeStyles: RoutingAccentID.allCases.map {
          FlowingGraphMiniMapNodeStyle(fill: $0.accent.fill.opacity(0.78))
        },
        cornerRadius: 12
      ),
      nodeStyleIndex: { scene.miniMapStyleIndex(for: $0.id) }
    )
    .shadow(color: .black.opacity(0.07), radius: 10, y: 4)
  }

  private var viewportControls: some View {
    HStack(spacing: 0) {
      FlowingIconButton(
        "Select and move nodes",
        systemImage: "cursorarrow",
        isSelected: controller.mouseTool == .select
      ) {
        controller.setMouseTool(.select)
      }

      FlowingIconButton(
        "Pan canvas",
        systemImage: "hand.raised",
        isSelected: controller.mouseTool == .pan
      ) {
        controller.setMouseTool(.pan)
      }

      Rectangle()
        .fill(FlowingPalette.hairline)
        .frame(width: 1, height: 18)
        .padding(.horizontal, 3)

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

      Rectangle()
        .fill(FlowingPalette.hairline)
        .frame(width: 1, height: 18)
        .padding(.horizontal, 3)

      FlowingIconButton(
        isMiniMapVisible ? "Hide overview" : "Show overview",
        systemImage: "map",
        isSelected: isMiniMapVisible
      ) {
        setMiniMapVisible(!isMiniMapVisible)
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

  private func moveNodes(
    _ nodeIDs: Set<RoutingCanvasElementID>,
    translation: CGSize
  ) {
    guard let nodeID = nodeIDs.first else { return }
    context.send(
      .nodeDragCompleted(
        FlowingGraphCanvasNodeDragIntent(
          nodeID: nodeID,
          nodeIDs: nodeIDs,
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
    if RoutingViewportPersistencePolicy.shouldPersist(phase: phase),
      context.session.wrappedValue.viewport != viewport
    {
      context.session.wrappedValue.viewport = viewport
    }
    context.viewportDidChange(viewport, phase: phase)
  }
}

enum RoutingViewportPersistencePolicy {
  static func shouldPersist(phase: FlowingCanvasViewportChangePhase) -> Bool {
    phase == .ended
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
