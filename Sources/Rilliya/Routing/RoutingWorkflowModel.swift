import FlowingDayGraphCanvas
import Foundation
import Observation

@MainActor
@Observable
final class RoutingWorkflowModel: Identifiable {
  let id: UUID
  private(set) var name: String
  private(set) var miniMapVisibilityOverride: Bool?
  let workspace: RoutingWorkspaceModel
  var canvasSession: FlowingGraphCanvasSessionState<RoutingCanvasSchema>

  @ObservationIgnored let canvasSessionID: FlowingGraphCanvasSessionID

  init(
    id: UUID = UUID(),
    name: String,
    workspace: RoutingWorkspaceModel? = nil,
    miniMapVisibilityOverride: Bool? = nil,
    canvasSession: FlowingGraphCanvasSessionState<RoutingCanvasSchema> =
      FlowingGraphCanvasSessionState()
  ) {
    precondition(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    self.id = id
    self.name = name
    self.workspace = workspace ?? RoutingWorkspaceModel(id: id)
    self.miniMapVisibilityOverride = miniMapVisibilityOverride
    self.canvasSession = canvasSession
    canvasSessionID = FlowingGraphCanvasSessionID()
  }

  func rename(to name: String) {
    let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return }
    self.name = normalized
  }

  func showsMiniMap(globalDefault: Bool) -> Bool {
    miniMapVisibilityOverride ?? globalDefault
  }

  func setMiniMapVisible(_ isVisible: Bool) {
    miniMapVisibilityOverride = isVisible
  }

  func useGlobalMiniMapDefault() {
    miniMapVisibilityOverride = nil
  }
}

@MainActor
@Observable
final class RoutingWorkflowLibrary {
  private(set) var workflows: [RoutingWorkflowModel]
  private(set) var selectedWorkflowID: UUID

  init(workflows: [RoutingWorkflowModel] = []) {
    let initialWorkflows =
      workflows.isEmpty
      ? [RoutingWorkflowModel(name: "Flow 1")]
      : workflows
    precondition(Set(initialWorkflows.map(\.id)).count == initialWorkflows.count)
    self.workflows = initialWorkflows
    selectedWorkflowID = initialWorkflows[0].id
  }

  var selectedWorkflow: RoutingWorkflowModel {
    workflows.first { $0.id == selectedWorkflowID } ?? workflows[0]
  }

  @discardableResult
  func addWorkflow() -> RoutingWorkflowModel {
    let workflow = RoutingWorkflowModel(name: nextWorkflowName())
    workflows.append(workflow)
    selectedWorkflowID = workflow.id
    return workflow
  }

  func selectWorkflow(id: UUID) {
    guard workflows.contains(where: { $0.id == id }) else { return }
    selectedWorkflowID = id
  }

  private func nextWorkflowName() -> String {
    let existingNames = Set(workflows.map(\.name))
    var ordinal = workflows.count + 1
    while existingNames.contains("Flow \(ordinal)") {
      ordinal += 1
    }
    return "Flow \(ordinal)"
  }

  static func launchConfigured() -> RoutingWorkflowLibrary {
    #if PROFILE
      if let scenario = RoutingProfilingScenario.fromProcessArguments() {
        return scenario.makeWorkflowLibrary()
      }
    #endif
    return RoutingWorkflowLibrary()
  }
}
