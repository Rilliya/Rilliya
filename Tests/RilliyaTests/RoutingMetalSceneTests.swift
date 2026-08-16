import CoreGraphics
import FlowingDayGraphCanvas
import FlowingDayGraphLayout
import Foundation
import Testing

@testable import Rilliya

@Suite("Routing Metal scene")
struct RoutingMetalSceneTests {
  @Test @MainActor
  func topologyCacheReusesLayoutAcrossRealtimeSupplementUpdates() throws {
    let model = RoutingWorkspaceModel()
    let nodeID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))
    let content = try #require(model.canvasContent)
    let cache = RoutingMetalSceneTopologyCache()

    let firstTopology = cache.topology(for: content)
    _ = RoutingMetalScene(topology: firstTopology, supplements: [:])
    let secondTopology = cache.topology(for: content)
    let updatedScene = RoutingMetalScene(
      topology: secondTopology,
      supplements: [
        nodeID: RoutingMetalNodeSupplement(
          isRunning: true,
          isCapturing: true,
          captureConsumerCount: 1,
          visualizerSignal: nil
        )
      ]
    )

    #expect(cache.topologyBuildCount == 1)
    #expect(updatedScene.nodes.first?.status == "Capturing live audio")

    _ = model.addVisualizerNode(centeredAt: CGPoint(x: 500, y: 100))
    _ = cache.topology(for: try #require(model.canvasContent))
    #expect(cache.topologyBuildCount == 2)
  }

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
  func marqueeFindsEveryIntersectingNode() throws {
    let model = RoutingWorkspaceModel()
    let firstID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))
    let secondID = model.addVisualizerNode(centeredAt: CGPoint(x: 500, y: 100))
    _ = model.addPeakLevelNode(centeredAt: CGPoint(x: 1_000, y: 1_000))
    let scene = RoutingMetalScene(
      content: try #require(model.canvasContent),
      supplements: [:]
    )

    let matches = scene.nodeIDs(
      intersecting: CGRect(x: -40, y: -40, width: 700, height: 280)
    )

    let firstElementID = try #require(model.elementID(for: firstID))
    let secondElementID = try #require(model.elementID(for: secondID))
    #expect(matches == [firstElementID, secondElementID])
  }

  @Test @MainActor
  func selectAllIncludesEveryNodeAndConnectionButNotPorts() throws {
    let model = RoutingWorkspaceModel()
    let sourceID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))
    let targetID = model.addVisualizerNode(centeredAt: CGPoint(x: 500, y: 100))
    let content = try #require(model.canvasContent)
    let source = try #require(
      content.presentation.ports.first {
        guard case .port(let key) = $0.address.elementID else { return false }
        return key.nodeID == sourceID && $0.value.audioChannel == .all
      }
    )
    let target = try #require(
      content.presentation.ports.first {
        guard case .port(let key) = $0.address.elementID else { return false }
        return key.nodeID == targetID && $0.value.audioChannel == .all
      }
    )
    model.send(
      .connectionCompleted(
        FlowingGraphCanvasConnectionCompletionIntent(
          operation: .create(sourcePortID: source.id, targetPortID: target.id),
          basePresentationSnapshotID: content.presentation.snapshotID,
          baseLayoutInputID: content.id
        )
      )
    )
    let scene = RoutingMetalScene(
      content: try #require(model.canvasContent),
      supplements: [:]
    )

    #expect(scene.selectableElementIDs == Set(scene.nodes.map(\.id) + scene.edges.map(\.id)))
    #expect(
      scene.selectableElementIDs.isDisjoint(with: Set(scene.nodes.flatMap(\.ports).map(\.id))))
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
  func aggregateAudioSourceCanPreviewAutomaticSeparationIntoALane() throws {
    let model = RoutingWorkspaceModel()
    let sourceID = model.addApplicationAudioNode(centeredAt: CGPoint(x: 100, y: 100))
    let targetID = model.addAudioMixerNode(centeredAt: CGPoint(x: 500, y: 100))
    let scene = RoutingMetalScene(
      content: try #require(model.canvasContent),
      supplements: [:]
    )
    let source = try #require(
      scene.nodes.first { $0.workspaceID == sourceID }?.ports.first {
        $0.value.audioChannel == .all
      }
    )
    let target = try #require(
      scene.nodes.first { $0.workspaceID == targetID }?.ports.first {
        $0.value.direction == .input && $0.value.audioChannel == .channel(1)
      }
    )

    #expect(scene.validatesConnection(from: source, to: target))
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
    #expect(node.accentID == .fern)
    #expect(node.drawsIconPlate)
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
    #expect(node.miniMapStyleIndex == RoutingAccentID.pollen.paletteIndex)
    #expect(scene.miniMapStyleIndex(for: node.id) == RoutingAccentID.pollen.paletteIndex)
  }

  @Test @MainActor
  func signalGeneratorCarriesItsConfigurationIntoTheGpuScene() throws {
    let model = RoutingWorkspaceModel()
    let nodeID = model.addSignalGeneratorNode(centeredAt: CGPoint(x: 100, y: 100))
    let configuration = RoutingSignalGeneratorConfiguration(
      waveform: .triangle,
      frequency: 880,
      amplitude: 0.5
    )
    model.configureSignalGenerator(configuration, for: nodeID)
    let scene = RoutingMetalScene(
      content: try #require(model.canvasContent),
      supplements: [:]
    )
    let node = try #require(scene.nodes.first)

    #expect(node.title == "Signal Generator")
    #expect(node.subtitle == "Triangle · 880 Hz")
    #expect(node.status == "Ready to route")
    #expect(node.symbolName == "waveform.path")
    #expect(node.miniMapStyleIndex == RoutingAccentID.poppy.paletteIndex)
    #expect(node.ports.count == 1)
    #expect(node.ports.first?.value.audioChannel == .channel(0))
  }

  @Test @MainActor
  func delayCarriesItsConfigurationIntoTheGpuScene() throws {
    let model = RoutingWorkspaceModel()
    let nodeID = model.addDelayNode(centeredAt: CGPoint(x: 100, y: 100))
    let configuration = RoutingDelayConfiguration(
      delaySeconds: 0.75,
      feedback: 0.4,
      dryWetMix: 0.6
    )
    model.configureDelay(configuration, for: nodeID)
    let scene = RoutingMetalScene(
      content: try #require(model.canvasContent),
      supplements: [:]
    )
    let node = try #require(scene.nodes.first)

    #expect(node.title == "Delay")
    #expect(node.subtitle == "750 ms")
    #expect(node.status == "Ready to route")
    #expect(node.symbolName == "clock.arrow.trianglehead.counterclockwise.rotate.90")
    #expect(node.miniMapStyleIndex == RoutingAccentID.wisteria.paletteIndex)
    #expect(node.ports.count == 2)
  }

  @Test @MainActor
  func noiseGateCarriesItsConfigurationIntoTheGpuScene() throws {
    let model = RoutingWorkspaceModel()
    let nodeID = model.addNoiseGateNode(centeredAt: CGPoint(x: 100, y: 100))
    var configuration = RoutingNoiseGateConfiguration.initial
    configuration.thresholdDecibels = -36
    configuration.reductionDecibels = 48
    model.configureNoiseGate(configuration, for: nodeID)
    let scene = RoutingMetalScene(
      content: try #require(model.canvasContent),
      supplements: [:]
    )
    let node = try #require(scene.nodes.first)

    #expect(node.title == "Noise Gate")
    #expect(node.subtitle == "-36 dBFS threshold")
    #expect(node.status == "Ready to route")
    #expect(node.symbolName == "waveform.badge.minus")
    #expect(node.miniMapStyleIndex == RoutingAccentID.lagoon.paletteIndex)
    #expect(node.ports.count == 2)
  }

  @Test @MainActor
  func compressorCarriesItsConfigurationIntoTheGpuScene() throws {
    let model = RoutingWorkspaceModel()
    let nodeID = model.addCompressorNode(centeredAt: CGPoint(x: 100, y: 100))
    let configuration = RoutingCompressorConfiguration(
      thresholdDecibels: -24,
      ratio: 6,
      kneeDecibels: 8,
      attackSeconds: 0.02,
      releaseSeconds: 0.25,
      makeupGainDecibels: 3
    )
    model.configureCompressor(configuration, for: nodeID)
    let scene = RoutingMetalScene(
      content: try #require(model.canvasContent),
      supplements: [:]
    )
    let node = try #require(scene.nodes.first)

    #expect(node.title == "Compressor")
    #expect(node.subtitle == "-24 dBFS · 6.0:1")
    #expect(node.status == "Ready to route")
    #expect(node.symbolName == "arrow.down.right.and.arrow.up.left")
    #expect(node.miniMapStyleIndex == RoutingAccentID.bloom.paletteIndex)
    #expect(node.ports.count == 2)
  }

  @Test @MainActor
  func sceneUsesTheResolvedPerNodeAccent() throws {
    let model = RoutingWorkspaceModel()
    let nodeID = model.addVisualizerNode(centeredAt: CGPoint(x: 100, y: 100))
    let scene = RoutingMetalScene(
      content: try #require(model.canvasContent),
      supplements: [:],
      accentIDs: [nodeID: .fuchsia]
    )
    let node = try #require(scene.nodes.first)

    #expect(node.accentID == .fuchsia)
    #expect(node.miniMapStyleIndex == RoutingAccentID.fuchsia.paletteIndex)
    #expect(scene.miniMapStyleIndex(for: node.id) == RoutingAccentID.fuchsia.paletteIndex)
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

  @Test @MainActor
  func systemOutputCarriesConfigurationAndCaptureStatusIntoTheGpuScene() throws {
    let model = RoutingWorkspaceModel()
    let nodeID = model.addSystemOutputNode(centeredAt: CGPoint(x: 100, y: 100))

    var scene = RoutingMetalScene(content: try #require(model.canvasContent), supplements: [:])
    var node = try #require(scene.nodes.first)
    #expect(node.title == "System Output")
    #expect(node.subtitle == "Choose an output source")
    #expect(node.status == "Select to configure")
    #expect(node.symbolName == "speaker.wave.2.circle")
    #expect(node.miniMapStyleIndex == RoutingAccentID.ripple.paletteIndex)
    #expect(node.ports.allSatisfy { $0.value.direction == .output })

    model.selectSystemOutput(.systemDefault, for: nodeID)
    scene = RoutingMetalScene(
      content: try #require(model.canvasContent),
      supplements: [
        nodeID: RoutingMetalNodeSupplement(
          isRunning: true,
          isCapturing: true,
          captureConsumerCount: 2,
          visualizerSignal: nil,
          outputCaptureState: .starting
        )
      ]
    )
    node = try #require(scene.nodes.first)
    #expect(node.subtitle == "System Default Output")
    #expect(node.status == "Preparing system output capture")
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
