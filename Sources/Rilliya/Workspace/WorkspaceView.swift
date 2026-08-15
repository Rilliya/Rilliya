import AppKit
import FlowingDayControls
import FlowingDayGraphCanvas
import SwiftUI

struct WorkspaceView: View {
  @State private var routingWorkspace = RoutingWorkspaceModel()
  @State private var applicationCatalog = InstalledApplicationCatalogController()
  @State private var iconResolver = NSWorkspaceInstalledApplicationIconResolver()
  @State private var canvasSession = FlowingGraphCanvasSessionState<RoutingCanvasSchema>()
  @State private var inspectedNodeID: UUID?

  private let canvasSessionID = FlowingGraphCanvasSessionID()

  var body: some View {
    HStack(spacing: 0) {
      RoutingNodePaletteView(
        applicationCatalog: applicationCatalog,
        insertApplicationAudio: insertApplicationAudio
      )

      Divider()
        .overlay(FlowingPalette.hairline)

      RoutingCanvasView(
        workspace: routingWorkspace,
        applicationCatalog: applicationCatalog,
        iconResolver: iconResolver,
        sessionID: canvasSessionID,
        session: $canvasSession,
        inspectedNodeID: $inspectedNodeID
      )
    }
    .background(FlowingPalette.canvas)
    .frame(minWidth: 840, minHeight: 560)
    .task {
      await applicationCatalog.refresh()
    }
    .task {
      for await _ in NSWorkspace.shared.notificationCenter.notifications(
        named: NSWorkspace.didLaunchApplicationNotification
      ) {
        await applicationCatalog.refresh()
      }
    }
    .task {
      for await _ in NSWorkspace.shared.notificationCenter.notifications(
        named: NSWorkspace.didTerminateApplicationNotification
      ) {
        await applicationCatalog.refresh()
      }
    }
    .onDisappear {
      applicationCatalog.cancelRefresh()
    }
  }

  private func insertApplicationAudio() {
    inspectedNodeID = routingWorkspace.addApplicationAudioNode(
      centeredAt: RoutingNodeInsertion.point(
        in: canvasSession.viewport.visibleWorldRect,
        existingNodeCount: routingWorkspace.nodes.count
      )
    )
  }
}

#Preview {
  WorkspaceView()
    .flowingAccent(.fern)
    .frame(width: 1_080, height: 680)
}
