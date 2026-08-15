import AppKit
import FlowingDayControls
import FlowingDayGraphCanvas
import RilliyaKit
import SwiftUI

struct WorkspaceView: View {
  @State private var routingWorkspace = RoutingWorkspaceModel()
  @State private var applicationCatalog = InstalledApplicationCatalogController()
  @State private var iconResolver = NSWorkspaceInstalledApplicationIconResolver()
  @State private var captureController = RoutingCaptureController()
  @State private var canvasSession = FlowingGraphCanvasSessionState<RoutingCanvasSchema>()

  private let canvasSessionID = FlowingGraphCanvasSessionID()

  var body: some View {
    ZStack {
      workspaceBackdrop

      HStack(spacing: 0) {
        RoutingNodePaletteView(
          applicationCatalog: applicationCatalog,
          insertApplicationAudio: insertApplicationAudio,
          insertVisualizer: insertVisualizer
        )

        RoutingCanvasView(
          workspace: routingWorkspace,
          applicationCatalog: applicationCatalog,
          iconResolver: iconResolver,
          captureController: captureController,
          sessionID: canvasSessionID,
          session: $canvasSession
        )
      }
    }
    .background(FlowingPalette.canvas)
    .background(NativeWindowChromeAttachment())
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
      for await notification in NSWorkspace.shared.notificationCenter.notifications(
        named: NSWorkspace.didTerminateApplicationNotification
      ) {
        if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
          let processID = AudioProcessID(rawValue: application.processIdentifier)
        {
          captureController.stop(processID: processID)
        }
        await applicationCatalog.refresh()
      }
    }
    .onDisappear {
      applicationCatalog.cancelRefresh()
      captureController.stopAll()
    }
  }

  private var workspaceBackdrop: some View {
    FlowingPalette.canvas
      .ignoresSafeArea()
      .allowsHitTesting(false)
  }

  private func insertApplicationAudio() {
    let nodeID = routingWorkspace.addApplicationAudioNode(
      centeredAt: RoutingNodeInsertion.point(
        in: canvasSession.viewport.visibleWorldRect,
        existingNodeCount: routingWorkspace.nodes.count
      )
    )
    selectNode(nodeID)
  }

  private func insertVisualizer() {
    let nodeID = routingWorkspace.addVisualizerNode(
      centeredAt: RoutingNodeInsertion.point(
        in: canvasSession.viewport.visibleWorldRect,
        existingNodeCount: routingWorkspace.nodes.count
      )
    )
    selectNode(nodeID)
  }

  private func selectNode(_ nodeID: UUID) {
    guard let elementID = routingWorkspace.elementID(for: nodeID) else { return }
    canvasSession.selection = [elementID]
    canvasSession.focusedElementID = elementID
  }
}

#Preview {
  WorkspaceView()
    .flowingAccent(.fern)
    .frame(width: 1_080, height: 680)
}
