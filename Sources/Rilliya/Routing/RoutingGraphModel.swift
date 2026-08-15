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

extension RoutingNodeValue {
  var channelPresentation: RoutingChannelPresentation? {
    guard case .applicationAudio(_, let presentation) = self else { return nil }
    return presentation
  }
}

enum RoutingVisualizerMode: String, CaseIterable, Equatable, Hashable, Sendable {
  case mixed
  case separate
}

struct RoutingVisualizerConfiguration: Equatable, Sendable {
  static let maximumAvailableChannelCount = 256
  static let maximumSeparateLaneCount = 8

  var mode: RoutingVisualizerMode
  var availableChannelCount: Int
  var selectedChannels: Set<Int>

  static let initial = RoutingVisualizerConfiguration(
    mode: .mixed,
    availableChannelCount: 2,
    selectedChannels: [0, 1]
  )

  var normalizedSelectedChannels: [Int] {
    Array(
      selectedChannels
        .filter { (0..<availableChannelCount).contains($0) }
        .sorted()
        .prefix(Self.maximumSeparateLaneCount)
    )
  }

  var canSelectAnotherChannel: Bool {
    normalizedSelectedChannels.count < Self.maximumSeparateLaneCount
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

enum RoutingPortDirection: Equatable, Hashable, Sendable {
  case input
  case output
}

enum RoutingAudioPortChannel: Equatable, Hashable, Sendable {
  case all
  case channel(Int)
}

struct RoutingGraphPortID: Equatable, Hashable, Sendable {
  let direction: RoutingPortDirection
  let key: RoutingPortKey

  init(direction: RoutingPortDirection, key: RoutingPortKey) {
    self.direction = direction
    self.key = key
  }

  init(direction: RoutingPortDirection, channel: RoutingAudioPortChannel) {
    self.direction = direction
    key = .audio(channel)
  }

  init(direction: RoutingPortDirection, name: String) {
    precondition(!name.isEmpty)
    self.direction = direction
    key = .named(name)
  }

  var audioChannel: RoutingAudioPortChannel? {
    guard case .audio(let channel) = key else { return nil }
    return channel
  }
}

enum RoutingPortKey: Equatable, Hashable, Sendable {
  case audio(RoutingAudioPortChannel)
  case named(String)
}

enum RoutingSignalType: Equatable, Hashable, Sendable {
  case audio
  case integer
  case floatingPoint
  case confidence
  case boolean
  case text
  case label(domain: String?)
  case structure(schema: String)
}

enum RoutingPortConnectionPolicy: Equatable, Hashable, Sendable {
  case fanOut
  case singleInput
  case mixingInput
}

struct RoutingGraphPortValue: Equatable, Sendable {
  let direction: RoutingPortDirection
  let key: RoutingPortKey
  let signalType: RoutingSignalType
  let connectionPolicy: RoutingPortConnectionPolicy
  let name: String
  let ordinal: Int
  let total: Int

  init(
    direction: RoutingPortDirection,
    channel: RoutingAudioPortChannel,
    ordinal: Int,
    total: Int
  ) {
    self.direction = direction
    key = .audio(channel)
    signalType = .audio
    connectionPolicy = direction == .input ? .mixingInput : .fanOut
    name =
      switch channel {
      case .all:
        "All channels"
      case .channel(let index):
        "Channel \(index + 1)"
      }
    self.ordinal = ordinal
    self.total = total
  }

  init(
    direction: RoutingPortDirection,
    id: String,
    name: String,
    signalType: RoutingSignalType,
    connectionPolicy: RoutingPortConnectionPolicy,
    ordinal: Int,
    total: Int
  ) {
    precondition(!id.isEmpty)
    precondition(!name.isEmpty)
    self.direction = direction
    key = .named(id)
    self.signalType = signalType
    self.connectionPolicy = connectionPolicy
    self.name = name
    self.ordinal = ordinal
    self.total = total
  }

  var id: RoutingGraphPortID {
    RoutingGraphPortID(direction: direction, key: key)
  }

  var audioChannel: RoutingAudioPortChannel? {
    guard case .audio(let channel) = key else { return nil }
    return channel
  }

  var label: String {
    "\(name) \(direction == .input ? "input" : "output")"
  }

  var shortLabel: String {
    switch key {
    case .audio(.all):
      return "All"
    case .audio(.channel(let index)):
      return "Ch \(index + 1)"
    case .named:
      switch signalType {
      case .audio:
        return "Audio"
      case .integer:
        return "Int"
      case .floatingPoint:
        return "Float"
      case .confidence:
        return "Confidence"
      case .boolean:
        return "Bool"
      case .text:
        return "Text"
      case .label:
        return "Label"
      case .structure:
        return "Data"
      }
    }
  }
}

struct RoutingGraphEdgeValue: Equatable, Sendable {
  let signalType: RoutingSignalType
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
      return CGSize(
        width: baseNodeSize.width,
        height: RoutingVisualizerLayout.nodeHeight(for: configuration)
      )
    }
    return CGSize(
      width: baseNodeSize.width,
      height: max(baseNodeSize.height, CGFloat(portCount + 1) * 18)
    )
  }
}

enum RoutingVisualizerLayout {
  static let waveformTop: CGFloat = 70
  static let singleLaneHeight: CGFloat = 42
  static let separateLaneHeight: CGFloat = 32
  static let laneSpacing: CGFloat = 6
  static let horizontalInset: CGFloat = 14
  static let bottomInset: CGFloat = 14
  static let maximumNodeHeight =
    waveformTop
    + CGFloat(RoutingVisualizerConfiguration.maximumSeparateLaneCount) * separateLaneHeight
    + CGFloat(RoutingVisualizerConfiguration.maximumSeparateLaneCount - 1) * laneSpacing
    + bottomInset

  static func laneCount(for configuration: RoutingVisualizerConfiguration) -> Int {
    configuration.mode == .mixed
      ? 1
      : max(configuration.normalizedSelectedChannels.count, 1)
  }

  static func laneHeight(for configuration: RoutingVisualizerConfiguration) -> CGFloat {
    configuration.mode == .mixed ? singleLaneHeight : separateLaneHeight
  }

  static func waveformContentHeight(
    for configuration: RoutingVisualizerConfiguration
  ) -> CGFloat {
    let count = laneCount(for: configuration)
    return CGFloat(count) * laneHeight(for: configuration)
      + CGFloat(max(count - 1, 0)) * laneSpacing
  }

  static func nodeHeight(for configuration: RoutingVisualizerConfiguration) -> CGFloat {
    min(
      maximumNodeHeight,
      max(
        RoutingCanvasMetrics.baseNodeSize.height,
        waveformTop + waveformContentHeight(for: configuration) + bottomInset
      )
    )
  }

  static func laneFrames(
    in nodeFrame: CGRect,
    configuration: RoutingVisualizerConfiguration
  ) -> [CGRect] {
    let height = laneHeight(for: configuration)
    return (0..<laneCount(for: configuration)).map { index in
      CGRect(
        x: nodeFrame.minX + horizontalInset,
        y: nodeFrame.minY + waveformTop + CGFloat(index) * (height + laneSpacing),
        width: nodeFrame.width - horizontalInset * 2,
        height: height
      )
    }
  }

  static func waitingFrame(
    in nodeFrame: CGRect,
    configuration: RoutingVisualizerConfiguration
  ) -> CGRect {
    CGRect(
      x: nodeFrame.minX + horizontalInset,
      y: nodeFrame.minY + waveformTop,
      width: nodeFrame.width - horizontalInset * 2,
      height: waveformContentHeight(for: configuration)
    )
  }
}

enum RoutingGraphPorts {
  static func values(for node: RoutingWorkspaceNode) -> [RoutingGraphPortValue] {
    values(for: node.value)
  }

  static func values(for value: RoutingNodeValue) -> [RoutingGraphPortValue] {
    let identities: [(RoutingPortDirection, RoutingAudioPortChannel)]
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
    value.id
  }

  private static func outputIdentities(
    for presentation: RoutingChannelPresentation
  ) -> [(RoutingPortDirection, RoutingAudioPortChannel)] {
    switch presentation {
    case .aggregate:
      return [(.output, .all)]
    case .separate(let channelCount):
      return (0..<channelCount).map { (.output, .channel($0)) }
    }
  }
}

enum RoutingPortCompatibility {
  static func incompatibilityReason(
    source: RoutingGraphPortValue,
    target: RoutingGraphPortValue
  ) -> String? {
    guard source.direction == .output, target.direction == .input else {
      return "Connect an output to an input"
    }
    guard signalTypesAreCompatible(source: source.signalType, target: target.signalType) else {
      return "Connect ports carrying the same data type"
    }
    guard source.signalType == .audio else { return nil }
    guard let sourceChannel = source.audioChannel,
      let targetChannel = target.audioChannel
    else {
      return "Connect compatible audio ports"
    }
    switch (sourceChannel, targetChannel) {
    case (.all, .all), (.channel, .all):
      return nil
    case (.channel, .channel):
      return nil
    case (.all, .channel):
      return "Separate the source channels before connecting"
    }
  }

  private static func signalTypesAreCompatible(
    source: RoutingSignalType,
    target: RoutingSignalType
  ) -> Bool {
    if source == target { return true }
    if case .label(let sourceDomain) = source,
      sourceDomain != nil,
      case .label(domain: nil) = target
    {
      return true
    }
    return false
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
