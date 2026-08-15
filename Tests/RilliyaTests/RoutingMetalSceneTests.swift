import CoreGraphics
import FlowingDayGraphLayout
import Foundation
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
  func renderElementsCullOffscreenNodesAndKeepSelectedNodesLast() throws {
    let model = RoutingWorkspaceModel()
    let firstID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))
    let secondID = model.addVisualizerNode(centeredAt: CGPoint(x: 500, y: 100))
    _ = model.addPeakLevelNode(centeredAt: CGPoint(x: 10_000, y: 10_000))
    let scene = RoutingMetalScene(
      content: try #require(model.canvasContent),
      supplements: [:]
    )
    let firstElementID = try #require(model.elementID(for: firstID))
    let visible = scene.renderElements(
      intersecting: CGRect(x: -100, y: -100, width: 900, height: 500),
      selection: [firstElementID]
    )

    #expect(visible.nodes.map(\.workspaceID) == [secondID, firstID])
    #expect(visible.edges.isEmpty)
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
        $0.value.audioChannel == .channel(0)
      }
    )
    let matchingTarget = try #require(
      scene.nodes.first { $0.workspaceID == targetID }?.ports.first {
        $0.value.audioChannel == .channel(0)
      }
    )
    let mismatchedTarget = try #require(
      scene.nodes.first { $0.workspaceID == targetID }?.ports.first {
        $0.value.audioChannel == .channel(1)
      }
    )

    #expect(scene.validatesConnection(from: source, to: matchingTarget))
    #expect(scene.validatesConnection(from: source, to: mismatchedTarget))
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
          captureConsumerCount: 0,
          visualizerSignal: signal
        )
      ]
    )

    #expect(scene.nodes.first?.supplement.visualizerSignal == signal)
  }

  @Test
  func visualizerWithoutInputUsesTextOnlyWaitingPresentation() {
    let presentation = RoutingMetalVisualizerPresentation(signal: nil)

    #expect(presentation == .waiting)
    #expect(RoutingMetalVisualizerPresentation.waitingMessage == "Waiting for audio input")
  }

  @Test
  func visualizerWithInputUsesWaveformPresentation() {
    let waveforms: [[Float]] = [[0, 0.25, -0.5, 0]]
    let signal = RoutingVisualizerSignal(waveforms: waveforms)

    let presentation = RoutingMetalVisualizerPresentation(
      signal: signal
    )

    #expect(presentation == .waveform(signal.lanes))
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

  @Test @MainActor
  func configuredApplicationOmitsTheRedundantStatusRow() throws {
    let model = RoutingWorkspaceModel()
    let nodeID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))
    model.selectApplication(
      RoutingApplicationSelection(
        stableID: "com.example.player",
        applicationURL: URL(fileURLWithPath: "/Applications/Player.app"),
        bundleIdentifier: "com.example.player",
        displayName: "Player"
      ),
      for: nodeID
    )
    let scene = RoutingMetalScene(
      content: try #require(model.canvasContent),
      supplements: [:]
    )

    #expect(scene.nodes.first?.applicationStatusText == nil)
    #expect(scene.nodes.first?.applicationStatusSymbolName == nil)
    #expect(scene.nodes.first?.hasApplicationSelection == true)
  }

  @Test @MainActor
  func peakLevelSignalIsRetainedForGpuRendering() throws {
    let model = RoutingWorkspaceModel()
    let nodeID = model.addPeakLevelNode(centeredAt: CGPoint(x: 100, y: 100))
    let signal = RoutingPeakLevelSignal(linearPeak: 0.75, isClipping: false)
    let scene = RoutingMetalScene(
      content: try #require(model.canvasContent),
      supplements: [
        nodeID: RoutingMetalNodeSupplement(
          isRunning: false,
          isCapturing: false,
          captureConsumerCount: 0,
          visualizerSignal: nil,
          peakLevelSignal: signal
        )
      ]
    )

    #expect(scene.nodes.first?.supplement.peakLevelSignal == signal)
    #expect(scene.nodes.first?.title == "Peak Level")
    #expect(scene.nodes.first?.subtitle == "Linear full-scale peak")
    let node = try #require(scene.nodes.first)
    #expect(node.miniMapStyleIndex == 5)
    #expect(scene.miniMapStyleIndex(for: node.id) == 5)
  }

  @Test @MainActor
  func sharedApplicationCaptureIsVisibleInTheGpuNodeStatus() throws {
    let model = RoutingWorkspaceModel()
    let nodeID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))
    let scene = RoutingMetalScene(
      content: try #require(model.canvasContent),
      supplements: [
        nodeID: RoutingMetalNodeSupplement(
          isRunning: true,
          isCapturing: true,
          captureConsumerCount: 3,
          visualizerSignal: nil
        )
      ]
    )

    #expect(scene.nodes.first?.status == "Shared capture · 3 nodes")
  }

  @Test
  func existingRouteFollowsTheSourceDuringAnInteractiveDrag() throws {
    let route = FlowingGraphEdgeRoute(
      start: CGPoint(x: 0, y: 10),
      segments: [
        .cubic(
          control1: CGPoint(x: 40, y: 10),
          control2: CGPoint(x: 160, y: 90),
          end: CGPoint(x: 200, y: 90)
        )
      ]
    )

    let projected = RoutingMetalEdgeRouteProjection.route(
      route,
      sourceMoves: true,
      targetMoves: false,
      translation: CGSize(width: 25, height: -5)
    )

    #expect(projected.start == CGPoint(x: 25, y: 5))
    guard
      case .cubic(let control1, let control2, let end) = try #require(
        projected.segments.first
      )
    else {
      Issue.record("Expected a cubic route")
      return
    }
    #expect(control1 == CGPoint(x: 65, y: 5))
    #expect(control2 == CGPoint(x: 160, y: 90))
    #expect(end == CGPoint(x: 200, y: 90))
  }

  @Test
  func existingRouteFollowsTheTargetDuringAnInteractiveDrag() throws {
    let route = FlowingGraphEdgeRoute(
      start: CGPoint(x: 0, y: 10),
      segments: [
        .cubic(
          control1: CGPoint(x: 40, y: 10),
          control2: CGPoint(x: 160, y: 90),
          end: CGPoint(x: 200, y: 90)
        )
      ]
    )

    let projected = RoutingMetalEdgeRouteProjection.route(
      route,
      sourceMoves: false,
      targetMoves: true,
      translation: CGSize(width: -15, height: 20)
    )

    #expect(projected.start == CGPoint(x: 0, y: 10))
    guard
      case .cubic(let control1, let control2, let end) = try #require(
        projected.segments.first
      )
    else {
      Issue.record("Expected a cubic route")
      return
    }
    #expect(control1 == CGPoint(x: 40, y: 10))
    #expect(control2 == CGPoint(x: 145, y: 110))
    #expect(end == CGPoint(x: 185, y: 110))
  }
}
