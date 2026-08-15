import CoreGraphics
import FlowingDayGraphCanvas
import FlowingDayGraphComposition
import FlowingDayGraphCore
import Foundation

struct RoutingApplicationSelection: Equatable, Hashable, Identifiable, Sendable {
  let id: String
  let applicationURL: URL
  let bundleIdentifier: String?
  let displayName: String

  init(
    stableID: String,
    applicationURL: URL,
    bundleIdentifier: String?,
    displayName: String
  ) {
    precondition(!stableID.isEmpty)
    precondition(!displayName.isEmpty)
    id = stableID
    self.applicationURL = applicationURL
    self.bundleIdentifier = bundleIdentifier
    self.displayName = displayName
  }
}

enum RoutingNodeValue: Equatable, Sendable {
  case applicationAudio(
    selection: RoutingApplicationSelection?,
    channelPresentation: RoutingChannelPresentation
  )
  case visualizer(configuration: RoutingVisualizerConfiguration)

  var applicationSelection: RoutingApplicationSelection? {
    switch self {
    case .applicationAudio(let selection, _):
      return selection
    case .visualizer:
      return nil
    }
  }

  var title: String {
    switch self {
    case .applicationAudio:
      return "Application Audio"
    case .visualizer:
      return "Visualizer"
    }
  }
}

enum RoutingChannelPresentation: Equatable, Hashable, Sendable {
  case aggregate
  case separate(channelCount: Int)

  var channelCount: Int? {
    guard case .separate(let channelCount) = self else { return nil }
    return channelCount
  }
}

enum RoutingVisualizerMode: String, CaseIterable, Equatable, Hashable, Sendable {
  case mixed
  case separate
}

struct RoutingVisualizerConfiguration: Equatable, Sendable {
  var mode: RoutingVisualizerMode
  var availableChannelCount: Int
  var selectedChannels: Set<Int>

  static let initial = RoutingVisualizerConfiguration(
    mode: .mixed,
    availableChannelCount: 2,
    selectedChannels: [0, 1]
  )

  var normalizedSelectedChannels: [Int] {
    selectedChannels
      .filter { (0..<availableChannelCount).contains($0) }
      .sorted()
  }
}

struct RoutingWorkspaceNode: Equatable, Identifiable, Sendable {
  let id: UUID
  var value: RoutingNodeValue
  var frame: CGRect
}

struct RoutingWorkspacePortAddress: Equatable, Hashable, Sendable {
  let nodeID: UUID
  let portID: RoutingGraphPortID
}

struct RoutingWorkspaceEdge: Equatable, Identifiable, Sendable {
  let id: UUID
  let source: RoutingWorkspacePortAddress
  let target: RoutingWorkspacePortAddress
}

enum RoutingAudioPortDirection: Equatable, Hashable, Sendable {
  case input
  case output
}

enum RoutingAudioPortChannel: Equatable, Hashable, Sendable {
  case all
  case channel(Int)
}

struct RoutingGraphPortID: Equatable, Hashable, Sendable {
  let direction: RoutingAudioPortDirection
  let channel: RoutingAudioPortChannel
}

struct RoutingGraphPortValue: Equatable, Sendable {
  let direction: RoutingAudioPortDirection
  let channel: RoutingAudioPortChannel
  let ordinal: Int
  let total: Int

  var label: String {
    switch channel {
    case .all:
      return direction == .input ? "All channels input" : "All channels output"
    case .channel(let index):
      return "Channel \(index + 1) \(direction == .input ? "input" : "output")"
    }
  }
}

enum RoutingGraphEdgeValue: Equatable, Sendable {
  case audio
}

enum RoutingGraphSchema: FlowingGraphSchema {
  typealias NodeID = UUID
  typealias NodeValue = RoutingNodeValue
  typealias PortID = RoutingGraphPortID
  typealias PortValue = RoutingGraphPortValue
  typealias EdgeID = UUID
  typealias EdgeValue = RoutingGraphEdgeValue
}

enum RoutingCanvasSchema: FlowingGraphCanvasSchema {
  typealias DocumentID = String
  typealias GraphID = String
  typealias EntryPointID = String
  typealias LinkID = String
  typealias LinkValue = String
  typealias GraphSchema = RoutingGraphSchema
}

typealias RoutingCanvasContent = FlowingGraphCanvasContent<RoutingCanvasSchema>
typealias RoutingCanvasElementID = FlowingGraphCompositionElementID<RoutingCanvasSchema>
typealias RoutingCanvasAccessibilitySnapshot =
  FlowingGraphCanvasAccessibilitySnapshot<RoutingCanvasElementID>

enum RoutingCanvasMetrics {
  static let baseNodeSize = CGSize(width: 252, height: 128)
  static let contentBounds = CGRect(
    x: -100_000,
    y: -100_000,
    width: 200_000,
    height: 200_000
  )

  static func nodeSize(for value: RoutingNodeValue) -> CGSize {
    let portCount: Int
    switch value {
    case .applicationAudio(_, .aggregate):
      portCount = 1
    case .applicationAudio(_, .separate(let channelCount)):
      portCount = channelCount
    case .visualizer(let configuration):
      portCount =
        configuration.mode == .mixed ? 1 : configuration.normalizedSelectedChannels.count
    }
    return CGSize(
      width: baseNodeSize.width,
      height: max(baseNodeSize.height, CGFloat(portCount + 1) * 18)
    )
  }
}

enum RoutingGraphPorts {
  static func values(for node: RoutingWorkspaceNode) -> [RoutingGraphPortValue] {
    values(for: node.value)
  }

  static func values(for value: RoutingNodeValue) -> [RoutingGraphPortValue] {
    let identities: [(RoutingAudioPortDirection, RoutingAudioPortChannel)]
    switch value {
    case .applicationAudio(_, let channelPresentation):
      identities = outputIdentities(for: channelPresentation)
    case .visualizer(let configuration):
      switch configuration.mode {
      case .mixed:
        identities = [(.input, .all)]
      case .separate:
        identities = configuration.normalizedSelectedChannels.map { (.input, .channel($0)) }
      }
    }
    return identities.enumerated().map { ordinal, identity in
      RoutingGraphPortValue(
        direction: identity.0,
        channel: identity.1,
        ordinal: ordinal,
        total: identities.count
      )
    }
  }

  static func portID(for value: RoutingGraphPortValue) -> RoutingGraphPortID {
    RoutingGraphPortID(
      direction: value.direction,
      channel: value.channel
    )
  }

  private static func outputIdentities(
    for presentation: RoutingChannelPresentation
  ) -> [(RoutingAudioPortDirection, RoutingAudioPortChannel)] {
    switch presentation {
    case .aggregate:
      return [(.output, .all)]
    case .separate(let channelCount):
      return (0..<channelCount).map { (.output, .channel($0)) }
    }
  }
}

enum RoutingNodeInsertion {
  static func point(
    in visibleWorldRect: CGRect,
    existingNodeCount: Int
  ) -> CGPoint {
    precondition(existingNodeCount >= 0)
    let center =
      visibleWorldRect.isEmpty
      ? CGPoint.zero
      : CGPoint(x: visibleWorldRect.midX, y: visibleWorldRect.midY)
    let columnOffsets: [CGFloat] = [0, -280, 280]
    let column = existingNodeCount % columnOffsets.count
    let row = existingNodeCount / columnOffsets.count
    return CGPoint(
      x: center.x + columnOffsets[column],
      y: center.y + CGFloat(row) * 156
    )
  }
}
