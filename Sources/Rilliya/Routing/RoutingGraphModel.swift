import CoreGraphics
import FlowingDayGraphCanvas
import FlowingDayGraphComposition
import FlowingDayGraphCore
import Foundation
import RilliyaKit

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

struct RoutingInputDeviceSelection: Equatable, Hashable, Identifiable, Sendable {
  let id: AudioDeviceID
  let displayName: String

  init(id: AudioDeviceID, displayName: String) {
    precondition(!displayName.isEmpty)
    self.id = id
    self.displayName = displayName
  }
}

enum RoutingNodeValue: Equatable, Sendable {
  case applicationAudio(
    selection: RoutingApplicationSelection?,
    channelPresentation: RoutingChannelPresentation
  )
  case inputAudio(
    selection: RoutingInputDeviceSelection?,
    channelPresentation: RoutingChannelPresentation
  )
  case visualizer(configuration: RoutingVisualizerConfiguration)
  case peakLevel

  var applicationSelection: RoutingApplicationSelection? {
    switch self {
    case .applicationAudio(let selection, _):
      return selection
    case .inputAudio, .visualizer, .peakLevel:
      return nil
    }
  }

  var inputDeviceSelection: RoutingInputDeviceSelection? {
    guard case .inputAudio(let selection, _) = self else { return nil }
    return selection
  }

  var visualizerConfiguration: RoutingVisualizerConfiguration? {
    guard case .visualizer(let configuration) = self else { return nil }
    return configuration
  }

  var audioSourceChannelPresentation: RoutingChannelPresentation? {
    switch self {
    case .applicationAudio(_, let presentation), .inputAudio(_, let presentation):
      return presentation
    case .visualizer, .peakLevel:
      return nil
    }
  }

  func replacingAudioSourceChannelPresentation(
    _ presentation: RoutingChannelPresentation
  ) -> RoutingNodeValue? {
    switch self {
    case .applicationAudio(let selection, _):
      return .applicationAudio(selection: selection, channelPresentation: presentation)
    case .inputAudio(let selection, _):
      return .inputAudio(selection: selection, channelPresentation: presentation)
    case .visualizer, .peakLevel:
      return nil
    }
  }

  var title: String {
    switch self {
    case .applicationAudio:
      return "Application Audio"
    case .inputAudio:
      return "Input Audio"
    case .visualizer:
      return "Visualizer"
    case .peakLevel:
      return "Peak Level"
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
    audioSourceChannelPresentation
  }
}

enum RoutingVisualizerMode: String, CaseIterable, Equatable, Hashable, Sendable {
  case mixed
  case separate
}

enum RoutingVisualizerChannelPreset: Int, CaseIterable, Equatable, Hashable, Sendable {
  case mono = 1
  case stereo = 2
  case quadraphonic = 4
  case surround51 = 6
  case surround71 = 8

  var requestedChannels: Set<Int> {
    Set(0..<rawValue)
  }
}

enum RoutingVisualizerChannelSelection: Equatable, Hashable, Sendable {
  case preset(RoutingVisualizerChannelPreset)
  case custom(Set<Int>)

  var requestedChannels: Set<Int> {
    switch self {
    case .preset(let preset):
      preset.requestedChannels
    case .custom(let channels):
      channels
    }
  }
}

struct RoutingVisualizerConfiguration: Equatable, Sendable {
  static let maximumAvailableChannelCount = 256
  static let maximumSeparateLaneCount = 8

  var mode: RoutingVisualizerMode
  var availableChannelCount: Int
  var channelSelection: RoutingVisualizerChannelSelection

  static let initial = RoutingVisualizerConfiguration(
    mode: .mixed,
    availableChannelCount: 2,
    channelSelection: .preset(.stereo)
  )

  init(
    mode: RoutingVisualizerMode,
    availableChannelCount: Int,
    channelSelection: RoutingVisualizerChannelSelection
  ) {
    self.mode = mode
    self.availableChannelCount = availableChannelCount
    self.channelSelection = channelSelection
  }

  init(
    mode: RoutingVisualizerMode,
    availableChannelCount: Int,
    selectedChannels: Set<Int>
  ) {
    self.init(
      mode: mode,
      availableChannelCount: availableChannelCount,
      channelSelection: .custom(selectedChannels)
    )
  }

  var selectedChannels: Set<Int> {
    get { channelSelection.requestedChannels }
    set { channelSelection = .custom(newValue) }
  }

  var normalizedSelectedChannels: [Int] {
    Array(
      channelSelection.requestedChannels
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
  var disabledPortIDs: Set<RoutingGraphPortID>

  init(
    id: UUID,
    value: RoutingNodeValue,
    frame: CGRect,
    disabledPortIDs: Set<RoutingGraphPortID> = []
  ) {
    self.id = id
    self.value = value
    self.frame = frame
    self.disabledPortIDs = disabledPortIDs
  }

  func isPortEnabled(_ portID: RoutingGraphPortID) -> Bool {
    !disabledPortIDs.contains(portID)
  }
}

struct RoutingWorkspacePortAddress: Equatable, Hashable, Sendable {
  let nodeID: UUID
  let portID: RoutingGraphPortID
}

struct RoutingWorkspaceEdge: Equatable, Identifiable, Sendable {
  let id: UUID
  let source: RoutingWorkspacePortAddress
  let target: RoutingWorkspacePortAddress
  var isEnabled: Bool

  init(
    id: UUID,
    source: RoutingWorkspacePortAddress,
    target: RoutingWorkspacePortAddress,
    isEnabled: Bool = true
  ) {
    self.id = id
    self.source = source
    self.target = target
    self.isEnabled = isEnabled
  }
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
  var isEnabled: Bool

  init(
    direction: RoutingPortDirection,
    channel: RoutingAudioPortChannel,
    name: String? = nil,
    connectionPolicy: RoutingPortConnectionPolicy? = nil,
    ordinal: Int,
    total: Int
  ) {
    self.direction = direction
    key = .audio(channel)
    signalType = .audio
    self.connectionPolicy =
      connectionPolicy ?? (direction == .input ? .mixingInput : .fanOut)
    let defaultName =
      switch channel {
      case .all:
        "All channels"
      case .channel(let index):
        "Channel \(index + 1)"
      }
    self.name = name ?? defaultName
    self.ordinal = ordinal
    self.total = total
    isEnabled = true
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
    isEnabled = true
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
  let isEnabled: Bool
  let isActive: Bool
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
    case .applicationAudio(let selection, .aggregate):
      if selection != nil {
        return CGSize(width: baseNodeSize.width, height: 80)
      }
      portCount = 1
    case .applicationAudio(let selection, .separate(let channelCount)):
      let minimumHeight = selection == nil ? baseNodeSize.height : 80
      return CGSize(
        width: baseNodeSize.width,
        height: max(minimumHeight, RoutingAudioSourceLayout.nodeHeight(channelCount: channelCount))
      )
    case .inputAudio(let selection, .aggregate):
      if selection != nil {
        return CGSize(width: baseNodeSize.width, height: 80)
      }
      portCount = 1
    case .inputAudio(let selection, .separate(let channelCount)):
      let minimumHeight = selection == nil ? baseNodeSize.height : 80
      return CGSize(
        width: baseNodeSize.width,
        height: max(minimumHeight, RoutingAudioSourceLayout.nodeHeight(channelCount: channelCount))
      )
    case .visualizer(let configuration):
      return CGSize(
        width: baseNodeSize.width,
        height: RoutingVisualizerLayout.nodeHeight(for: configuration)
      )
    case .peakLevel:
      return baseNodeSize
    }
    return CGSize(
      width: baseNodeSize.width,
      height: max(baseNodeSize.height, CGFloat(portCount + 1) * 18)
    )
  }
}

enum RoutingAudioSourceLayout {
  static let rowsTop: CGFloat = 66
  static let rowHeight: CGFloat = 24
  static let rowSpacing: CGFloat = 4
  static let horizontalInset: CGFloat = 14
  static let channelLabelWidth: CGFloat = 36
  static let portLabelGutter: CGFloat = 42
  static let bottomInset: CGFloat = 12

  static func nodeHeight(channelCount: Int) -> CGFloat {
    let count = max(channelCount, 1)
    return rowsTop + CGFloat(count) * rowHeight
      + CGFloat(max(count - 1, 0)) * rowSpacing + bottomInset
  }

  static func rowFrames(in nodeFrame: CGRect, channelCount: Int) -> [CGRect] {
    (0..<max(channelCount, 1)).map { index in
      CGRect(
        x: nodeFrame.minX + horizontalInset,
        y: nodeFrame.minY + rowsTop + CGFloat(index) * (rowHeight + rowSpacing),
        width: nodeFrame.width - horizontalInset * 2 - portLabelGutter,
        height: rowHeight
      )
    }
  }
}

enum RoutingVisualizerLayout {
  static let waveformTop: CGFloat = 70
  static let singleLaneHeight: CGFloat = 42
  static let separateLaneHeight: CGFloat = 32
  static let laneSpacing: CGFloat = 6
  static let horizontalInset: CGFloat = 14
  static let portLabelGutter: CGFloat = 48
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
        x: nodeFrame.minX + horizontalInset + portLabelGutter,
        y: nodeFrame.minY + waveformTop + CGFloat(index) * (height + laneSpacing),
        width: nodeFrame.width - horizontalInset * 2 - portLabelGutter,
        height: height
      )
    }
  }

  static func waitingFrame(
    in nodeFrame: CGRect,
    configuration: RoutingVisualizerConfiguration
  ) -> CGRect {
    CGRect(
      x: nodeFrame.minX + horizontalInset + portLabelGutter,
      y: nodeFrame.minY + waveformTop,
      width: nodeFrame.width - horizontalInset * 2 - portLabelGutter,
      height: waveformContentHeight(for: configuration)
    )
  }
}

enum RoutingGraphPorts {
  static func values(for node: RoutingWorkspaceNode) -> [RoutingGraphPortValue] {
    values(for: node.value).map { value in
      var value = value
      value.isEnabled = node.isPortEnabled(value.id)
      return value
    }
  }

  static func values(for value: RoutingNodeValue) -> [RoutingGraphPortValue] {
    let identities: [(RoutingPortDirection, RoutingAudioPortChannel)]
    switch value {
    case .applicationAudio(_, let channelPresentation),
      .inputAudio(_, let channelPresentation):
      identities = outputIdentities(for: channelPresentation)
    case .visualizer(let configuration):
      switch configuration.mode {
      case .mixed:
        identities = [(.input, .all)]
      case .separate:
        identities = configuration.normalizedSelectedChannels.map { (.input, .channel($0)) }
      }
    case .peakLevel:
      return [
        RoutingGraphPortValue(
          direction: .input,
          channel: .all,
          name: "Audio",
          connectionPolicy: .singleInput,
          ordinal: 0,
          total: 1
        ),
        RoutingGraphPortValue(
          direction: .output,
          id: "peak",
          name: "Peak Level",
          signalType: .floatingPoint,
          connectionPolicy: .fanOut,
          ordinal: 0,
          total: 1
        ),
      ]
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
