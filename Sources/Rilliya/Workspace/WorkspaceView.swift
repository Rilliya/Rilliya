import AppKit
import FlowingDayCanvas
import FlowingDayControls
import FlowingDayGraphCanvas
import RilliyaCapture
import RilliyaCore
import SwiftUI

struct WorkspaceView: View {
  let settings: RilliyaSettings

  @Environment(\.scenePhase) private var scenePhase
  @State private var workflowLibrary = RoutingWorkflowLibrary.launchConfigured()
  @State private var applicationCatalog = InstalledApplicationCatalogController()
  @State private var audioCatalog = AudioCatalogController()
  @State private var iconResolver = NSWorkspaceInstalledApplicationIconResolver()
  @State private var captureController = RoutingCaptureController()
  @State private var inputCaptureController = RoutingInputCaptureController()
  @State private var filePlaybackController = RoutingFilePlaybackController()
  @State private var networkSendController = RoutingNetworkSendController()
  @State private var networkReceiveController = RoutingNetworkReceiveController()
  @State private var outputController = RoutingAudioOutputController()
  @State private var workflowPersistenceStore = RoutingWorkflowPersistenceStore()
  @State private var didRestoreWorkflows = false
  @State private var workflowSaveTask: Task<Void, Never>?
  @State private var workflowPersistenceIssue: String?

  var body: some View {
    ZStack {
      workspaceBackdrop

      workflowCanvas

      RoutingNodePaletteView(
        applicationCatalog: applicationCatalog,
        settings: settings,
        allowsClickInsertion: settings.addsNodesOnPaletteClick,
        insertApplicationAudio: insertApplicationAudio,
        insertInputAudio: insertInputAudio,
        insertOutputAudio: insertOutputAudio,
        insertVisualizer: insertVisualizer,
        insertAudioMixer: insertAudioMixer,
        insertGain: insertGain,
        insertChannelRouter: insertChannelRouter,
        insertPeakLevel: insertPeakLevel,
        insertSignalGenerator: insertSignalGenerator,
        insertFilePlayback: insertFilePlayback,
        insertNetworkSend: insertNetworkSend,
        insertNetworkReceive: insertNetworkReceive,
        insertDelay: insertDelay,
        insertNoiseGate: insertNoiseGate,
        insertCompressor: insertCompressor
      ) {
        RoutingWorkflowSwitcher(
          library: workflowLibrary,
          captureController: captureController,
          inputCaptureController: inputCaptureController
        )
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      if let workflowPersistenceIssue {
        FlowingCanvasViewportOverlay(
          alignment: .bottomTrailing,
          insets: EdgeInsets(top: 0, leading: 0, bottom: 22, trailing: 22)
        ) {
          FlowingCallout(
            workflowPersistenceIssue,
            title: "Workflows could not be saved",
            systemImage: "externaldrive.badge.exclamationmark",
            tone: .critical
          )
          .frame(maxWidth: 360)
        }
      }
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
      await restoreWorkflows()
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
    .onChange(of: filePlaybackRequirements, initial: true) { _, requirements in
      filePlaybackController.reconcile(requirements: requirements)
    }
    .onChange(of: networkReceiveRequirements, initial: true) { _, requirements in
      networkReceiveController.reconcile(requirements: requirements)
    }
    .onChange(of: outputReconciliationToken, initial: true) {
      outputController.reconcile(
        workflows: workflowLibrary.workflows,
        captureController: captureController,
        inputCaptureController: inputCaptureController,
        filePlaybackController: filePlaybackController,
        networkReceiveController: networkReceiveController
      )
      networkSendController.reconcile(
        workflows: workflowLibrary.workflows,
        captureController: captureController,
        inputCaptureController: inputCaptureController,
        filePlaybackController: filePlaybackController,
        networkReceiveController: networkReceiveController
      )
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
    .onChange(of: pinnedApplications, initial: true) { _, applications in
      Task {
        await iconResolver.updatePinnedApplications(applications)
      }
    }
    .onChange(of: workflowPersistenceToken) {
      scheduleWorkflowSave()
    }
    .onChange(of: scenePhase) { _, phase in
      handleScenePhaseChange(phase)
    }
    .onDisappear {
      saveWorkflowsImmediately()
      applicationCatalog.cancelRefresh()
      audioCatalog.stop()
      captureController.stopAll()
      inputCaptureController.stopAll()
      filePlaybackController.stopAll()
      networkSendController.stopAll()
      networkReceiveController.stopAll()
      outputController.stopAll()
    }
  }

  private var workflowPersistenceToken: RoutingWorkflowPersistenceToken {
    RoutingWorkflowPersistenceToken(library: workflowLibrary)
  }

  private var outputReconciliationToken: RoutingAudioOutputReconciliationToken {
    RoutingAudioOutputReconciliationToken(
      workflows: workflowLibrary.workflows,
      processStates: captureController.states,
      inputStates: inputCaptureController.states,
      fileStates: filePlaybackController.states,
      networkReceiveStates: networkReceiveController.states
    )
  }

  private var usesWorkflowPersistence: Bool {
    #if PROFILE
      RoutingProfilingScenario.fromProcessArguments() == nil
    #else
      true
    #endif
  }

  private func restoreWorkflows() async {
    guard !didRestoreWorkflows else { return }
    guard usesWorkflowPersistence else {
      didRestoreWorkflows = true
      return
    }
    do {
      if let snapshot = try await workflowPersistenceStore.load() {
        workflowLibrary = try snapshot.makeLibrary()
      }
    } catch {
      workflowPersistenceIssue = "Your previous workflows remain on disk. \(error)"
    }
    didRestoreWorkflows = true
  }

  private func scheduleWorkflowSave() {
    guard didRestoreWorkflows, usesWorkflowPersistence else { return }
    let snapshot = RoutingWorkflowLibrarySnapshot(library: workflowLibrary)
    workflowSaveTask?.cancel()
    workflowSaveTask = Task {
      do {
        try await Task.sleep(for: .milliseconds(400))
        try Task.checkCancellation()
        try await workflowPersistenceStore.save(snapshot)
        workflowPersistenceIssue = nil
      } catch is CancellationError {
        return
      } catch {
        workflowPersistenceIssue = String(describing: error)
      }
    }
  }

  private func saveWorkflowsImmediately() {
    guard didRestoreWorkflows, usesWorkflowPersistence else { return }
    let snapshot = RoutingWorkflowLibrarySnapshot(library: workflowLibrary)
    workflowSaveTask?.cancel()
    workflowSaveTask = Task {
      do {
        try await workflowPersistenceStore.save(snapshot)
        workflowPersistenceIssue = nil
      } catch {
        workflowPersistenceIssue = String(describing: error)
      }
    }
  }

  private func handleScenePhaseChange(_ phase: ScenePhase) {
    guard phase != ScenePhase.active else { return }
    saveWorkflowsImmediately()
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

  private var pinnedApplications: [InstalledApplication] {
    guard let items = applicationCatalog.state.snapshot?.items else { return [] }
    let configuredURLs = Set(
      workflowLibrary.workflows.flatMap { workflow in
        workflow.workspace.nodes.compactMap { node in
          node.value.applicationSelection.map {
            canonicalApplicationURL($0.applicationURL)
          }
        }
      }
    )
    return items.compactMap { item in
      configuredURLs.contains(canonicalApplicationURL(item.application.bundleURL))
        ? item.application
        : nil
    }
  }

  private var filePlaybackRequirements: [UUID: RoutingFilePlaybackRequirement] {
    RoutingFilePlaybackRequirementResolver.resolve(
      workflows: workflowLibrary.workflows,
      catalogSnapshot: audioCatalog.state.snapshot
    )
  }

  private var networkReceiveRequirements: [UUID: RoutingNetworkReceiveConfiguration] {
    RoutingNetworkReceiveRequirementResolver.resolve(workflows: workflowLibrary.workflows)
  }

  private var workflowCanvas: some View {
    RoutingWorkflowCanvas(
      workflow: workflowLibrary.selectedWorkflow,
      settings: settings,
      applicationCatalog: applicationCatalog,
      audioCatalog: audioCatalog,
      iconResolver: iconResolver,
      captureController: captureController,
      inputCaptureController: inputCaptureController,
      filePlaybackController: filePlaybackController,
      networkSendController: networkSendController,
      networkReceiveController: networkReceiveController,
      outputController: outputController
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

  private func insertOutputAudio() {
    let workflow = workflowLibrary.selectedWorkflow
    let nodeID = workflow.workspace.addOutputAudioNode(
      centeredAt: RoutingNodeInsertion.point(
        in: workflow.canvasSession.viewport.visibleWorldRect,
        existingNodeCount: workflow.workspace.nodes.count
      )
    )
    selectNode(nodeID, in: workflow)
  }

  private func insertAudioMixer() {
    let workflow = workflowLibrary.selectedWorkflow
    let nodeID = workflow.workspace.addAudioMixerNode(
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

  private func insertGain() {
    let workflow = workflowLibrary.selectedWorkflow
    let nodeID = workflow.workspace.addGainNode(
      centeredAt: RoutingNodeInsertion.point(
        in: workflow.canvasSession.viewport.visibleWorldRect,
        existingNodeCount: workflow.workspace.nodes.count
      )
    )
    selectNode(nodeID, in: workflow)
  }

  private func insertChannelRouter() {
    let workflow = workflowLibrary.selectedWorkflow
    let nodeID = workflow.workspace.addChannelRouterNode(
      centeredAt: RoutingNodeInsertion.point(
        in: workflow.canvasSession.viewport.visibleWorldRect,
        existingNodeCount: workflow.workspace.nodes.count
      )
    )
    selectNode(nodeID, in: workflow)
  }

  private func insertSignalGenerator() {
    let workflow = workflowLibrary.selectedWorkflow
    let nodeID = workflow.workspace.addSignalGeneratorNode(
      centeredAt: RoutingNodeInsertion.point(
        in: workflow.canvasSession.viewport.visibleWorldRect,
        existingNodeCount: workflow.workspace.nodes.count
      )
    )
    selectNode(nodeID, in: workflow)
  }

  private func insertFilePlayback() {
    let workflow = workflowLibrary.selectedWorkflow
    let nodeID = workflow.workspace.addFilePlaybackNode(
      centeredAt: RoutingNodeInsertion.point(
        in: workflow.canvasSession.viewport.visibleWorldRect,
        existingNodeCount: workflow.workspace.nodes.count
      )
    )
    selectNode(nodeID, in: workflow)
  }

  private func insertNetworkSend() {
    let workflow = workflowLibrary.selectedWorkflow
    let nodeID = workflow.workspace.addNetworkSendNode(
      centeredAt: RoutingNodeInsertion.point(
        in: workflow.canvasSession.viewport.visibleWorldRect,
        existingNodeCount: workflow.workspace.nodes.count
      )
    )
    selectNode(nodeID, in: workflow)
  }

  private func insertNetworkReceive() {
    let workflow = workflowLibrary.selectedWorkflow
    let nodeID = workflow.workspace.addNetworkReceiveNode(
      centeredAt: RoutingNodeInsertion.point(
        in: workflow.canvasSession.viewport.visibleWorldRect,
        existingNodeCount: workflow.workspace.nodes.count
      )
    )
    selectNode(nodeID, in: workflow)
  }

  private func insertDelay() {
    let workflow = workflowLibrary.selectedWorkflow
    let nodeID = workflow.workspace.addDelayNode(
      centeredAt: RoutingNodeInsertion.point(
        in: workflow.canvasSession.viewport.visibleWorldRect,
        existingNodeCount: workflow.workspace.nodes.count
      )
    )
    selectNode(nodeID, in: workflow)
  }

  private func insertNoiseGate() {
    let workflow = workflowLibrary.selectedWorkflow
    let nodeID = workflow.workspace.addNoiseGateNode(
      centeredAt: RoutingNodeInsertion.point(
        in: workflow.canvasSession.viewport.visibleWorldRect,
        existingNodeCount: workflow.workspace.nodes.count
      )
    )
    selectNode(nodeID, in: workflow)
  }

  private func insertCompressor() {
    let workflow = workflowLibrary.selectedWorkflow
    let nodeID = workflow.workspace.addCompressorNode(
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

private struct RoutingAudioOutputReconciliationToken: Equatable {
  struct Workflow: Equatable {
    let id: UUID
    let revision: UInt64
    let isRunning: Bool
  }

  struct ProcessState: Equatable {
    let nodeID: UUID
    let state: RoutingCaptureState
  }

  struct InputState: Equatable {
    let nodeID: UUID
    let state: RoutingInputCaptureState
  }

  struct FileState: Equatable {
    let nodeID: UUID
    let state: RoutingFilePlaybackState
  }

  struct NetworkReceiveState: Equatable {
    let nodeID: UUID
    let state: RoutingNetworkReceiveState
  }

  let workflows: [Workflow]
  let processStates: [ProcessState]
  let inputStates: [InputState]
  let fileStates: [FileState]
  let networkReceiveStates: [NetworkReceiveState]

  @MainActor
  init(
    workflows: [RoutingWorkflowModel],
    processStates: [UUID: RoutingCaptureState],
    inputStates: [UUID: RoutingInputCaptureState],
    fileStates: [UUID: RoutingFilePlaybackState],
    networkReceiveStates: [UUID: RoutingNetworkReceiveState]
  ) {
    self.workflows = workflows.map {
      Workflow(
        id: $0.id,
        revision: $0.workspace.persistenceRevision,
        isRunning: $0.isRunning
      )
    }
    self.processStates = processStates.map {
      ProcessState(nodeID: $0.key, state: $0.value)
    }.sorted { $0.nodeID.uuidString < $1.nodeID.uuidString }
    self.inputStates = inputStates.map {
      InputState(nodeID: $0.key, state: $0.value)
    }.sorted { $0.nodeID.uuidString < $1.nodeID.uuidString }
    self.fileStates = fileStates.map {
      FileState(nodeID: $0.key, state: $0.value)
    }.sorted { $0.nodeID.uuidString < $1.nodeID.uuidString }
    self.networkReceiveStates = networkReceiveStates.map {
      NetworkReceiveState(nodeID: $0.key, state: $0.value)
    }.sorted { $0.nodeID.uuidString < $1.nodeID.uuidString }
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
  let filePlaybackController: RoutingFilePlaybackController
  let networkSendController: RoutingNetworkSendController
  let networkReceiveController: RoutingNetworkReceiveController
  let outputController: RoutingAudioOutputController

  var body: some View {
    RoutingCanvasView(
      workspace: workflow.workspace,
      settings: settings,
      applicationCatalog: applicationCatalog,
      audioCatalog: audioCatalog,
      iconResolver: iconResolver,
      captureController: captureController,
      inputCaptureController: inputCaptureController,
      filePlaybackController: filePlaybackController,
      networkSendController: networkSendController,
      networkReceiveController: networkReceiveController,
      outputController: outputController,
      sessionID: workflow.canvasSessionID,
      isWorkflowRunning: workflow.isRunning,
      session: $workflow.canvasSession,
      isMiniMapVisible: workflow.showsMiniMap(
        globalDefault: settings.showsMiniMapByDefault
      ),
      setMiniMapVisible: workflow.setMiniMapVisible
    )
  }
}

private struct RoutingWorkflowSwitcher: View {
  private enum WorkflowDialog {
    case rename
    case delete
  }

  let library: RoutingWorkflowLibrary
  let captureController: RoutingCaptureController
  let inputCaptureController: RoutingInputCaptureController

  @State private var workflowDialog: WorkflowDialog?
  @State private var isWorkflowPopoverPresented = false
  @State private var pendingWorkflowID: UUID?
  @State private var proposedWorkflowName = ""

  var body: some View {
    HStack(spacing: 6) {
      if isCapturing(library.selectedWorkflow) {
        Circle()
          .fill(Color(nsColor: .systemGreen))
          .frame(width: 7, height: 7)
          .accessibilityLabel("Workflow has active audio capture")
      }

      FlowingPopover(
        isPresented: $isWorkflowPopoverPresented,
        accessibilityLabel: "Choose workflow",
        arrowEdge: .top,
        minimumWidth: 248,
        maximumWidth: 280,
        contentInsets: EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
      ) {
        RoutingWorkflowPopoverLabel(title: library.selectedWorkflow.name)
      } content: {
        workflowPopoverContent
      }
      .buttonStyle(.plain)
      .frame(maxWidth: .infinity)

      FlowingIconButton(
        library.selectedWorkflow.isRunning ? "Pause Workflow" : "Run Workflow",
        systemImage: library.selectedWorkflow.isRunning ? "pause.fill" : "play.fill",
        emphasis: .standard,
        isSelected: library.selectedWorkflow.isRunning
      ) {
        library.selectedWorkflow.toggleRunning()
      }
      .accessibilityValue(library.selectedWorkflow.isRunning ? "Running" : "Paused")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Workflows")
    .alert(workflowDialogTitle, isPresented: workflowDialogIsPresented) {
      switch workflowDialog {
      case .rename:
        TextField("Workflow name", text: $proposedWorkflowName)
        Button("Cancel", role: .cancel) {}
        Button("Rename") {
          guard let pendingWorkflowID,
            let workflow = library.workflows.first(where: { $0.id == pendingWorkflowID })
          else { return }
          workflow.rename(to: proposedWorkflowName)
        }
        .disabled(proposedWorkflowName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      case .delete:
        Button("Cancel", role: .cancel) {}
        Button("Delete", role: .destructive) {
          guard let pendingWorkflowID else { return }
          library.removeWorkflow(id: pendingWorkflowID)
        }
      case nil:
        Button("Cancel", role: .cancel) {}
      }
    } message: {
      Text(workflowDialogMessage)
    }
  }

  private var workflowPopoverContent: some View {
    VStack(alignment: .leading, spacing: 8) {
      VStack(spacing: 3) {
        ForEach(library.workflows) { workflow in
          RoutingWorkflowSelectionRow(
            name: workflow.name,
            isRunning: workflow.isRunning,
            isSelected: workflow.id == library.selectedWorkflowID
          ) {
            library.selectWorkflow(id: workflow.id)
            isWorkflowPopoverPresented = false
          }
        }
      }

      Divider()
        .overlay(FlowingPalette.hairline)

      HStack(spacing: 5) {
        FlowingIconButton("New Workflow", systemImage: "plus", emphasis: .standard) {
          library.addWorkflow()
          isWorkflowPopoverPresented = false
        }
        FlowingIconButton("Rename Workflow", systemImage: "pencil", emphasis: .standard) {
          isWorkflowPopoverPresented = false
          beginRenaming(library.selectedWorkflow)
        }
        FlowingIconButton(
          "Duplicate Workflow",
          systemImage: "plus.square.on.square",
          emphasis: .standard
        ) {
          library.duplicateWorkflow(id: library.selectedWorkflowID)
          isWorkflowPopoverPresented = false
        }
        FlowingIconButton("Delete Workflow", systemImage: "trash", emphasis: .standard) {
          isWorkflowPopoverPresented = false
          beginDeleting(library.selectedWorkflow)
        }
        .disabled(library.workflows.count == 1)
      }

      Divider()
        .overlay(FlowingPalette.hairline)

      RoutingWorkflowLaunchToggle(
        isOn: library.selectedWorkflow.runsAutomaticallyOnLaunch
      ) {
        let workflow = library.selectedWorkflow
        workflow.setRunsAutomaticallyOnLaunch(!workflow.runsAutomaticallyOnLaunch)
      }
    }
  }

  private var workflowDialogIsPresented: Binding<Bool> {
    Binding(
      get: { workflowDialog != nil },
      set: { isPresented in
        if !isPresented { workflowDialog = nil }
      }
    )
  }

  private var workflowDialogTitle: String {
    switch workflowDialog {
    case .rename:
      "Rename Workflow"
    case .delete:
      "Delete Workflow?"
    case nil:
      "Workflow"
    }
  }

  private var workflowDialogMessage: String {
    switch workflowDialog {
    case .rename:
      "Use a name that makes this audio flow easy to recognize."
    case .delete:
      "This removes the workflow and all of its nodes and connections."
    case nil:
      ""
    }
  }

  private func beginRenaming(_ workflow: RoutingWorkflowModel) {
    pendingWorkflowID = workflow.id
    proposedWorkflowName = workflow.name
    workflowDialog = .rename
  }

  private func beginDeleting(_ workflow: RoutingWorkflowModel) {
    pendingWorkflowID = workflow.id
    workflowDialog = .delete
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

private struct RoutingWorkflowPopoverLabel: View {
  let title: String

  @Environment(\.flowingAccent) private var accent
  @State private var isHovering = false

  var body: some View {
    HStack(spacing: 7) {
      Text(title)
        .font(.callout.weight(.semibold))
        .lineLimit(1)
      Spacer(minLength: 4)
      Image(systemName: "chevron.down")
        .font(.system(size: 8, weight: .bold))
    }
    .foregroundStyle(accent.foreground)
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
    .background(
      isHovering ? accent.wash : accent.veil,
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(accent.foreground.opacity(0.16))
    }
    .contentShape(Rectangle())
    .onHover { isHovering = $0 }
  }
}

private struct RoutingWorkflowSelectionRow: View {
  let name: String
  let isRunning: Bool
  let isSelected: Bool
  let action: () -> Void

  @Environment(\.flowingAccent) private var accent
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Circle()
          .fill(isRunning ? Color(nsColor: .systemGreen) : FlowingPalette.hairline)
          .frame(width: 7, height: 7)
          .accessibilityHidden(true)
        Text(name)
          .font(.callout.weight(isSelected ? .semibold : .regular))
          .foregroundStyle(FlowingPalette.ink)
          .lineLimit(1)
        Spacer(minLength: 8)
        if isSelected {
          Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(accent.foreground)
        }
      }
      .padding(.horizontal, 9)
      .frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
      .background(
        isSelected ? accent.veil : (isHovering ? FlowingPalette.control : .clear),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .accessibilityLabel(name)
    .accessibilityValue(
      [isSelected ? "Selected" : nil, isRunning ? "Running" : "Paused"]
        .compactMap { $0 }
        .joined(separator: ", ")
    )
  }
}

private struct RoutingWorkflowLaunchToggle: View {
  let isOn: Bool
  let action: () -> Void

  @Environment(\.flowingAccent) private var accent
  @State private var isHovering = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(isOn ? accent.foreground : FlowingPalette.muted)
        Text("Run on App Launch")
          .font(.callout)
          .foregroundStyle(FlowingPalette.ink)
        Spacer(minLength: 8)
      }
      .padding(.horizontal, 9)
      .frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
      .background(
        isHovering ? accent.veil.opacity(0.72) : .clear,
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .accessibilityLabel("Run on App Launch")
    .accessibilityValue(isOn ? "On" : "Off")
  }
}

#Preview {
  WorkspaceView(settings: RilliyaSettings.shared)
    .flowingAccent(.fern)
    .frame(width: 1_080, height: 680)
}
