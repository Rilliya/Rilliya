import CoreGraphics
import Foundation
import Testing

@testable import Rilliya

struct RoutingWorkflowModelTests {
  @Test @MainActor
  func libraryStartsWithOneSelectedWorkflow() {
    let library = RoutingWorkflowLibrary()

    #expect(library.workflows.count == 1)
    #expect(library.selectedWorkflow.name == "Flow 1")
    #expect(library.selectedWorkflowID == library.selectedWorkflow.id)
    #expect(library.selectedWorkflow.workspace.id == library.selectedWorkflow.id)
  }

  @Test @MainActor
  func addingAndSwitchingWorkflowsPreservesIndependentGraphs() {
    let library = RoutingWorkflowLibrary()
    let first = library.selectedWorkflow
    _ = first.workspace.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))

    let second = library.addWorkflow()
    _ = second.workspace.addVisualizerNode(centeredAt: CGPoint(x: 500, y: 300))

    #expect(library.selectedWorkflow === second)
    #expect(first.workspace.nodes.count == 1)
    #expect(second.workspace.nodes.count == 1)
    #expect(first.workspace.nodes.first?.value.title == "Application Audio")
    #expect(second.workspace.nodes.first?.value.title == "Visualizer")
    #expect(first.workspace.id != second.workspace.id)

    library.selectWorkflow(id: first.id)

    #expect(library.selectedWorkflow === first)
    #expect(first.workspace.nodes.count == 1)
    #expect(second.workspace.nodes.count == 1)
  }

  @Test @MainActor
  func workflowNamesRemainNonemptyAndNewNamesStayDistinct() {
    let library = RoutingWorkflowLibrary()
    let first = library.selectedWorkflow
    first.rename(to: "  Music Lab  ")
    first.rename(to: "   ")

    let second = library.addWorkflow()
    second.rename(to: "Flow 3")
    let third = library.addWorkflow()

    #expect(first.name == "Music Lab")
    #expect(second.name == "Flow 3")
    #expect(third.name == "Flow 4")
  }

  @Test @MainActor
  func unknownWorkflowSelectionIsIgnored() {
    let library = RoutingWorkflowLibrary()
    let originalID = library.selectedWorkflowID

    library.selectWorkflow(id: UUID())

    #expect(library.selectedWorkflowID == originalID)
  }

  @Test @MainActor
  func miniMapOverrideStaysLocalToItsWorkflowAndCanReturnToTheGlobalDefault() {
    let library = RoutingWorkflowLibrary()
    let first = library.selectedWorkflow
    let second = library.addWorkflow()

    #expect(first.showsMiniMap(globalDefault: true))
    #expect(!first.showsMiniMap(globalDefault: false))

    first.setMiniMapVisible(false)
    second.setMiniMapVisible(true)

    #expect(!first.showsMiniMap(globalDefault: true))
    #expect(second.showsMiniMap(globalDefault: false))

    first.useGlobalMiniMapDefault()

    #expect(first.showsMiniMap(globalDefault: true))
    #expect(!first.showsMiniMap(globalDefault: false))
    #expect(second.showsMiniMap(globalDefault: false))
  }
}
