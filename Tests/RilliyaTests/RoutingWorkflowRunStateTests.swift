import CoreGraphics
import Foundation
import Testing

@testable import Rilliya

@Suite("Routing workflow run state")
struct RoutingWorkflowRunStateTests {
  @Test
  func aPausedWorkflowStaysPausedRegardlessOfFailures() {
    #expect(RoutingWorkflowRunState(isRunning: false, failingNodeCount: 0) == .paused)
    #expect(RoutingWorkflowRunState(isRunning: false, failingNodeCount: 3) == .paused)
  }

  @Test
  func aRunningWorkflowReportsItsStoppedNodes() {
    #expect(RoutingWorkflowRunState(isRunning: true, failingNodeCount: 0) == .running)
    #expect(
      RoutingWorkflowRunState(isRunning: true, failingNodeCount: 2)
        == .runningWithIssues(count: 2)
    )
  }

  @Test
  func theAccessibilityValueDistinguishesAllThreeStates() {
    #expect(RoutingWorkflowRunState.paused.accessibilityValue == "Paused")
    #expect(RoutingWorkflowRunState.running.accessibilityValue == "Running")
    #expect(
      RoutingWorkflowRunState.runningWithIssues(count: 1).accessibilityValue
        == "Running, 1 stopped node"
    )
    #expect(
      RoutingWorkflowRunState.runningWithIssues(count: 4).accessibilityValue
        == "Running, 4 stopped nodes"
    )
  }

  /// Stepping through issues should follow the graph, so the order has to match the canvas
  /// rather than whatever order a dictionary happens to produce.
  @Test @MainActor
  func failingNodesAreReportedInCanvasOrder() {
    let workflow = RoutingWorkflowModel(name: "Flow")
    let first = workflow.workspace.addNetworkReceiveNode(centeredAt: .zero)
    let healthy = workflow.workspace.addGainNode(centeredAt: CGPoint(x: 320, y: 0))
    let last = workflow.workspace.addNetworkSendNode(centeredAt: CGPoint(x: 640, y: 0))
    workflow.run()
    let reporters: [any RoutingNodeFailureReporting] = [
      StubFailureReporter(failing: [last]),
      StubFailureReporter(failing: [first]),
    ]

    let failing = RoutingWorkflowFailures.failingNodeIDs(in: workflow, reporters: reporters)

    #expect(failing == [first, last])
    #expect(!failing.contains(healthy))
  }

  @Test @MainActor
  func aPausedWorkflowReportsNoFailingNodes() {
    let workflow = RoutingWorkflowModel(name: "Flow")
    let nodeID = workflow.workspace.addNetworkSendNode(centeredAt: .zero)
    let reporters: [any RoutingNodeFailureReporting] = [StubFailureReporter(failing: [nodeID])]

    #expect(RoutingWorkflowFailures.failingNodeIDs(in: workflow, reporters: reporters).isEmpty)
  }
}

@MainActor
private final class StubFailureReporter: RoutingNodeFailureReporting {
  private let failing: Set<UUID>

  init(failing: Set<UUID>) {
    self.failing = failing
  }

  func failure(for nodeID: UUID) -> RoutingNodeFailure? {
    failing.contains(nodeID) ? RoutingNodeFailure(message: "Stopped.") : nil
  }
}
