import CoreGraphics
import Foundation
import Testing

@testable import Rilliya

@Suite("Routing node failure presentation")
struct RoutingMetalNodeFailureTests {
  private enum Fixture {
    static let phrased = RoutingNodeFailure(
      summary: "Sample rate mismatch",
      message: "Audio source needs explicit sample-rate conversion before playback."
    )
    static let unphrased = RoutingNodeFailure(message: "Something outside the known causes.")
  }

  @Test
  func aHealthySupplementHasNoFailure() {
    #expect(RoutingMetalNodeSupplement.empty.failure == nil)
  }

  @Test
  func eachControllerStateSurfacesItsFailure() {
    let states: [RoutingMetalNodeSupplement] = [
      RoutingMetalNodeSupplement(
        isRunning: false, isCapturing: false, captureConsumerCount: 0, visualizerSignal: nil,
        captureState: .failed(Fixture.phrased)),
      RoutingMetalNodeSupplement(
        isRunning: false, isCapturing: false, captureConsumerCount: 0, visualizerSignal: nil,
        inputCaptureState: .failed(Fixture.phrased)),
      RoutingMetalNodeSupplement(
        isRunning: false, isCapturing: false, captureConsumerCount: 0, visualizerSignal: nil,
        outputCaptureState: .failed(Fixture.phrased)),
      RoutingMetalNodeSupplement(
        isRunning: false, isCapturing: false, captureConsumerCount: 0, visualizerSignal: nil,
        audioOutputState: .failed(Fixture.phrased)),
      RoutingMetalNodeSupplement(
        isRunning: false, isCapturing: false, captureConsumerCount: 0, visualizerSignal: nil,
        filePlaybackState: .failed(Fixture.phrased)),
      RoutingMetalNodeSupplement(
        isRunning: false, isCapturing: false, captureConsumerCount: 0, visualizerSignal: nil,
        fileOutputState: .failed(Fixture.phrased)),
      RoutingMetalNodeSupplement(
        isRunning: false, isCapturing: false, captureConsumerCount: 0, visualizerSignal: nil,
        networkSendState: .failed(Fixture.phrased)),
      RoutingMetalNodeSupplement(
        isRunning: false, isCapturing: false, captureConsumerCount: 0, visualizerSignal: nil,
        networkReceiveState: .failed(Fixture.phrased)),
    ]

    #expect(states.allSatisfy { $0.failure == Fixture.phrased })
  }

  @Test @MainActor
  func aPhrasedFailureReplacesTheNodeKindOnTheStatusLine() throws {
    let node = try makeNode(supplement: supplement(failing: Fixture.phrased))

    #expect(node.showsFailureBadge)
    #expect(
      node.statusLine == RoutingMetalNodeStatusLine(text: "Sample rate mismatch", isFailure: true))
  }

  /// The badge alone says something is wrong; the first words of an arbitrary message would not.
  @Test @MainActor
  func anUnphrasedFailureShowsTheBadgeAndKeepsTheNodeKind() throws {
    let node = try makeNode(supplement: supplement(failing: Fixture.unphrased))

    #expect(node.showsFailureBadge)
    #expect(node.statusLine == RoutingMetalNodeStatusLine(text: "Network Send", isFailure: false))
  }

  @Test @MainActor
  func aHealthyNodeKeepsTheNodeKind() throws {
    let node = try makeNode(
      supplement: RoutingMetalNodeSupplement(
        isRunning: true,
        isCapturing: false,
        captureConsumerCount: 0,
        visualizerSignal: nil,
        networkSendState: .starting
      )
    )

    #expect(!node.showsFailureBadge)
    #expect(node.statusLine == RoutingMetalNodeStatusLine(text: "Network Send", isFailure: false))
  }

  private func supplement(failing failure: RoutingNodeFailure) -> RoutingMetalNodeSupplement {
    RoutingMetalNodeSupplement(
      isRunning: true,
      isCapturing: false,
      captureConsumerCount: 0,
      visualizerSignal: nil,
      networkSendState: .failed(failure)
    )
  }

  @MainActor
  private func makeNode(
    supplement: RoutingMetalNodeSupplement
  ) throws -> RoutingMetalScene.Node {
    let workspace = RoutingWorkspaceModel()
    let nodeID = workspace.addNetworkSendNode(centeredAt: CGPoint(x: 100, y: 100))
    let scene = RoutingMetalScene(
      content: try #require(workspace.canvasContent),
      supplements: [nodeID: supplement]
    )
    return try #require(scene.nodes.first)
  }
}
