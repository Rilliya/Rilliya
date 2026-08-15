import AppKit
import FlowingDayControls
import FlowingDayGraphCanvas
import RilliyaKit
import SwiftUI

struct WorkspaceView: View {
  let settings: RilliyaSettings

  @State private var workflowLibrary = RoutingWorkflowLibrary.launchConfigured()
  @State private var applicationCatalog = InstalledApplicationCatalogController()
  @State private var audioCatalog = AudioCatalogController()
  @State private var iconResolver = NSWorkspaceInstalledApplicationIconResolver()
  @State private var captureController = RoutingCaptureController()
  @State private var inputCaptureController = RoutingInputCaptureController()

  var body: some View {
    ZStack {
      workspaceBackdrop

      workflowCanvas

      RoutingNodePaletteView(
        applicationCatalog: applicationCatalog,
        allowsClickInsertion: settings.addsNodesOnPaletteClick,
        insertApplicationAudio: insertApplicationAudio,
        insertInputAudio: insertInputAudio,
        insertVisualizer: insertVisualizer,
        insertPeakLevel: insertPeakLevel
      ) {
        RoutingWorkflowSwitcher(
          library: workflowLibrary,
          captureController: captureController,
          inputCaptureController: inputCaptureController
        )
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .background(FlowingPalette.canvas)
    .background(NativeWindowChromeAttachment())
    .ignoresSafeArea(.container, edges: .top)
    .frame(minWidth: 840, minHeight: 560)
    .task {
      await applicationCatalog.refresh()
    }
    .task {
      audioCatalog.start()
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
      inputCaptureController.reconcile(
        deviceIDsByNode: requirements.inputDeviceIDsByNode
      )
    }
    .onChange(of: captureController.states, initial: true) { _, states in
      let formats = states.compactMapValues { state -> ProcessOutputCaptureFormat? in
        guard case .running(let format) = state else { return nil }
        return format
      }
      for workflow in workflowLibrary.workflows {
        workflow.workspace.synchronizeCaptureFormats(
          formats,
          preferredSeparateChannelCount: settings.defaultSeparateChannelLayout.channelCount
        )
      }
    }
    .onChange(of: inputCaptureController.states, initial: true) { _, states in
      let formats = states.compactMapValues { state -> DeviceInputCaptureFormat? in
        guard case .running(let format) = state else { return nil }
        return format
      }
      for workflow in workflowLibrary.workflows {
        workflow.workspace.synchronizeInputCaptureFormats(
          formats,
          preferredSeparateChannelCount: settings.defaultSeparateChannelLayout.channelCount
        )
      }
    }
    .onChange(of: settings.defaultSeparateChannelLayout, initial: true) { _, layout in
      let formats = captureController.states.compactMapValues {
        state -> ProcessOutputCaptureFormat? in
        guard case .running(let format) = state else { return nil }
        return format
      }
      let inputFormats = inputCaptureController.states.compactMapValues {
        state -> DeviceInputCaptureFormat? in
        guard case .running(let format) = state else { return nil }
        return format
      }
      for workflow in workflowLibrary.workflows {
        workflow.workspace.synchronizeCaptureFormats(
          formats,
          preferredSeparateChannelCount: layout.channelCount
        )
        workflow.workspace.synchronizeInputCaptureFormats(
          inputFormats,
          preferredSeparateChannelCount: layout.channelCount
        )
      }
    }
    .onDisappear {
      applicationCatalog.cancelRefresh()
      audioCatalog.stop()
      captureController.stopAll()
      inputCaptureController.stopAll()
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
    RoutingWorkflowCanvas(
      workflow: workflowLibrary.selectedWorkflow,
      settings: settings,
      applicationCatalog: applicationCatalog,
      audioCatalog: audioCatalog,
      iconResolver: iconResolver,
      captureController: captureController,
      inputCaptureController: inputCaptureController
    )
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

  private func insertInputAudio() {
    let workflow = workflowLibrary.selectedWorkflow
    let nodeID = workflow.workspace.addInputAudioNode(
      centeredAt: RoutingNodeInsertion.point(
        in: workflow.canvasSession.viewport.visibleWorldRect,
        existingNodeCount: workflow.workspace.nodes.count
      )
    )
    selectNode(nodeID, in: workflow)
  }

  private func insertPeakLevel() {
    let workflow = workflowLibrary.selectedWorkflow
    let nodeID = workflow.workspace.addPeakLevelNode(
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
  let audioCatalog: AudioCatalogController
  let iconResolver: NSWorkspaceInstalledApplicationIconResolver
  let captureController: RoutingCaptureController
  let inputCaptureController: RoutingInputCaptureController

  var body: some View {
    RoutingCanvasView(
      workspace: workflow.workspace,
      settings: settings,
      applicationCatalog: applicationCatalog,
      audioCatalog: audioCatalog,
      iconResolver: iconResolver,
      captureController: captureController,
      inputCaptureController: inputCaptureController,
      sessionID: workflow.canvasSessionID,
      session: $workflow.canvasSession,
      isMiniMapVisible: workflow.showsMiniMap(
        globalDefault: settings.showsMiniMapByDefault
      ),
      setMiniMapVisible: workflow.setMiniMapVisible
    )
  }
}

private struct RoutingWorkflowSwitcher: View {
  let library: RoutingWorkflowLibrary
  let captureController: RoutingCaptureController
  let inputCaptureController: RoutingInputCaptureController

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
        minimumWidth: 154,
        fillsAvailableWidth: true
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
      }

      FlowingIconButton("New Workflow", systemImage: "plus") {
        library.addWorkflow()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Workflows")
  }

  private func isCapturing(_ workflow: RoutingWorkflowModel) -> Bool {
    workflow.workspace.nodes.contains { node in
      switch captureController.state(for: node.id) {
      case .starting, .running:
        return true
      case .idle, .failed:
        break
      }
      switch inputCaptureController.state(for: node.id) {
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
