import CoreGraphics
import Foundation
import Testing

@testable import Rilliya

@Suite("Routing visualizer layout")
struct RoutingVisualizerLayoutTests {
  @Test
  func legacyVisualizerConfigurationDefaultsToNoMixedOutput() throws {
    let encoded = try JSONEncoder().encode(RoutingVisualizerConfiguration.initial)
    var object = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["includesMixedOutput"] = nil
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(
      RoutingVisualizerConfiguration.self,
      from: legacyData
    )

    #expect(decoded.includesMixedOutput == false)
  }

  @Test
  func presetIntentSurvivesTemporaryRuntimeChannelLoss() {
    var configuration = RoutingVisualizerConfiguration(
      mode: .separate,
      availableChannelCount: 2,
      channelSelection: .preset(.surround51)
    )

    #expect(configuration.normalizedSelectedChannels == [0, 1])
    #expect(configuration.channelSelection == .preset(.surround51))

    configuration.availableChannelCount = 6

    #expect(configuration.normalizedSelectedChannels == Array(0..<6))
    #expect(configuration.channelSelection == .preset(.surround51))
  }

  @Test
  func mixedModeKeepsTheCompactNodeHeight() {
    let configuration = RoutingVisualizerConfiguration.initial

    #expect(
      RoutingVisualizerLayout.nodeHeight(for: configuration)
        == RoutingCanvasMetrics.baseNodeSize.height
    )
    #expect(RoutingVisualizerLayout.laneCount(for: configuration) == 1)
  }

  @Test
  func selectedChannelsCreateIndependentLanesWithoutUsingTheAvailableCount() {
    let configuration = RoutingVisualizerConfiguration(
      mode: .separate,
      availableChannelCount: 64,
      selectedChannels: [0, 47]
    )
    let nodeFrame = CGRect(
      origin: .zero,
      size: CGSize(
        width: RoutingCanvasMetrics.baseNodeSize.width,
        height: RoutingVisualizerLayout.nodeHeight(for: configuration)
      )
    )
    let lanes = RoutingVisualizerLayout.laneFrames(
      in: nodeFrame,
      configuration: configuration
    )

    #expect(lanes.count == 2)
    #expect(lanes[0].height == RoutingVisualizerLayout.separateLaneHeight)
    #expect(lanes[1].minY - lanes[0].maxY == RoutingVisualizerLayout.laneSpacing)
    #expect(nodeFrame.maxY - lanes[1].maxY == RoutingVisualizerLayout.bottomInset)
  }

  @Test @MainActor
  func separateLaneSelectionIsBoundedForLargeChannelSources() throws {
    let model = RoutingWorkspaceModel()
    let nodeID = model.addVisualizerNode(centeredAt: .zero)

    model.configureVisualizer(
      RoutingVisualizerConfiguration(
        mode: .separate,
        availableChannelCount: 64,
        selectedChannels: Set(0..<48)
      ),
      for: nodeID
    )

    let node = try #require(model.node(id: nodeID))
    guard case .visualizer(let configuration) = node.value else {
      Issue.record("Expected a visualizer node")
      return
    }
    #expect(
      configuration.normalizedSelectedChannels
        == Array(0..<RoutingVisualizerConfiguration.maximumSeparateLaneCount)
    )
    #expect(
      node.frame.height
        == RoutingVisualizerLayout.nodeHeight(for: configuration)
    )
    #expect(node.frame.height == RoutingVisualizerLayout.maximumNodeHeight)
  }

  @Test @MainActor
  func separateInputPortsAlignWithTheirWaveformLanes() throws {
    let model = RoutingWorkspaceModel()
    let nodeID = model.addVisualizerNode(centeredAt: CGPoint(x: 200, y: 200))
    model.configureVisualizer(
      RoutingVisualizerConfiguration(
        mode: .separate,
        availableChannelCount: 64,
        selectedChannels: [0, 47]
      ),
      for: nodeID
    )
    let node = try #require(model.node(id: nodeID))
    guard case .visualizer(let configuration) = node.value else {
      Issue.record("Expected a visualizer node")
      return
    }
    let scene = RoutingMetalScene(
      content: try #require(model.canvasContent),
      supplements: [:]
    )
    let ports = try #require(
      scene.nodes.first { $0.workspaceID == nodeID }
    ).ports
    let laneCenters = RoutingVisualizerLayout.laneFrames(
      in: node.frame,
      configuration: configuration
    ).map(\.midY)

    #expect(ports.map(\.position.y) == laneCenters + laneCenters)
    #expect(
      ports.filter { $0.value.direction == .input }
        .allSatisfy { $0.position.x == node.frame.minX }
    )
    #expect(
      ports.filter { $0.value.direction == .output }
        .allSatisfy { $0.position.x == node.frame.maxX }
    )
  }

  @Test
  func quietWaveformsReceiveTheSameBoundedDisplayGainAsTheSpike() {
    let normalized = RoutingWaveformDisplayTransform.normalizedSamples([
      -0.1, 0, 0.1,
    ])

    #expect(abs(normalized[0] + 0.9) < 0.000_1)
    #expect(normalized[1] == 0)
    #expect(abs(normalized[2] - 0.9) < 0.000_1)
  }

  @Test
  func displayGainIsCappedAndNonfiniteSamplesBecomeSilence() {
    let normalized = RoutingWaveformDisplayTransform.normalizedSamples([
      -0.01, .nan, .infinity, 0.01,
    ])

    #expect(abs(normalized[0] + 0.2) < 0.000_1)
    #expect(normalized[1] == 0)
    #expect(normalized[2] == 0)
    #expect(abs(normalized[3] - 0.2) < 0.000_1)
  }

  @Test
  func separateSignalRetainsTheSelectedChannelIdentities() {
    let signal = RoutingVisualizerSignal(
      lanes: [
        RoutingVisualizerLaneSignal(id: .channel(0), samples: []),
        RoutingVisualizerLaneSignal(id: .channel(47), samples: [0.2, -0.2]),
      ]
    )

    #expect(signal.lanes.map(\.id) == [.channel(0), .channel(47)])
  }
}
