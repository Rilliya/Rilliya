import AppKit
import Foundation
import Observation
import RilliyaCapture
import RilliyaCore

@MainActor
@Observable
final class RilliyaRuntime {
  var workflowLibrary = RoutingWorkflowLibrary.launchConfigured()
  let applicationCatalog = InstalledApplicationCatalogController()
  let audioCatalog = AudioCatalogController()
  let iconResolver = NSWorkspaceInstalledApplicationIconResolver()
  let captureController = RoutingCaptureController()
  let inputCaptureController = RoutingInputCaptureController()
  let outputCaptureController = RoutingOutputCaptureController()
  let filePlaybackController = RoutingFilePlaybackController()
  let fileOutputController = RoutingFileOutputController()
  let networkSendController = RoutingNetworkSendController()
  let networkReceiveController = RoutingNetworkReceiveController()
  let outputController = RoutingAudioOutputController()
  let workflowPersistenceStore = RoutingWorkflowPersistenceStore()
  let managedApplicationStore = RilliyaManagedApplicationStore()
  let virtualAudioController = RilliyaVirtualAudioController.shared

  var didRestoreWorkflows = false
  var workflowSaveTask: Task<Void, Never>?
  var workflowPersistenceIssue: String?

  @ObservationIgnored private var isObservingAudioState = false
  @ObservationIgnored private var applicationMixerWorkflow: RoutingWorkflowModel?
  @ObservationIgnored private let applicationDirectoryMonitor:
    any InstalledApplicationDirectoryMonitoring
  @ObservationIgnored private var applicationDirectoryTask: Task<Void, Never>?
  @ObservationIgnored private var applicationLaunchTask: Task<Void, Never>?
  @ObservationIgnored private var applicationTerminationTask: Task<Void, Never>?

  init(
    applicationDirectoryMonitor: any InstalledApplicationDirectoryMonitoring =
      SystemInstalledApplicationDirectoryMonitor()
  ) {
    self.applicationDirectoryMonitor = applicationDirectoryMonitor
  }

  func start(settings: RilliyaSettings) {
    audioCatalog.start()
    startApplicationObservation()
    Task {
      await applicationCatalog.refresh()
      await virtualAudioController.refresh()
    }
    guard !isObservingAudioState else { return }
    isObservingAudioState = true
    observeAudioState(settings: settings)
  }

  var audioWorkflows: [RoutingWorkflowModel] {
    workflowLibrary.workflows + [applicationMixerWorkflow].compactMap { $0 }
  }

  func installedItem(
    for application: RilliyaManagedApplication
  ) -> InstalledApplicationCatalogItem? {
    let items = applicationCatalog.state.snapshot?.items ?? []
    let canonicalURL = canonicalApplicationURL(application.applicationURL)
    if let exact = items.first(where: {
      canonicalApplicationURL($0.application.bundleURL) == canonicalURL
    }) {
      return exact
    }
    guard let bundleIdentifier = application.bundleIdentifier else { return nil }
    let matches = items.filter { $0.application.bundleIdentifier == bundleIdentifier }
    return matches.count == 1 ? matches[0] : nil
  }

  func isProducingAudio(_ application: RilliyaManagedApplication) -> Bool {
    guard let item = installedItem(for: application) else { return false }
    let processIDs = Set(item.runningApplications.map(\.processIdentifier))
    return audioCatalog.state.snapshot?.processes.contains(where: {
      processIDs.contains($0.id.rawValue) && $0.isRunningOutput
    }) == true
  }

  func isManagedByWorkflow(_ application: RilliyaManagedApplication) -> Bool {
    RilliyaApplicationMixerBuilder.applicationsReroutedByWorkflows(
      workflowLibrary.workflows
    ).contains(canonicalApplicationURL(application.applicationURL))
  }

  func setWorkflowRunning(_ isRunning: Bool, id: UUID) {
    guard let workflow = workflowLibrary.workflows.first(where: { $0.id == id }) else { return }
    if isRunning {
      workflow.run()
    } else {
      workflow.pause()
    }
    scheduleWorkflowSave()
  }

  func scheduleWorkflowSave() {
    guard didRestoreWorkflows else { return }
    let snapshot = RoutingWorkflowLibrarySnapshot(library: workflowLibrary)
    workflowSaveTask?.cancel()
    let store = workflowPersistenceStore
    workflowSaveTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(400))
        try Task.checkCancellation()
        try await store.save(snapshot)
        self?.workflowPersistenceIssue = nil
      } catch is CancellationError {
        return
      } catch {
        self?.workflowPersistenceIssue = String(describing: error)
      }
    }
  }

  private func observeAudioState(settings: RilliyaSettings) {
    withObservationTracking {
      reconcileAudio(settings: settings)
    } onChange: { [weak self, weak settings] in
      Task { @MainActor in
        guard let self, let settings, self.isObservingAudioState else { return }
        self.observeAudioState(settings: settings)
      }
    }
  }

  private func reconcileAudio(settings: RilliyaSettings) {
    rebuildApplicationMixer()
    let workflows = audioWorkflows
    for workflow in workflows {
      workflow.workspace.synchronizeVirtualAudioCatalog(virtualAudioController.catalog)
    }
    let requirements = RoutingCaptureRequirementResolver.resolve(
      workflows: workflows,
      catalogSnapshot: applicationCatalog.state.snapshot,
      audioCatalogSnapshot: audioCatalog.state.snapshot,
      virtualAudioCatalog: virtualAudioController.catalog
    )
    captureController.reconcile(requirements: requirements)
    inputCaptureController.reconcile(deviceIDsByNode: requirements.inputDeviceIDsByNode)
    outputCaptureController.reconcile(
      deviceIDsByNode: requirements.outputCaptureDeviceIDsByNode,
      catalogRevision: audioCatalog.state.revision
    )

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
    let outputCaptureFormats = outputCaptureController.states.compactMapValues {
      state -> DeviceOutputCaptureFormat? in
      guard case .running(let format) = state else { return nil }
      return format
    }
    for workflow in workflows {
      workflow.workspace.synchronizeCaptureFormats(
        formats,
        preferredSeparateChannelCount: settings.defaultSeparateChannelLayout.channelCount
      )
      workflow.workspace.synchronizeInputCaptureFormats(
        inputFormats,
        preferredSeparateChannelCount: settings.defaultSeparateChannelLayout.channelCount
      )
      workflow.workspace.synchronizeOutputCaptureFormats(
        outputCaptureFormats,
        preferredSeparateChannelCount: settings.defaultSeparateChannelLayout.channelCount
      )
    }

    filePlaybackController.reconcile(
      requirements: RoutingFilePlaybackRequirementResolver.resolve(
        workflows: workflowLibrary.workflows,
        catalogSnapshot: audioCatalog.state.snapshot
      )
    )
    networkReceiveController.reconcile(
      requirements: RoutingNetworkReceiveRequirementResolver.resolve(
        workflows: workflowLibrary.workflows
      )
    )
    outputController.reconcile(
      workflows: workflows,
      captureController: captureController,
      inputCaptureController: inputCaptureController,
      outputCaptureController: outputCaptureController,
      filePlaybackController: filePlaybackController,
      networkReceiveController: networkReceiveController,
      virtualAudioCatalog: virtualAudioController.catalog
    )
    networkSendController.reconcile(
      workflows: workflowLibrary.workflows,
      captureController: captureController,
      inputCaptureController: inputCaptureController,
      outputCaptureController: outputCaptureController,
      filePlaybackController: filePlaybackController,
      networkReceiveController: networkReceiveController
    )
    fileOutputController.reconcile(
      workflows: workflowLibrary.workflows,
      captureController: captureController,
      inputCaptureController: inputCaptureController,
      outputCaptureController: outputCaptureController,
      filePlaybackController: filePlaybackController,
      networkReceiveController: networkReceiveController
    )
  }

  private func rebuildApplicationMixer() {
    let reroutedURLs = RilliyaApplicationMixerBuilder.applicationsReroutedByWorkflows(
      workflowLibrary.workflows
    )
    let availableApplications = managedApplicationStore.applications.filter { application in
      !reroutedURLs.contains(canonicalApplicationURL(application.applicationURL))
        && installedItem(for: application)?.isRunning == true
    }
    let defaultOutputDevice = audioCatalog.state.snapshot?.devices.first(where: {
      $0.output?.isDefault == true
    })
    applicationMixerWorkflow = RilliyaApplicationMixerBuilder.makeWorkflow(
      applications: availableApplications,
      defaultOutputDevice: defaultOutputDevice
    )
  }

  private func startApplicationObservation() {
    guard
      applicationDirectoryTask == nil,
      applicationLaunchTask == nil,
      applicationTerminationTask == nil
    else { return }
    let directoryChanges = applicationDirectoryMonitor.changes()
    applicationDirectoryTask = Task { @MainActor [weak self] in
      for await _ in directoryChanges {
        guard let self else { return }
        self.applicationCatalog.scheduleRefresh()
      }
    }
    applicationLaunchTask = Task { @MainActor [weak self] in
      for await _ in NSWorkspace.shared.notificationCenter.notifications(
        named: NSWorkspace.didLaunchApplicationNotification
      ) {
        guard let self else { return }
        self.applicationCatalog.scheduleRefresh(after: .milliseconds(100))
      }
    }
    applicationTerminationTask = Task { @MainActor [weak self] in
      for await notification in NSWorkspace.shared.notificationCenter.notifications(
        named: NSWorkspace.didTerminateApplicationNotification
      ) {
        guard let self else { return }
        if let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
          as? NSRunningApplication,
          let processID = AudioProcessID(rawValue: application.processIdentifier)
        {
          self.captureController.stop(processID: processID)
        }
        self.applicationCatalog.scheduleRefresh(after: .milliseconds(100))
      }
    }
  }
}
