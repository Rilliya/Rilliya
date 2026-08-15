import CoreGraphics
import Testing

@testable import Rilliya

@Suite("Routing Metal scene")
struct RoutingMetalSceneTests {
  @Test @MainActor
  func selectedNodeRendersLastAndCarriesItsPorts() throws {
    let model = RoutingWorkspaceModel()
    let firstID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))
    let secondID = model.addVisualizerNode(centeredAt: CGPoint(x: 500, y: 100))
    let content = try #require(model.canvasContent)
    let scene = RoutingMetalScene(content: content, supplements: [:])
    let firstElementID = try #require(model.elementID(for: firstID))

    let ordered = scene.nodesInRenderOrder(selection: [firstElementID])

    #expect(ordered.map(\.workspaceID) == [secondID, firstID])
    #expect(ordered.last?.ports.count == 1)
    #expect(ordered.last?.ports.first?.value.direction == .output)
  }

  @Test @MainActor
  func sceneUsesActualNodeBoundsInsteadOfThePanSafetyBounds() throws {
    let model = RoutingWorkspaceModel()
    _ = model.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))
    _ = model.addVisualizerNode(centeredAt: CGPoint(x: 500, y: 100))
    let scene = RoutingMetalScene(
      content: try #require(model.canvasContent),
      supplements: [:]
    )

    #expect(scene.contentBounds.width < 1_000)
    #expect(scene.contentBounds.height < 500)
  }

  @Test @MainActor
  func connectionValidationMatchesChannelRoutingRules() throws {
    let model = RoutingWorkspaceModel()
    let sourceID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))
    let targetID = model.addVisualizerNode(centeredAt: CGPoint(x: 500, y: 100))
    model.setApplicationChannelPresentation(.separate(channelCount: 2), for: sourceID)
    model.configureVisualizer(
      RoutingVisualizerConfiguration(
        mode: .separate,
        availableChannelCount: 2,
        selectedChannels: [0, 1]
      ),
      for: targetID
    )
    let scene = RoutingMetalScene(
      content: try #require(model.canvasContent),
      supplements: [:]
    )
    let source = try #require(
      scene.nodes.first { $0.workspaceID == sourceID }?.ports.first {
        $0.value.channel == .channel(0)
      }
    )
    let matchingTarget = try #require(
      scene.nodes.first { $0.workspaceID == targetID }?.ports.first {
        $0.value.channel == .channel(0)
      }
    )
    let mismatchedTarget = try #require(
      scene.nodes.first { $0.workspaceID == targetID }?.ports.first {
        $0.value.channel == .channel(1)
      }
    )

    #expect(scene.validatesConnection(from: source, to: matchingTarget))
    #expect(!scene.validatesConnection(from: source, to: mismatchedTarget))
  }

  @Test @MainActor
  func visualizerSignalIsRetainedForGpuRendering() throws {
    let model = RoutingWorkspaceModel()
    let nodeID = model.addVisualizerNode(centeredAt: CGPoint(x: 100, y: 100))
    let signal = RoutingVisualizerSignal(waveforms: [[0, 0.5, -0.5, 0]])
    let scene = RoutingMetalScene(
      content: try #require(model.canvasContent),
      supplements: [
        nodeID: RoutingMetalNodeSupplement(
          isRunning: false,
          isCapturing: false,
          visualizerSignal: signal
        )
      ]
    )

    #expect(scene.nodes.first?.supplement.visualizerSignal == signal)
  }

  @Test @MainActor
  func applicationNodeRetainsTheOriginalStatusSymbolAndCopy() throws {
    let model = RoutingWorkspaceModel()
    _ = model.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))
    let scene = RoutingMetalScene(
      content: try #require(model.canvasContent),
      supplements: [:]
    )
    let node = try #require(scene.nodes.first)

    #expect(node.applicationStatusSymbolName == "cursorarrow.click")
    #expect(node.applicationStatusText == "Select this node to configure")
    #expect(!node.hasApplicationSelection)
    #expect(node.applicationURL == nil)
  }
}
