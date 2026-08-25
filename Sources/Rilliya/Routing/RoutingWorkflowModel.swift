import FlowingDayGraphCanvas
import Foundation
import Observation

@MainActor
@Observable
final class RoutingWorkflowModel: Identifiable {
  let id: UUID
  private(set) var name: String
  private(set) var miniMapVisibilityOverride: Bool?
  private(set) var runsAutomaticallyOnLaunch: Bool
  private(set) var isRunning: Bool
  let workspace: RoutingWorkspaceModel
  var canvasSession: FlowingGraphCanvasSessionState<RoutingCanvasSchema>

  @ObservationIgnored let canvasSessionID: FlowingGraphCanvasSessionID

  init(
    id: UUID = UUID(),
    name: String,
    workspace: RoutingWorkspaceModel? = nil,
    miniMapVisibilityOverride: Bool? = nil,
    runsAutomaticallyOnLaunch: Bool = false,
    isRunning: Bool = false,
    canvasSession: FlowingGraphCanvasSessionState<RoutingCanvasSchema> =
      FlowingGraphCanvasSessionState()
  ) {
    precondition(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    self.id = id
    self.name = name
    self.workspace = workspace ?? RoutingWorkspaceModel(id: id)
    self.miniMapVisibilityOverride = miniMapVisibilityOverride
    self.runsAutomaticallyOnLaunch = runsAutomaticallyOnLaunch
    self.isRunning = isRunning
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

  func run() {
    isRunning = true
  }

  func pause() {
    isRunning = false
  }

  func toggleRunning() {
    isRunning.toggle()
  }

  func setRunsAutomaticallyOnLaunch(_ shouldRun: Bool) {
    runsAutomaticallyOnLaunch = shouldRun
  }
}

@MainActor
@Observable
final class RoutingWorkflowLibrary {
  private(set) var workflows: [RoutingWorkflowModel]
  private(set) var selectedWorkflowID: UUID

  init(
    workflows: [RoutingWorkflowModel] = [],
    selectedWorkflowID: UUID? = nil
  ) {
    let initialWorkflows =
      workflows.isEmpty
      ? [RoutingWorkflowModel(name: "Flow 1")]
      : workflows
    precondition(Set(initialWorkflows.map(\.id)).count == initialWorkflows.count)
    self.workflows = initialWorkflows
    self.selectedWorkflowID =
      selectedWorkflowID.flatMap { requestedID in
        initialWorkflows.contains(where: { $0.id == requestedID }) ? requestedID : nil
      }
      ?? initialWorkflows[0].id
  }

  var selectedWorkflow: RoutingWorkflowModel {
    workflows.first { $0.id == selectedWorkflowID } ?? workflows[0]
  }

  var isPristineForOnboarding: Bool {
    guard workflows.count == 1, let workflow = workflows.first else { return false }
    return workflow.name == "Flow 1"
      && workflow.workspace.nodes.isEmpty
      && workflow.workspace.edges.isEmpty
      && !workflow.isRunning
      && !workflow.runsAutomaticallyOnLaunch
      && workflow.miniMapVisibilityOverride == nil
  }

  @discardableResult
  func addWorkflow() -> RoutingWorkflowModel {
    let workflow = RoutingWorkflowModel(name: nextWorkflowName())
    workflows.append(workflow)
    selectedWorkflowID = workflow.id
    return workflow
  }

  @discardableResult
  func duplicateWorkflow(id: UUID) -> RoutingWorkflowModel? {
    guard let sourceIndex = workflows.firstIndex(where: { $0.id == id }) else {
      return nil
    }
    let source = workflows[sourceIndex]
    let nodeIDMap = Dictionary(
      uniqueKeysWithValues: source.workspace.nodes.map { ($0.id, UUID()) }
    )
    let nodes = source.workspace.nodes.compactMap { sourceNode -> RoutingWorkspaceNode? in
      guard let nodeID = nodeIDMap[sourceNode.id] else { return nil }
      return RoutingWorkspaceNode(
        id: nodeID,
        value: sourceNode.value,
        frame: sourceNode.frame,
        disabledPortIDs: sourceNode.disabledPortIDs,
        audioChannelControls: sourceNode.audioChannelControls,
        accentOverride: sourceNode.accentOverride
      )
    }
    let edges = source.workspace.edges.compactMap { sourceEdge -> RoutingWorkspaceEdge? in
      guard let sourceNodeID = nodeIDMap[sourceEdge.source.nodeID],
        let targetNodeID = nodeIDMap[sourceEdge.target.nodeID]
      else {
        return nil
      }
      return RoutingWorkspaceEdge(
        id: UUID(),
        source: RoutingWorkspacePortAddress(
          nodeID: sourceNodeID,
          portID: sourceEdge.source.portID
        ),
        target: RoutingWorkspacePortAddress(
          nodeID: targetNodeID,
          portID: sourceEdge.target.portID
        ),
        isEnabled: sourceEdge.isEnabled
      )
    }
    guard nodes.count == source.workspace.nodes.count,
      edges.count == source.workspace.edges.count,
      let workspace = try? RoutingWorkspaceModel(
        restoringID: UUID(),
        nodes: nodes,
        edges: edges
      )
    else {
      return nil
    }

    let workflow = RoutingWorkflowModel(
      id: workspace.id,
      name: uniqueCopyName(for: source.name),
      workspace: workspace,
      miniMapVisibilityOverride: source.miniMapVisibilityOverride,
      canvasSession: FlowingGraphCanvasSessionState(viewport: source.canvasSession.viewport)
    )
    workflows.insert(workflow, at: sourceIndex + 1)
    selectedWorkflowID = workflow.id
    return workflow
  }

  @discardableResult
  func removeWorkflow(id: UUID) -> Bool {
    guard workflows.count > 1,
      let removedIndex = workflows.firstIndex(where: { $0.id == id })
    else {
      return false
    }
    workflows.remove(at: removedIndex)
    if selectedWorkflowID == id {
      selectedWorkflowID = workflows[min(removedIndex, workflows.count - 1)].id
    }
    return true
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

  private func uniqueCopyName(for sourceName: String) -> String {
    let existingNames = Set(workflows.map(\.name))
    let baseName = "\(sourceName) Copy"
    guard existingNames.contains(baseName) else { return baseName }
    var ordinal = 2
    while existingNames.contains("\(baseName) \(ordinal)") {
      ordinal += 1
    }
    return "\(baseName) \(ordinal)"
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
