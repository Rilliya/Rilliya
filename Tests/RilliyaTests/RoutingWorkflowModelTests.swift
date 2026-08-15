import CoreGraphics
import FlowingDayGraphCanvas
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
    #expect(!library.selectedWorkflow.isRunning)
    #expect(!library.selectedWorkflow.runsAutomaticallyOnLaunch)
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
  func duplicatingAWorkflowCopiesItsGraphWithFreshResourceIdentities() throws {
    let library = RoutingWorkflowLibrary()
    let original = library.selectedWorkflow
    original.rename(to: "Broadcast")
    original.setMiniMapVisible(false)
    original.setRunsAutomaticallyOnLaunch(true)
    original.run()
    let sourceNodeID = original.workspace.addApplicationAudioNode(
      centeredAt: CGPoint(x: 100, y: 100)
    )
    let targetNodeID = original.workspace.addVisualizerNode(
      centeredAt: CGPoint(x: 500, y: 100)
    )
    let content = try #require(original.workspace.canvasContent)
    let sourcePort = try #require(
      content.presentation.ports.first {
        guard case .port(let key) = $0.address.elementID else { return false }
        return key.nodeID == sourceNodeID && $0.value.direction == .output
      }
    )
    let targetPort = try #require(
      content.presentation.ports.first {
        guard case .port(let key) = $0.address.elementID else { return false }
        return key.nodeID == targetNodeID && $0.value.direction == .input
      }
    )
    original.workspace.send(
      .connectionCompleted(
        FlowingGraphCanvasConnectionCompletionIntent<RoutingCanvasSchema>(
          operation: .create(
            sourcePortID: sourcePort.id,
            targetPortID: targetPort.id
          ),
          basePresentationSnapshotID: content.presentation.snapshotID,
          baseLayoutInputID: content.id
        )
      )
    )

    let duplicate = try #require(library.duplicateWorkflow(id: original.id))

    #expect(duplicate.name == "Broadcast Copy")
    #expect(library.selectedWorkflow === duplicate)
    #expect(duplicate.id != original.id)
    #expect(duplicate.workspace.id == duplicate.id)
    #expect(
      Set(duplicate.workspace.nodes.map(\.id)).isDisjoint(with: original.workspace.nodes.map(\.id)))
    #expect(
      Set(duplicate.workspace.edges.map(\.id)).isDisjoint(with: original.workspace.edges.map(\.id)))
    #expect(duplicate.workspace.nodes.map(\.value) == original.workspace.nodes.map(\.value))
    #expect(duplicate.workspace.nodes.map(\.frame) == original.workspace.nodes.map(\.frame))
    #expect(duplicate.workspace.edges.count == 1)
    #expect(!duplicate.showsMiniMap(globalDefault: true))
    #expect(!duplicate.isRunning)
    #expect(!duplicate.runsAutomaticallyOnLaunch)
    #expect(duplicate.canvasSession.viewport == original.canvasSession.viewport)
    #expect(duplicate.canvasSession.selection.isEmpty)
  }

  @Test @MainActor
  func duplicateNamesStayDistinct() throws {
    let library = RoutingWorkflowLibrary()
    let originalID = library.selectedWorkflowID

    let firstCopy = try #require(library.duplicateWorkflow(id: originalID))
    library.selectWorkflow(id: originalID)
    let secondCopy = try #require(library.duplicateWorkflow(id: originalID))

    #expect(firstCopy.name == "Flow 1 Copy")
    #expect(secondCopy.name == "Flow 1 Copy 2")
  }

  @Test @MainActor
  func removingAWorkflowSelectsItsNearestNeighborAndPreservesOneWorkflow() {
    let library = RoutingWorkflowLibrary()
    let first = library.selectedWorkflow
    let second = library.addWorkflow()
    let third = library.addWorkflow()
    library.selectWorkflow(id: second.id)

    #expect(library.removeWorkflow(id: second.id))
    #expect(library.selectedWorkflow === third)
    #expect(library.workflows.map(\.id) == [first.id, third.id])
    #expect(!library.removeWorkflow(id: UUID()))
    #expect(library.removeWorkflow(id: first.id))
    #expect(library.workflows.count == 1)
    #expect(!library.removeWorkflow(id: third.id))
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

  @Test @MainActor
  func executionAndAutomaticLaunchStayLocalToEachWorkflow() {
    let library = RoutingWorkflowLibrary()
    let first = library.selectedWorkflow
    let second = library.addWorkflow()

    first.run()
    first.setRunsAutomaticallyOnLaunch(true)

    #expect(first.isRunning)
    #expect(first.runsAutomaticallyOnLaunch)
    #expect(!second.isRunning)
    #expect(!second.runsAutomaticallyOnLaunch)

    first.pause()
    #expect(!first.isRunning)
    #expect(first.runsAutomaticallyOnLaunch)

    second.toggleRunning()
    #expect(second.isRunning)
    #expect(!second.runsAutomaticallyOnLaunch)
  }
}
