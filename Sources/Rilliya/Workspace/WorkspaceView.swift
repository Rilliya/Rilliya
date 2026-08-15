import AppKit
import FlowingDayControls
import FlowingDayGraphCanvas
import RilliyaKit
import SwiftUI

struct WorkspaceView: View {
  let settings: RilliyaSettings

  @State private var workflowLibrary = RoutingWorkflowLibrary()
  @State private var applicationCatalog = InstalledApplicationCatalogController()
  @State private var iconResolver = NSWorkspaceInstalledApplicationIconResolver()
  @State private var captureController = RoutingCaptureController()

  var body: some View {
    ZStack {
      workspaceBackdrop

      HStack(spacing: 0) {
        RoutingNodePaletteView(
          applicationCatalog: applicationCatalog,
          insertApplicationAudio: insertApplicationAudio,
          insertVisualizer: insertVisualizer
        )

        workflowCanvas
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
    .onChange(of: captureRequirements, initial: true) { _, requirements in
      captureController.reconcile(requirements: requirements)
    }
    .onChange(of: captureController.states, initial: true) { _, states in
      let formats = states.compactMapValues { state -> ProcessOutputCaptureFormat? in
        guard case .running(let format) = state else { return nil }
        return format
      }
      for workflow in workflowLibrary.workflows {
        workflow.workspace.synchronizeCaptureFormats(formats)
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

  private var captureRequirements: RoutingCaptureRequirements {
    RoutingCaptureRequirementResolver.resolve(
      workflows: workflowLibrary.workflows,
      catalogSnapshot: applicationCatalog.state.snapshot
    )
  }

  private var workflowCanvas: some View {
    ZStack(alignment: .topLeading) {
      RoutingWorkflowCanvas(
        workflow: workflowLibrary.selectedWorkflow,
        settings: settings,
        applicationCatalog: applicationCatalog,
        iconResolver: iconResolver,
        captureController: captureController
      )

      RoutingWorkflowSwitcher(
        library: workflowLibrary,
        captureController: captureController
      )
      .padding(.top, 18)
      .padding(.leading, 18)
    }
  }

  private func insertApplicationAudio() {
    let workflow = workflowLibrary.selectedWorkflow
    let nodeID = workflow.workspace.addApplicationAudioNode(
      centeredAt: RoutingNodeInsertion.point(
        in: workflow.canvasSession.viewport.visibleWorldRect,
        existingNodeCount: workflow.workspace.nodes.count
      )
    )
    selectNode(nodeID, in: workflow)
  }

  private func insertVisualizer() {
    let workflow = workflowLibrary.selectedWorkflow
    let nodeID = workflow.workspace.addVisualizerNode(
      centeredAt: RoutingNodeInsertion.point(
        in: workflow.canvasSession.viewport.visibleWorldRect,
        existingNodeCount: workflow.workspace.nodes.count
      )
    )
    selectNode(nodeID, in: workflow)
  }

  private func selectNode(_ nodeID: UUID, in workflow: RoutingWorkflowModel) {
    guard let elementID = workflow.workspace.elementID(for: nodeID) else { return }
    workflow.canvasSession.selection = [elementID]
    workflow.canvasSession.focusedElementID = elementID
  }
}

private struct RoutingWorkflowCanvas: View {
  @Bindable var workflow: RoutingWorkflowModel

  let settings: RilliyaSettings
  let applicationCatalog: InstalledApplicationCatalogController
  let iconResolver: NSWorkspaceInstalledApplicationIconResolver
  let captureController: RoutingCaptureController

  var body: some View {
    RoutingCanvasView(
      workspace: workflow.workspace,
      settings: settings,
      applicationCatalog: applicationCatalog,
      iconResolver: iconResolver,
      captureController: captureController,
      sessionID: workflow.canvasSessionID,
      session: $workflow.canvasSession
    )
  }
}

private struct RoutingWorkflowSwitcher: View {
  let library: RoutingWorkflowLibrary
  let captureController: RoutingCaptureController

  var body: some View {
    HStack(spacing: 6) {
      if isCapturing(library.selectedWorkflow) {
        Circle()
          .fill(Color(nsColor: .systemGreen))
          .frame(width: 7, height: 7)
          .accessibilityLabel("Workflow has active audio capture")
      }

      FlowingMenu(
        library.selectedWorkflow.name,
        systemImage: "point.3.connected.trianglepath.dotted",
        minimumWidth: 144
      ) {
        ForEach(library.workflows) { workflow in
          Button {
            library.selectWorkflow(id: workflow.id)
          } label: {
            HStack {
              Text(workflow.name)
              if isCapturing(workflow) {
                Image(systemName: "waveform.circle.fill")
              }
              if workflow.id == library.selectedWorkflowID {
                Image(systemName: "checkmark")
              }
            }
          }
        }

        Divider()

        Button {
          library.addWorkflow()
        } label: {
          Label("New Workflow", systemImage: "plus")
        }
      }

      FlowingIconButton("New Workflow", systemImage: "plus") {
        library.addWorkflow()
      }
    }
    .padding(5)
    .background(
      FlowingPalette.control.opacity(0.96),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(FlowingPalette.hairline)
    }
    .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Workflows")
  }

  private func isCapturing(_ workflow: RoutingWorkflowModel) -> Bool {
    workflow.workspace.nodes.contains { node in
      switch captureController.state(for: node.id) {
      case .starting, .running:
        return true
      case .idle, .failed:
        return false
      }
    }
  }
}

#Preview {
  WorkspaceView(settings: RilliyaSettings.shared)
    .flowingAccent(.fern)
    .frame(width: 1_080, height: 680)
}
