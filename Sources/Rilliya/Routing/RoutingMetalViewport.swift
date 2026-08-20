import FlowingDayCanvas
import FlowingDayControls
import FlowingDayGraphCanvas
import SwiftUI
import os

struct RoutingMetalViewport: View {
  let context: FlowingGraphCanvasBackendContext<RoutingCanvasSchema>
  let scene: RoutingMetalScene
  let inspectorID: UUID?
  let inspector: AnyView
  let removeNodes: (Set<UUID>) -> Void
  let removeEdges: (Set<UUID>) -> Void
  let toggleEdgeEnabled: (UUID) -> Void
  let togglePortEnabled: (UUID, RoutingGraphPortID) -> Void
  let showNodeColorPicker: (UUID) -> Void
  let setAudioChannelGain: (UUID, Int, Double) -> Void
  let toggleAudioChannelMuted: (UUID, Int) -> Void
  let showsDisabledPortCrosses: Bool
  let isMiniMapVisible: Bool
  let setMiniMapVisible: (Bool) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var contextMenuRequest: RoutingCanvasContextMenuRequest?
  @State private var lastRevealedFailure: RoutingCanvasElementID?
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
    showNodeColorPicker: @escaping (UUID) -> Void,
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
    self.showNodeColorPicker = showNodeColorPicker
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
          onShowNodeColorPicker: showNodeColorPicker,
          onPresentContextMenu: { request in
            contextMenuRequest = request
          },
          onSetAudioChannelGain: setAudioChannelGain,
          onToggleAudioChannelMuted: toggleAudioChannelMuted,
          showsDisabledPortCrosses: showsDisabledPortCrosses,
          onViewportChange: updateViewport
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Laid over the canvas rather than stacked beside it. As siblings these decide how tall
        // the stack wants to be, so the canvas grew and shrank with whichever inspector was
        // showing and every node appeared to jump. An overlay is measured against the canvas and
        // can never resize it.
        .overlay {
          FlowingCanvasViewportOverlay(
            alignment: .topTrailing,
            // Stops above the control strip rather than behind it: this column and the strip share
            // the trailing edge, and the strip is the only way to reach a failing node.
            insets: EdgeInsets(
              top: 14,
              leading: 14,
              bottom: RoutingViewportControlMetrics.clearance,
              trailing: 14
            )
          ) {
            VStack(alignment: .trailing, spacing: 12) {
              if isMiniMapVisible, !scene.nodes.isEmpty {
                miniMap
                  .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
              }
              ZStack(alignment: .topTrailing) {
                if let inspectorID {
                  // Scrolls rather than squashes.
                  //
                  // The panel floats over the canvas, so its height is whatever the window leaves;
                  // a small window is an ordinary thing and the panel has to cope with it. Without
                  // somewhere to scroll, a panel taller than that got compressed instead, and the
                  // text allowed to shrink did: a segmented control rendered smaller inside a long
                  // inspector than inside a short one while everything around it stayed put.
                  ScrollView(.vertical, showsIndicators: false) {
                    inspector
                  }
                  .id(inspectorID)
                  .compositingGroup()
                  .transition(inspectorTransition)
                  .scrollBounceBehavior(.basedOnSize)
                }
              }
              // Takes what the mini map leaves, so the scroll view has a height to scroll within.
              // Without this the column is as tall as its content and scrolling never engages.
              .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity, alignment: .top)
          }
          .animation(inspectorAnimation, value: inspectorID)
          .animation(inspectorAnimation, value: isMiniMapVisible)
        }
        .overlay {
          FlowingCanvasViewportOverlay(
            alignment: .bottomTrailing,
            insets: EdgeInsets(
              top: RoutingViewportControlMetrics.inset,
              leading: RoutingViewportControlMetrics.inset,
              bottom: RoutingViewportControlMetrics.inset,
              trailing: RoutingViewportControlMetrics.inset
            )
          ) {
            viewportControls
          }
        }

        if let contextMenuRequest {
          FlowingContextMenu(
            anchor: contextMenuRequest.anchor,
            items: contextMenuRequest.items,
            onDismiss: { self.contextMenuRequest = nil }
          )
          .flowingAccent(contextMenuRequest.accentID.accent)
          .id(contextMenuRequest.id)
          .zIndex(10)
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
      if !failingNodes.isEmpty {
        Button(action: revealNextFailure) {
          HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
              .font(.system(size: 9.5, weight: .bold))
            Text("\(failingNodes.count)")
              .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
          }
          .foregroundStyle(Color(nsColor: .systemOrange))
          .frame(height: RoutingViewportControlMetrics.buttonHeight)
          .padding(.horizontal, 7)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
          failingNodes.count == 1
            ? "Go to the node with an issue" : "Go to the next node with an issue"
        )
        .accessibilityValue("\(failingNodes.count) nodes have issues")

        Rectangle()
          .fill(FlowingPalette.hairline)
          .frame(width: 1, height: 18)
          .padding(.horizontal, 3)
      }

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
    .padding(RoutingViewportControlMetrics.padding)
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

  /// The nodes wearing a failure badge, in the order the canvas lays them out.
  private var failingNodes: [RoutingMetalScene.Node] {
    scene.nodes.filter(\.showsFailureBadge)
  }

  /// Brings the next failing node into view and selects it, so its inspector explains the failure.
  private func revealNextFailure() {
    let failing = failingNodes
    guard
      let nextID = RoutingWorkflowFailures.nodeAfter(lastRevealedFailure, in: failing.map(\.id)),
      let next = failing.first(where: { $0.id == nextID })
    else { return }
    lastRevealedFailure = nextID
    controller.center(on: CGPoint(x: next.frame.midX, y: next.frame.midY))
    updateSelection([nextID])
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
      ViewportDiagnostics.report(
        "persisting \(phase) viewport \(viewport) over \(context.session.wrappedValue.viewport)")
      context.session.wrappedValue.viewport = viewport
    }
    context.viewportDidChange(viewport, phase: phase)
  }
}

/// What the viewport is being changed to and by what, and only while building for debugging.
///
/// A viewport written back from a layout pass and one written back from a gesture are the same
/// call from here, and only the numbers say which happened.
private enum ViewportDiagnostics {
  #if DEBUG
    private static let log = Logger(subsystem: "moe.uwucocoa.rilliya", category: "viewport")
  #endif

  /// Reports one persisted viewport change.
  static func report(_ message: @autoclosure () -> String) {
    #if DEBUG
      let text = message()
      log.debug("\(text, privacy: .public)")
    #endif
  }
}

enum RoutingViewportPersistencePolicy {
  static func shouldPersist(phase: FlowingCanvasViewportChangePhase) -> Bool {
    phase == .ended
  }
}

/// What the viewport controls occupy in the bottom-trailing corner.
///
/// Anything else placed in that corner has to clear them, or it covers the only way to reach a
/// failing node.
enum RoutingViewportControlMetrics {
  /// The control strip's button height.
  static let buttonHeight: CGFloat = 28

  /// The padding inside the strip's background.
  static let padding: CGFloat = 4

  /// The strip's distance from the viewport edge.
  static let inset: CGFloat = 14

  /// The bottom inset another bottom-trailing overlay needs to sit clear of the strip.
  static let clearance = inset + buttonHeight + padding * 2 + 8
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
