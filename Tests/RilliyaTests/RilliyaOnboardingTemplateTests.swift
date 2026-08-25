import Foundation
import Testing

@testable import Rilliya

struct RilliyaOnboardingTemplateTests {
  @Test @MainActor
  func selectedGoalsBecomeIndependentConnectedWorkflows() throws {
    let settings = RilliyaSettings(defaults: try makeDefaults())
    let library = try RilliyaOnboardingTemplateFactory(settings: settings).makeLibrary(
      for: [.listenToApplication, .routeInput, .recordApplication]
    )

    #expect(
      library.workflows.map(\.name)
        == ["Listen to an App", "Route a Microphone", "Record an App"]
    )
    #expect(library.selectedWorkflow === library.workflows[0])
    #expect(
      library.workflows.map { $0.workspace.nodes.map(\.value.title) }
        == [
          ["Application Audio", "Output Audio", "Visualizer"],
          ["Input Audio", "Output Audio"],
          ["Application Audio", "File Output"],
        ]
    )
    #expect(library.workflows.map { $0.workspace.edges.count } == [2, 1, 1])
    #expect(library.workflows.allSatisfy { !$0.isRunning })
    #expect(library.workflows.allSatisfy { !$0.runsAutomaticallyOnLaunch })
    #expect(library.workflows.allSatisfy { !$0.canvasSession.selection.isEmpty })
  }

  @Test @MainActor
  func duplicateGoalsCreateOnlyOneTemplate() throws {
    let settings = RilliyaSettings(defaults: try makeDefaults())
    let library = try RilliyaOnboardingTemplateFactory(settings: settings).makeLibrary(
      for: [.routeInput, .routeInput]
    )

    #expect(library.workflows.count == 1)
    #expect(library.selectedWorkflow.name == "Route a Microphone")
  }

  @Test @MainActor
  func templatesRoundTripThroughWorkflowPersistence() throws {
    let settings = RilliyaSettings(defaults: try makeDefaults())
    let library = try RilliyaOnboardingTemplateFactory(settings: settings).makeLibrary(
      for: [.listenToApplication, .recordApplication]
    )

    let restored = try RoutingWorkflowLibrarySnapshot(library: library).makeLibrary()

    #expect(restored.workflows.map(\.name) == ["Listen to an App", "Record an App"])
    #expect(restored.workflows.map { $0.workspace.nodes.count } == [3, 2])
    #expect(restored.workflows.map { $0.workspace.edges.count } == [2, 1])
    #expect(!restored.workflows[0].isRunning)
    #expect(!restored.workflows[1].isRunning)
  }

  @Test @MainActor
  func emptySelectionIsRejected() throws {
    let settings = RilliyaSettings(defaults: try makeDefaults())

    #expect(throws: RilliyaOnboardingTemplateError.noGoalsSelected) {
      try RilliyaOnboardingTemplateFactory(settings: settings).makeLibrary(for: [])
    }
  }

  @Test @MainActor
  func onlyTheUntouchedInitialWorkflowAcceptsOnboardingTemplates() throws {
    let untouched = RoutingWorkflowLibrary()
    #expect(untouched.isPristineForOnboarding)

    let edited = RoutingWorkflowLibrary()
    _ = edited.selectedWorkflow.workspace.addApplicationAudioNode(centeredAt: .zero)
    #expect(!edited.isPristineForOnboarding)

    let renamed = RoutingWorkflowLibrary()
    renamed.selectedWorkflow.rename(to: "My Flow")
    #expect(!renamed.isPristineForOnboarding)
  }

  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "moe.uwucocoa.rilliya.onboarding-template-tests.\(UUID().uuidString)"
    return try #require(UserDefaults(suiteName: suiteName))
  }
}
