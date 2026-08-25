import CoreGraphics
import Foundation

enum RilliyaOnboardingTemplateError: LocalizedError, Equatable {
  case noGoalsSelected
  case workflowChanged
  case invalidTemplate(RilliyaOnboardingGoal)

  var errorDescription: String? {
    switch self {
    case .noGoalsSelected:
      "Choose at least one workflow to create."
    case .workflowChanged:
      "The canvas changed before the templates could be created. Your existing work was left untouched."
    case .invalidTemplate:
      "A starter workflow could not be created. Your existing work was left untouched."
    }
  }
}

@MainActor
struct RilliyaOnboardingTemplateFactory {
  private let settings: RilliyaSettings

  init(settings: RilliyaSettings) {
    self.settings = settings
  }

  func makeLibrary(for goals: [RilliyaOnboardingGoal]) throws -> RoutingWorkflowLibrary {
    let uniqueGoals = goals.reduce(into: [RilliyaOnboardingGoal]()) { result, goal in
      guard !result.contains(goal) else { return }
      result.append(goal)
    }
    guard !uniqueGoals.isEmpty else {
      throw RilliyaOnboardingTemplateError.noGoalsSelected
    }
    let workflows = try uniqueGoals.map(makeWorkflow)
    return RoutingWorkflowLibrary(
      workflows: workflows,
      selectedWorkflowID: workflows[0].id
    )
  }

  private func makeWorkflow(for goal: RilliyaOnboardingGoal) throws -> RoutingWorkflowModel {
    let workflowID = UUID()
    let workspace = RoutingWorkspaceModel(id: workflowID, settings: settings)
    let sourceNodeID = addSource(for: goal, to: workspace)
    let destinationNodeID = addDestination(for: goal, to: workspace)
    guard
      workspace.connectAggregateAudio(
        sourceNodeID: sourceNodeID,
        targetNodeID: destinationNodeID
      )
    else {
      throw RilliyaOnboardingTemplateError.invalidTemplate(goal)
    }

    let workflow = RoutingWorkflowModel(
      id: workflowID,
      name: goal.workflowName,
      workspace: workspace
    )
    if let elementID = workspace.elementID(for: sourceNodeID) {
      workflow.canvasSession.selection = [elementID]
      workflow.canvasSession.focusedElementID = elementID
    }
    return workflow
  }

  private func addSource(
    for goal: RilliyaOnboardingGoal,
    to workspace: RoutingWorkspaceModel
  ) -> UUID {
    switch goal {
    case .listenToApplication, .recordApplication:
      workspace.addApplicationAudioNode(centeredAt: CGPoint(x: -170, y: 0))
    case .routeInput:
      workspace.addInputAudioNode(centeredAt: CGPoint(x: -170, y: 0))
    }
  }

  private func addDestination(
    for goal: RilliyaOnboardingGoal,
    to workspace: RoutingWorkspaceModel
  ) -> UUID {
    switch goal {
    case .listenToApplication, .routeInput:
      workspace.addOutputAudioNode(centeredAt: CGPoint(x: 170, y: 0))
    case .recordApplication:
      workspace.addFileOutputNode(centeredAt: CGPoint(x: 170, y: 0))
    }
  }
}

extension RilliyaOnboardingGoal {
  fileprivate var workflowName: String {
    switch self {
    case .listenToApplication:
      "Listen to an App"
    case .routeInput:
      "Route a Microphone"
    case .recordApplication:
      "Record an App"
    }
  }
}
