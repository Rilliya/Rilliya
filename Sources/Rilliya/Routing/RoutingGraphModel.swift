import CoreGraphics
import FlowingDayGraphCanvas
import FlowingDayGraphComposition
import FlowingDayGraphCore
import Foundation
import RilliyaCore
import RilliyaDSP

struct RoutingApplicationSelection: Codable, Equatable, Hashable, Identifiable, Sendable {
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

struct RoutingOutputDeviceSelection: Equatable, Hashable, Identifiable, Sendable {
  let id: AudioDeviceID
  let displayName: String

  init(id: AudioDeviceID, displayName: String) {
    precondition(!displayName.isEmpty)
    self.id = id
    self.displayName = displayName
  }
}

extension RoutingInputDeviceSelection: Codable {
  private enum CodingKeys: String, CodingKey {
    case id
    case displayName
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawID = try container.decode(String.self, forKey: .id)
    let displayName = try container.decode(String.self, forKey: .displayName)
    guard let id = AudioDeviceID(rawValue: rawID),
      !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .id,
        in: container,
        debugDescription: "Input device selections require a valid device ID and name."
      )
    }
    self.init(id: id, displayName: displayName)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id.rawValue, forKey: .id)
    try container.encode(displayName, forKey: .displayName)
  }
}

extension RoutingOutputDeviceSelection: Codable {
  private enum CodingKeys: String, CodingKey {
    case id
    case displayName
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let rawID = try container.decode(String.self, forKey: .id)
    let displayName = try container.decode(String.self, forKey: .displayName)
    guard let id = AudioDeviceID(rawValue: rawID),
      !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .id,
        in: container,
        debugDescription: "Output device selections require a valid device ID and name."
      )
    }
    self.init(id: id, displayName: displayName)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id.rawValue, forKey: .id)
    try container.encode(displayName, forKey: .displayName)
  }
}

enum RoutingNodeValue: Codable, Equatable, Sendable {
  case applicationAudio(
    selection: RoutingApplicationSelection?,
    channelPresentation: RoutingChannelPresentation
  )
  case inputAudio(
    selection: RoutingInputDeviceSelection?,
    channelPresentation: RoutingChannelPresentation
  )
  case outputAudio(
    selection: RoutingOutputDeviceSelection?,
    channelPresentation: RoutingChannelPresentation
  )
  case visualizer(configuration: RoutingVisualizerConfiguration)
  case audioMixer(configuration: RoutingAudioMixerConfiguration)
  case peakLevel
  case signalGenerator(configuration: RoutingSignalGeneratorConfiguration)
  case delay(configuration: RoutingDelayConfiguration)
  case noiseGate(configuration: RoutingNoiseGateConfiguration)

  var applicationSelection: RoutingApplicationSelection? {
    switch self {
    case .applicationAudio(let selection, _):
      return selection
    case .inputAudio, .outputAudio, .visualizer, .audioMixer, .peakLevel, .signalGenerator,
      .delay, .noiseGate:
      return nil
    }
  }

  var inputDeviceSelection: RoutingInputDeviceSelection? {
    guard case .inputAudio(let selection, _) = self else { return nil }
    return selection
  }

  var outputDeviceSelection: RoutingOutputDeviceSelection? {
    guard case .outputAudio(let selection, _) = self else { return nil }
    return selection
  }

  var visualizerConfiguration: RoutingVisualizerConfiguration? {
    guard case .visualizer(let configuration) = self else { return nil }
    return configuration
  }

  var audioMixerConfiguration: RoutingAudioMixerConfiguration? {
    guard case .audioMixer(let configuration) = self else { return nil }
    return configuration
  }

  var audioSourceChannelPresentation: RoutingChannelPresentation? {
    switch self {
    case .applicationAudio(_, let presentation), .inputAudio(_, let presentation):
      return presentation
    case .outputAudio, .visualizer, .audioMixer, .peakLevel, .signalGenerator, .delay,
      .noiseGate:
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
    case .outputAudio, .visualizer, .audioMixer, .peakLevel, .signalGenerator, .delay,
      .noiseGate:
      return nil
    }
  }

  var audioDestinationChannelPresentation: RoutingChannelPresentation? {
    guard case .outputAudio(_, let presentation) = self else { return nil }
    return presentation
  }

  func replacingAudioDestinationChannelPresentation(
    _ presentation: RoutingChannelPresentation
  ) -> RoutingNodeValue? {
    guard case .outputAudio(let selection, _) = self else { return nil }
    return .outputAudio(selection: selection, channelPresentation: presentation)
  }

  var title: String {
    switch self {
    case .applicationAudio:
      return "Application Audio"
    case .inputAudio:
      return "Input Audio"
    case .outputAudio:
      return "Output Audio"
    case .visualizer:
      return "Visualizer"
    case .audioMixer:
      return "Audio Mixer"
    case .peakLevel:
      return "Peak Level"
    case .signalGenerator:
      return "Signal Generator"
    case .delay:
      return "Delay"
    case .noiseGate:
      return "Noise Gate"
    }
  }
}

enum RoutingChannelPresentation: Codable, Equatable, Hashable, Sendable {
  case aggregate
  case separate(channelCount: Int)

  var channelCount: Int? {
    guard case .separate(let channelCount) = self else { return nil }
    return channelCount
  }
}

struct RoutingAudioChannelControl: Codable, Equatable, Hashable, Sendable {
  static let minimumGainDecibels = -60.0
  static let maximumGainDecibels = 12.0
  static let unity = RoutingAudioChannelControl(gainDecibels: 0, isMuted: false)

  var gainDecibels: Double
  var isMuted: Bool

  init(gainDecibels: Double, isMuted: Bool) {
    precondition(gainDecibels.isFinite)
    precondition(
      (Self.minimumGainDecibels...Self.maximumGainDecibels).contains(gainDecibels)
    )
    self.gainDecibels = gainDecibels
    self.isMuted = isMuted
  }

  var linearGain: Float {
    guard !isMuted else { return 0 }
    return Float(pow(10, gainDecibels / 20))
  }

  var gainDescription: String {
    if gainDecibels == 0 { return "0 dB" }
    return String(
      format: "%+.0f dB",
      locale: Locale(identifier: "en_US_POSIX"),
      gainDecibels
    )
  }

  private enum CodingKeys: String, CodingKey {
    case gainDecibels
    case isMuted
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let gainDecibels = try container.decode(Double.self, forKey: .gainDecibels)
    guard gainDecibels.isFinite,
      (Self.minimumGainDecibels...Self.maximumGainDecibels).contains(gainDecibels)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .gainDecibels,
        in: container,
        debugDescription: "Audio channel gain is outside the supported range."
      )
    }
    self.init(
      gainDecibels: gainDecibels,
      isMuted: try container.decode(Bool.self, forKey: .isMuted)
    )
  }
}

struct RoutingAudioMixerConfiguration: Codable, Equatable, Hashable, Sendable {
  static let minimumChannelCount = 1
  static let maximumChannelCount = 8
  static let initial = RoutingAudioMixerConfiguration(channelCount: 2)

  var channelCount: Int

  init(channelCount: Int) {
    precondition(
      (Self.minimumChannelCount...Self.maximumChannelCount).contains(channelCount)
    )
    self.channelCount = channelCount
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let channelCount = try container.decode(Int.self)
    guard (Self.minimumChannelCount...Self.maximumChannelCount).contains(channelCount) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Audio mixer channel count is outside the supported range."
      )
    }
    self.init(channelCount: channelCount)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(channelCount)
  }
}

struct RoutingSignalGeneratorConfiguration: Codable, Equatable, Hashable, Sendable {
  static let minimumFrequency = 1.0
  static let maximumFrequency = 20_000.0
  static let initial = RoutingSignalGeneratorConfiguration(
    waveform: .sine,
    frequency: 440,
    amplitude: 0.25
  )

  var waveform: AudioSignalGeneratorWaveform
  var frequency: Double
  var amplitude: Float

  init(
    waveform: AudioSignalGeneratorWaveform,
    frequency: Double,
    amplitude: Float
  ) {
    precondition(frequency.isFinite)
    precondition((Self.minimumFrequency...Self.maximumFrequency).contains(frequency))
    precondition(amplitude.isFinite && (0...1).contains(amplitude))
    self.waveform = waveform
    self.frequency = frequency
    self.amplitude = amplitude
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let waveform = try container.decode(AudioSignalGeneratorWaveform.self, forKey: .waveform)
    let frequency = try container.decode(Double.self, forKey: .frequency)
    let amplitude = try container.decode(Float.self, forKey: .amplitude)
    guard frequency.isFinite,
      (Self.minimumFrequency...Self.maximumFrequency).contains(frequency),
      amplitude.isFinite,
      (0...1).contains(amplitude)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .frequency,
        in: container,
        debugDescription: "Signal generator parameters are outside the supported range."
      )
    }
    self.init(waveform: waveform, frequency: frequency, amplitude: amplitude)
  }
}

struct RoutingDelayConfiguration: Codable, Equatable, Hashable, Sendable {
  static let minimumDelaySeconds = 0.001
  static let maximumDelaySeconds = AudioDelayConfiguration.maximumDelaySeconds
  static let maximumFeedback: Float = 0.95
  static let initial = RoutingDelayConfiguration(
    delaySeconds: 0.25,
    feedback: 0.25,
    dryWetMix: 0.5
  )

  var delaySeconds: Double
  var feedback: Float
  var dryWetMix: Float

  init(delaySeconds: Double, feedback: Float, dryWetMix: Float) {
    precondition(delaySeconds.isFinite)
    precondition((Self.minimumDelaySeconds...Self.maximumDelaySeconds).contains(delaySeconds))
    precondition(
      feedback.isFinite && (-Self.maximumFeedback...Self.maximumFeedback).contains(feedback))
    precondition(dryWetMix.isFinite && (0...1).contains(dryWetMix))
    self.delaySeconds = delaySeconds
    self.feedback = feedback
    self.dryWetMix = dryWetMix
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let delaySeconds = try container.decode(Double.self, forKey: .delaySeconds)
    let feedback = try container.decode(Float.self, forKey: .feedback)
    let dryWetMix = try container.decode(Float.self, forKey: .dryWetMix)
    guard delaySeconds.isFinite,
      (Self.minimumDelaySeconds...Self.maximumDelaySeconds).contains(delaySeconds),
      feedback.isFinite,
      (-Self.maximumFeedback...Self.maximumFeedback).contains(feedback),
      dryWetMix.isFinite,
      (0...1).contains(dryWetMix)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .delaySeconds,
        in: container,
        debugDescription: "Delay parameters are outside the supported range."
      )
    }
    self.init(
      delaySeconds: delaySeconds,
      feedback: feedback,
      dryWetMix: dryWetMix
    )
  }
}

struct RoutingNoiseGateConfiguration: Codable, Equatable, Hashable, Sendable {
  static let minimumThresholdDecibels: Float = -96
  static let maximumThresholdDecibels: Float = 0
  static let maximumHysteresisDecibels: Float = 24
  static let maximumAttackSeconds = 1.0
  static let maximumHoldSeconds = 5.0
  static let maximumReleaseSeconds = 10.0
  static let maximumReductionDecibels: Float = 96
  static let initial = RoutingNoiseGateConfiguration(
    thresholdDecibels: -40,
    hysteresisDecibels: 6,
    attackSeconds: 0.005,
    holdSeconds: 0.05,
    releaseSeconds: 0.15,
    reductionDecibels: 60
  )

  var thresholdDecibels: Float
  var hysteresisDecibels: Float
  var attackSeconds: Double
  var holdSeconds: Double
  var releaseSeconds: Double
  var reductionDecibels: Float

  init(
    thresholdDecibels: Float,
    hysteresisDecibels: Float,
    attackSeconds: Double,
    holdSeconds: Double,
    releaseSeconds: Double,
    reductionDecibels: Float
  ) {
    precondition(Self.isValidThreshold(thresholdDecibels))
    precondition(Self.isValidHysteresis(hysteresisDecibels))
    precondition(Self.isValidAttack(attackSeconds))
    precondition(Self.isValidHold(holdSeconds))
    precondition(Self.isValidRelease(releaseSeconds))
    precondition(Self.isValidReduction(reductionDecibels))
    self.thresholdDecibels = thresholdDecibels
    self.hysteresisDecibels = hysteresisDecibels
    self.attackSeconds = attackSeconds
    self.holdSeconds = holdSeconds
    self.releaseSeconds = releaseSeconds
    self.reductionDecibels = reductionDecibels
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let threshold = try container.decode(Float.self, forKey: .thresholdDecibels)
    let hysteresis = try container.decode(Float.self, forKey: .hysteresisDecibels)
    let attack = try container.decode(Double.self, forKey: .attackSeconds)
    let hold = try container.decode(Double.self, forKey: .holdSeconds)
    let release = try container.decode(Double.self, forKey: .releaseSeconds)
    let reduction = try container.decode(Float.self, forKey: .reductionDecibels)
    guard Self.isValidThreshold(threshold),
      Self.isValidHysteresis(hysteresis),
      Self.isValidAttack(attack),
      Self.isValidHold(hold),
      Self.isValidRelease(release),
      Self.isValidReduction(reduction)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .thresholdDecibels,
        in: container,
        debugDescription: "Noise-gate parameters are outside the supported range."
      )
    }
    self.init(
      thresholdDecibels: threshold,
      hysteresisDecibels: hysteresis,
      attackSeconds: attack,
      holdSeconds: hold,
      releaseSeconds: release,
      reductionDecibels: reduction
    )
  }

  private static func isValidThreshold(_ value: Float) -> Bool {
    value.isFinite && (minimumThresholdDecibels...maximumThresholdDecibels).contains(value)
  }

  private static func isValidHysteresis(_ value: Float) -> Bool {
    value.isFinite && (0...maximumHysteresisDecibels).contains(value)
  }

  private static func isValidAttack(_ value: Double) -> Bool {
    value.isFinite && (0...maximumAttackSeconds).contains(value)
  }

  private static func isValidHold(_ value: Double) -> Bool {
    value.isFinite && (0...maximumHoldSeconds).contains(value)
  }

  private static func isValidRelease(_ value: Double) -> Bool {
    value.isFinite && (0...maximumReleaseSeconds).contains(value)
  }

  private static func isValidReduction(_ value: Float) -> Bool {
    value.isFinite && (0...maximumReductionDecibels).contains(value)
  }

  var isValid: Bool {
    Self.isValidThreshold(thresholdDecibels)
      && Self.isValidHysteresis(hysteresisDecibels)
      && Self.isValidAttack(attackSeconds)
      && Self.isValidHold(holdSeconds)
      && Self.isValidRelease(releaseSeconds)
      && Self.isValidReduction(reductionDecibels)
  }
}

extension AudioSignalGeneratorWaveform {
  var displayName: String {
    switch self {
    case .sine: "Sine"
    case .square: "Square"
    case .triangle: "Triangle"
    case .sawtooth: "Sawtooth"
    case .whiteNoise: "White Noise"
    case .pinkNoise: "Pink Noise"
    case .brownNoise: "Brown Noise"
    }
  }

  var usesFrequency: Bool {
    switch self {
    case .sine, .square, .triangle, .sawtooth: true
    case .whiteNoise, .pinkNoise, .brownNoise: false
    }
  }
}

extension RoutingNodeValue {
  var channelPresentation: RoutingChannelPresentation? {
    audioSourceChannelPresentation
  }
}

enum RoutingVisualizerMode: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
  case mixed
  case separate
}

enum RoutingVisualizerChannelPreset: Int, CaseIterable, Codable, Equatable, Hashable, Sendable {
  case mono = 1
  case stereo = 2
  case quadraphonic = 4
  case surround51 = 6
  case surround71 = 8

  var requestedChannels: Set<Int> {
    Set(0..<rawValue)
  }
}

enum RoutingVisualizerChannelSelection: Codable, Equatable, Hashable, Sendable {
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

struct RoutingVisualizerConfiguration: Codable, Equatable, Sendable {
  static let maximumAvailableChannelCount = 256
  static let maximumSeparateLaneCount = 8

  var mode: RoutingVisualizerMode
  var availableChannelCount: Int
  var channelSelection: RoutingVisualizerChannelSelection
  var includesMixedOutput: Bool

  static let initial = RoutingVisualizerConfiguration(
    mode: .mixed,
    availableChannelCount: 2,
    channelSelection: .preset(.stereo),
    includesMixedOutput: false
  )

  init(
    mode: RoutingVisualizerMode,
    availableChannelCount: Int,
    channelSelection: RoutingVisualizerChannelSelection,
    includesMixedOutput: Bool = false
  ) {
    self.mode = mode
    self.availableChannelCount = availableChannelCount
    self.channelSelection = channelSelection
    self.includesMixedOutput = includesMixedOutput
  }

  init(
    mode: RoutingVisualizerMode,
    availableChannelCount: Int,
    selectedChannels: Set<Int>,
    includesMixedOutput: Bool = false
  ) {
    self.init(
      mode: mode,
      availableChannelCount: availableChannelCount,
      channelSelection: .custom(selectedChannels),
      includesMixedOutput: includesMixedOutput
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

  private enum CodingKeys: String, CodingKey {
    case mode
    case availableChannelCount
    case channelSelection
    case includesMixedOutput
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      mode: try container.decode(RoutingVisualizerMode.self, forKey: .mode),
      availableChannelCount: try container.decode(Int.self, forKey: .availableChannelCount),
      channelSelection: try container.decode(
        RoutingVisualizerChannelSelection.self,
        forKey: .channelSelection
      ),
      includesMixedOutput: try container.decodeIfPresent(
        Bool.self,
        forKey: .includesMixedOutput
      ) ?? false
    )
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(mode, forKey: .mode)
    try container.encode(availableChannelCount, forKey: .availableChannelCount)
    try container.encode(channelSelection, forKey: .channelSelection)
    try container.encode(includesMixedOutput, forKey: .includesMixedOutput)
  }
}

struct RoutingWorkspaceNode: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var value: RoutingNodeValue
  var frame: CGRect
  var disabledPortIDs: Set<RoutingGraphPortID>
  var audioChannelControls: [Int: RoutingAudioChannelControl]
  var accentOverride: RoutingAccentID?

  init(
    id: UUID,
    value: RoutingNodeValue,
    frame: CGRect,
    disabledPortIDs: Set<RoutingGraphPortID> = [],
    audioChannelControls: [Int: RoutingAudioChannelControl] = [:],
    accentOverride: RoutingAccentID? = nil
  ) {
    self.id = id
    self.value = value
    self.frame = frame
    self.disabledPortIDs = disabledPortIDs
    self.audioChannelControls = audioChannelControls
    self.accentOverride = accentOverride
  }

  func isPortEnabled(_ portID: RoutingGraphPortID) -> Bool {
    !disabledPortIDs.contains(portID)
  }

  func audioChannelControl(at channelIndex: Int) -> RoutingAudioChannelControl {
    audioChannelControls[channelIndex] ?? .unity
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case value
    case frame
    case disabledPortIDs
    case audioChannelControls
    case accentOverride
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(UUID.self, forKey: .id),
      value: try container.decode(RoutingNodeValue.self, forKey: .value),
      frame: try container.decode(CGRect.self, forKey: .frame),
      disabledPortIDs: try container.decodeIfPresent(
        Set<RoutingGraphPortID>.self,
        forKey: .disabledPortIDs
      ) ?? [],
      audioChannelControls: try container.decodeIfPresent(
        [Int: RoutingAudioChannelControl].self,
        forKey: .audioChannelControls
      ) ?? [:],
      accentOverride: try container.decodeIfPresent(
        RoutingAccentID.self,
        forKey: .accentOverride
      )
    )
  }
}

struct RoutingWorkspacePortAddress: Codable, Equatable, Hashable, Sendable {
  let nodeID: UUID
  let portID: RoutingGraphPortID
}

struct RoutingWorkspaceEdge: Codable, Equatable, Identifiable, Sendable {
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

enum RoutingPortDirection: Codable, Equatable, Hashable, Sendable {
  case input
  case output
}

enum RoutingAudioPortChannel: Codable, Equatable, Hashable, Sendable {
  case all
  case channel(Int)
}

struct RoutingGraphPortID: Codable, Equatable, Hashable, Sendable {
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

enum RoutingPortKey: Codable, Equatable, Hashable, Sendable {
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
  static let mixerNodeWidth: CGFloat = 300
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
    case .outputAudio(let selection, .aggregate):
      if selection != nil {
        return CGSize(width: baseNodeSize.width, height: 80)
      }
      portCount = 1
    case .outputAudio(let selection, .separate(let channelCount)):
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
    case .audioMixer(let configuration):
      return CGSize(
        width: mixerNodeWidth,
        height: max(
          baseNodeSize.height,
          RoutingAudioMixerLayout.nodeHeight(channelCount: configuration.channelCount)
        )
      )
    case .peakLevel, .signalGenerator, .delay, .noiseGate:
      return baseNodeSize
    }
    return CGSize(
      width: baseNodeSize.width,
      height: max(baseNodeSize.height, CGFloat(portCount + 1) * 18)
    )
  }
}

enum RoutingAudioMixerLayout {
  static let rowsTop = RoutingAudioSourceLayout.rowsTop
  static let rowHeight = RoutingAudioSourceLayout.rowHeight
  static let rowSpacing = RoutingAudioSourceLayout.rowSpacing
  static let horizontalInset = RoutingAudioSourceLayout.horizontalInset
  static let portLabelGutter: CGFloat = 42
  static let bottomInset = RoutingAudioSourceLayout.bottomInset

  static func nodeHeight(channelCount: Int) -> CGFloat {
    rowsTop + CGFloat(max(channelCount, 1)) * rowHeight
      + CGFloat(max(channelCount - 1, 0)) * rowSpacing + bottomInset
  }

  static func rowFrames(in nodeFrame: CGRect, channelCount: Int) -> [CGRect] {
    (0..<max(channelCount, 1)).map { index in
      CGRect(
        x: nodeFrame.minX + horizontalInset + portLabelGutter,
        y: nodeFrame.minY + rowsTop + CGFloat(index) * (rowHeight + rowSpacing),
        width: nodeFrame.width - horizontalInset * 2 - portLabelGutter * 2,
        height: rowHeight
      )
    }
  }
}

enum RoutingAudioSourceLayout {
  static let rowsTop: CGFloat = 66
  static let rowHeight: CGFloat = 24
  static let rowSpacing: CGFloat = 4
  static let horizontalInset: CGFloat = 14
  static let channelLabelWidth: CGFloat = 28
  static let gainValueWidth: CGFloat = 38
  static let muteButtonWidth: CGFloat = 20
  static let controlSpacing: CGFloat = 5
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

  static func gainTrackFrame(in rowFrame: CGRect) -> CGRect {
    CGRect(
      x: rowFrame.minX + channelLabelWidth,
      y: rowFrame.midY - 4,
      width: max(
        1,
        rowFrame.width - channelLabelWidth - gainValueWidth - muteButtonWidth
          - controlSpacing * 2
      ),
      height: 8
    )
  }

  static func gainValueFrame(in rowFrame: CGRect) -> CGRect {
    let track = gainTrackFrame(in: rowFrame)
    return CGRect(
      x: track.maxX + controlSpacing,
      y: rowFrame.minY,
      width: gainValueWidth,
      height: rowFrame.height
    )
  }

  static func muteButtonFrame(in rowFrame: CGRect) -> CGRect {
    CGRect(
      x: rowFrame.maxX - muteButtonWidth,
      y: rowFrame.midY - muteButtonWidth / 2,
      width: muteButtonWidth,
      height: muteButtonWidth
    )
  }

  static func gainFraction(for gainDecibels: Double) -> CGFloat {
    let range =
      RoutingAudioChannelControl.maximumGainDecibels
      - RoutingAudioChannelControl.minimumGainDecibels
    return CGFloat(
      (min(
        max(gainDecibels, RoutingAudioChannelControl.minimumGainDecibels),
        RoutingAudioChannelControl.maximumGainDecibels
      ) - RoutingAudioChannelControl.minimumGainDecibels) / range
    )
  }

  static func gainDecibels(at x: CGFloat, in trackFrame: CGRect) -> Double {
    guard trackFrame.width > 0 else { return 0 }
    let fraction = min(max((x - trackFrame.minX) / trackFrame.width, 0), 1)
    let range =
      RoutingAudioChannelControl.maximumGainDecibels
      - RoutingAudioChannelControl.minimumGainDecibels
    return (RoutingAudioChannelControl.minimumGainDecibels + Double(fraction) * range)
      .rounded()
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
  static let mixedOutputSpacing: CGFloat = 10
  static let mixedOutputHeight: CGFloat = 18
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
    let mixedOutputExtraHeight =
      configuration.mode == .separate && configuration.includesMixedOutput
      ? mixedOutputSpacing + mixedOutputHeight
      : 0
    return min(
      maximumNodeHeight + mixedOutputSpacing + mixedOutputHeight,
      max(
        RoutingCanvasMetrics.baseNodeSize.height,
        waveformTop + waveformContentHeight(for: configuration) + bottomInset
          + mixedOutputExtraHeight
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
        width: nodeFrame.width - horizontalInset * 2 - portLabelGutter * 2,
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
      width: nodeFrame.width - horizontalInset * 2 - portLabelGutter * 2,
      height: waveformContentHeight(for: configuration)
    )
  }

  static func mixedOutputCenterY(
    in nodeFrame: CGRect,
    configuration: RoutingVisualizerConfiguration
  ) -> CGFloat? {
    guard configuration.mode == .separate, configuration.includesMixedOutput else {
      return nil
    }
    return nodeFrame.minY + waveformTop + waveformContentHeight(for: configuration)
      + mixedOutputSpacing + mixedOutputHeight / 2
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
    case .outputAudio(_, let channelPresentation):
      identities = inputIdentities(for: channelPresentation)
    case .visualizer(let configuration):
      return visualizerValues(for: configuration)
    case .audioMixer(let configuration):
      return audioMixerValues(for: configuration)
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
    case .signalGenerator:
      return [
        RoutingGraphPortValue(
          direction: .output,
          channel: .channel(0),
          name: "Mono",
          connectionPolicy: .fanOut,
          ordinal: 0,
          total: 1
        )
      ]
    case .delay:
      return effectValues(outputName: "Delayed Audio")
    case .noiseGate:
      return effectValues(outputName: "Gated Audio")
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

  private static func effectValues(outputName: String) -> [RoutingGraphPortValue] {
    [
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
        channel: .all,
        name: outputName,
        connectionPolicy: .fanOut,
        ordinal: 0,
        total: 1
      ),
    ]
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

  private static func inputIdentities(
    for presentation: RoutingChannelPresentation
  ) -> [(RoutingPortDirection, RoutingAudioPortChannel)] {
    switch presentation {
    case .aggregate:
      return [(.input, .all)]
    case .separate(let channelCount):
      return (0..<channelCount).map { (.input, .channel($0)) }
    }
  }

  private static func visualizerValues(
    for configuration: RoutingVisualizerConfiguration
  ) -> [RoutingGraphPortValue] {
    switch configuration.mode {
    case .mixed:
      return [
        RoutingGraphPortValue(
          direction: .input,
          channel: .all,
          connectionPolicy: .singleInput,
          ordinal: 0,
          total: 1
        ),
        RoutingGraphPortValue(
          direction: .output,
          channel: .all,
          name: "Pass-through",
          connectionPolicy: .fanOut,
          ordinal: 0,
          total: 1
        ),
      ]
    case .separate:
      let channels = configuration.normalizedSelectedChannels
      let inputs = channels.enumerated().map { ordinal, channel in
        RoutingGraphPortValue(
          direction: .input,
          channel: .channel(channel),
          connectionPolicy: .singleInput,
          ordinal: ordinal,
          total: channels.count
        )
      }
      let outputCount = channels.count + (configuration.includesMixedOutput ? 1 : 0)
      let outputs = channels.enumerated().map { ordinal, channel in
        RoutingGraphPortValue(
          direction: .output,
          channel: .channel(channel),
          connectionPolicy: .fanOut,
          ordinal: ordinal,
          total: outputCount
        )
      }
      guard configuration.includesMixedOutput else { return inputs + outputs }
      return inputs + outputs + [
        RoutingGraphPortValue(
          direction: .output,
          channel: .all,
          name: "Mixed",
          connectionPolicy: .fanOut,
          ordinal: outputCount - 1,
          total: outputCount
        )
      ]
    }
  }

  private static func audioMixerValues(
    for configuration: RoutingAudioMixerConfiguration
  ) -> [RoutingGraphPortValue] {
    let inputs = (0..<configuration.channelCount).map { channel in
      RoutingGraphPortValue(
        direction: .input,
        channel: .channel(channel),
        connectionPolicy: .mixingInput,
        ordinal: channel,
        total: configuration.channelCount
      )
    }
    let outputs = (0..<configuration.channelCount).map { channel in
      RoutingGraphPortValue(
        direction: .output,
        channel: .channel(channel),
        connectionPolicy: .fanOut,
        ordinal: channel,
        total: configuration.channelCount
      )
    }
    return inputs + outputs
  }
}

enum RoutingPortCompatibility {
  static func separatedSourceChannel(
    source: RoutingGraphPortValue,
    target: RoutingGraphPortValue
  ) -> Int? {
    guard source.signalType == .audio,
      target.signalType == .audio,
      source.audioChannel == .all,
      case .some(.channel(let channel)) = target.audioChannel
    else {
      return nil
    }
    return channel
  }

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
