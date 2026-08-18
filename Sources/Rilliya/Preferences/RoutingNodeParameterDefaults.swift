import Foundation
import RilliyaDSP
import RilliyaFileWriting

struct RoutingChannelPresentationParameterDefaults: Codable, Equatable, Sendable {
  var channelPresentation: RoutingChannelPresentation?

  static let empty = RoutingChannelPresentationParameterDefaults()

  var enabledCount: Int { channelPresentation == nil ? 0 : 1 }
}

struct RoutingVisualizerParameterDefaults: Codable, Equatable, Sendable {
  var inputMode: RoutingVisualizerMode?
  var displayMode: RoutingVisualizerMode?
  var outputMode: RoutingVisualizerMode?
  var channelSelection: RoutingVisualizerChannelSelection?
  var includesMixedOutput: Bool?

  static let empty = RoutingVisualizerParameterDefaults()

  var enabledCount: Int {
    [
      inputMode != nil,
      displayMode != nil,
      outputMode != nil,
      channelSelection != nil,
      includesMixedOutput != nil,
    ].filter { $0 }.count
  }

  func applying(to configuration: RoutingVisualizerConfiguration)
    -> RoutingVisualizerConfiguration
  {
    var updated = configuration
    if let inputMode { updated.inputMode = inputMode }
    if let displayMode { updated.displayMode = displayMode }
    if let outputMode { updated.outputMode = outputMode }
    if let channelSelection { updated.channelSelection = channelSelection }
    if let includesMixedOutput { updated.includesMixedOutput = includesMixedOutput }
    return updated
  }
}

struct RoutingAudioMixerParameterDefaults: Codable, Equatable, Sendable {
  var channelCount: Int?

  static let empty = RoutingAudioMixerParameterDefaults()

  var enabledCount: Int { channelCount == nil ? 0 : 1 }

  func applying(to configuration: RoutingAudioMixerConfiguration)
    -> RoutingAudioMixerConfiguration
  {
    var updated = configuration
    if let channelCount { updated.channelCount = channelCount }
    return updated
  }
}

struct RoutingGainParameterDefaults: Codable, Equatable, Sendable {
  var gainDecibels: Double?
  var isMuted: Bool?
  var isPolarityInverted: Bool?

  static let empty = RoutingGainParameterDefaults()

  var enabledCount: Int {
    [gainDecibels != nil, isMuted != nil, isPolarityInverted != nil].filter { $0 }.count
  }

  func applying(to configuration: RoutingGainConfiguration) -> RoutingGainConfiguration {
    var updated = configuration
    if let gainDecibels { updated.gainDecibels = gainDecibels }
    if let isMuted { updated.isMuted = isMuted }
    if let isPolarityInverted { updated.isPolarityInverted = isPolarityInverted }
    return updated
  }
}

struct RoutingChannelRouterParameterDefaults: Codable, Equatable, Sendable {
  var routing: RoutingChannelRouterConfiguration?

  static let empty = RoutingChannelRouterParameterDefaults()

  var enabledCount: Int { routing == nil ? 0 : 1 }

  func applying(to configuration: RoutingChannelRouterConfiguration)
    -> RoutingChannelRouterConfiguration
  {
    routing ?? configuration
  }
}

struct RoutingSignalGeneratorParameterDefaults: Codable, Equatable, Sendable {
  var waveform: AudioSignalGeneratorWaveform?
  var frequency: Double?
  var amplitude: Float?

  static let empty = RoutingSignalGeneratorParameterDefaults()

  var enabledCount: Int {
    [waveform != nil, frequency != nil, amplitude != nil].filter { $0 }.count
  }

  func applying(to configuration: RoutingSignalGeneratorConfiguration)
    -> RoutingSignalGeneratorConfiguration
  {
    var updated = configuration
    if let waveform { updated.waveform = waveform }
    if let frequency { updated.frequency = frequency }
    if let amplitude { updated.amplitude = amplitude }
    return updated
  }
}

struct RoutingFilePlaybackParameterDefaults: Codable, Equatable, Sendable {
  var loopMode: RoutingFilePlaybackLoopMode?

  static let empty = RoutingFilePlaybackParameterDefaults()

  var enabledCount: Int { loopMode == nil ? 0 : 1 }

  func applying(to configuration: RoutingFilePlaybackConfiguration)
    -> RoutingFilePlaybackConfiguration
  {
    var updated = configuration
    if let loopMode { updated.loopMode = loopMode }
    return updated
  }
}

struct RoutingFileOutputFormatDefault: Codable, Equatable, Hashable, Sendable {
  var container: AudioFileContainer
  var encoding: AudioFileEncoding
}

struct RoutingFileOutputParameterDefaults: Codable, Equatable, Sendable {
  var format: RoutingFileOutputFormatDefault?
  var sampleRate: Double?
  var channelCount: Int?

  static let empty = RoutingFileOutputParameterDefaults()

  var enabledCount: Int {
    [format != nil, sampleRate != nil, channelCount != nil].filter { $0 }.count
  }

  func applying(to configuration: RoutingFileOutputConfiguration)
    -> RoutingFileOutputConfiguration
  {
    var updated = configuration
    if let format {
      updated.container = format.container
      updated.encoding = format.encoding
    }
    if let sampleRate { updated.sampleRate = sampleRate }
    if let channelCount { updated.channelCount = channelCount }
    return updated
  }
}

struct RoutingNetworkReceiveParameterDefaults: Codable, Equatable, Sendable {
  var sampleRate: Double?
  var channelCount: Int?
  var adoptsSenderFormat: Bool?
  var jitterTargetMilliseconds: Int?
  var jitterCorrection: RoutingNetworkJitterCorrection?

  static let empty = RoutingNetworkReceiveParameterDefaults()

  var enabledCount: Int {
    [
      sampleRate != nil,
      channelCount != nil,
      adoptsSenderFormat != nil,
      jitterTargetMilliseconds != nil,
      jitterCorrection != nil,
    ].filter { $0 }.count
  }

  func applying(to configuration: RoutingNetworkReceiveConfiguration)
    -> RoutingNetworkReceiveConfiguration
  {
    var updated = configuration
    if let sampleRate { updated.sampleRate = sampleRate }
    if let channelCount { updated.channelCount = channelCount }
    if let adoptsSenderFormat { updated.adoptsSenderFormat = adoptsSenderFormat }
    if let jitterTargetMilliseconds {
      updated.jitter.targetMilliseconds = jitterTargetMilliseconds
    }
    if let jitterCorrection { updated.jitter.correction = jitterCorrection }
    return updated
  }
}

struct RoutingDelayParameterDefaults: Codable, Equatable, Sendable {
  var delaySeconds: Double?
  var feedback: Float?
  var dryWetMix: Float?

  static let empty = RoutingDelayParameterDefaults()

  var enabledCount: Int {
    [delaySeconds != nil, feedback != nil, dryWetMix != nil].filter { $0 }.count
  }

  func applying(to configuration: RoutingDelayConfiguration) -> RoutingDelayConfiguration {
    var updated = configuration
    if let delaySeconds { updated.delaySeconds = delaySeconds }
    if let feedback { updated.feedback = feedback }
    if let dryWetMix { updated.dryWetMix = dryWetMix }
    return updated
  }
}

struct RoutingNoiseGateParameterDefaults: Codable, Equatable, Sendable {
  var thresholdDecibels: Float?
  var hysteresisDecibels: Float?
  var attackSeconds: Double?
  var holdSeconds: Double?
  var releaseSeconds: Double?
  var reductionDecibels: Float?

  static let empty = RoutingNoiseGateParameterDefaults()

  var enabledCount: Int {
    [
      thresholdDecibels != nil,
      hysteresisDecibels != nil,
      attackSeconds != nil,
      holdSeconds != nil,
      releaseSeconds != nil,
      reductionDecibels != nil,
    ].filter { $0 }.count
  }

  func applying(to configuration: RoutingNoiseGateConfiguration)
    -> RoutingNoiseGateConfiguration
  {
    var updated = configuration
    if let thresholdDecibels { updated.thresholdDecibels = thresholdDecibels }
    if let hysteresisDecibels { updated.hysteresisDecibels = hysteresisDecibels }
    if let attackSeconds { updated.attackSeconds = attackSeconds }
    if let holdSeconds { updated.holdSeconds = holdSeconds }
    if let releaseSeconds { updated.releaseSeconds = releaseSeconds }
    if let reductionDecibels { updated.reductionDecibels = reductionDecibels }
    return updated
  }
}

struct RoutingCompressorParameterDefaults: Codable, Equatable, Sendable {
  var thresholdDecibels: Float?
  var ratio: Float?
  var kneeDecibels: Float?
  var attackSeconds: Double?
  var releaseSeconds: Double?
  var makeupGainDecibels: Float?

  static let empty = RoutingCompressorParameterDefaults()

  var enabledCount: Int {
    [
      thresholdDecibels != nil,
      ratio != nil,
      kneeDecibels != nil,
      attackSeconds != nil,
      releaseSeconds != nil,
      makeupGainDecibels != nil,
    ].filter { $0 }.count
  }

  func applying(to configuration: RoutingCompressorConfiguration)
    -> RoutingCompressorConfiguration
  {
    var updated = configuration
    if let thresholdDecibels { updated.thresholdDecibels = thresholdDecibels }
    if let ratio { updated.ratio = ratio }
    if let kneeDecibels { updated.kneeDecibels = kneeDecibels }
    if let attackSeconds { updated.attackSeconds = attackSeconds }
    if let releaseSeconds { updated.releaseSeconds = releaseSeconds }
    if let makeupGainDecibels { updated.makeupGainDecibels = makeupGainDecibels }
    return updated
  }
}

enum RoutingNodeParameterDefaults: Codable, Equatable, Sendable {
  case applicationAudio(RoutingChannelPresentationParameterDefaults)
  case inputAudio(RoutingChannelPresentationParameterDefaults)
  case systemOutput(RoutingChannelPresentationParameterDefaults)
  case virtualOutput(RoutingChannelPresentationParameterDefaults)
  case outputAudio(RoutingChannelPresentationParameterDefaults)
  case virtualInput(RoutingChannelPresentationParameterDefaults)
  case visualizer(RoutingVisualizerParameterDefaults)
  case audioMixer(RoutingAudioMixerParameterDefaults)
  case gain(RoutingGainParameterDefaults)
  case channelRouter(RoutingChannelRouterParameterDefaults)
  case signalGenerator(RoutingSignalGeneratorParameterDefaults)
  case filePlayback(RoutingFilePlaybackParameterDefaults)
  case fileOutput(RoutingFileOutputParameterDefaults)
  case networkSend(RoutingNetworkSendParameterDefaults)
  case networkReceive(RoutingNetworkReceiveParameterDefaults)
  case delay(RoutingDelayParameterDefaults)
  case noiseGate(RoutingNoiseGateParameterDefaults)
  case compressor(RoutingCompressorParameterDefaults)

  var kind: RoutingNodeKind {
    switch self {
    case .applicationAudio: .applicationAudio
    case .inputAudio: .inputAudio
    case .systemOutput: .systemOutput
    case .virtualOutput: .virtualOutput
    case .outputAudio: .outputAudio
    case .virtualInput: .virtualInput
    case .visualizer: .visualizer
    case .audioMixer: .audioMixer
    case .gain: .gain
    case .channelRouter: .channelRouter
    case .signalGenerator: .signalGenerator
    case .filePlayback: .filePlayback
    case .fileOutput: .fileOutput
    case .networkSend: .networkSend
    case .networkReceive: .networkReceive
    case .delay: .delay
    case .noiseGate: .noiseGate
    case .compressor: .compressor
    }
  }

  var enabledCount: Int {
    switch self {
    case .applicationAudio(let defaults), .inputAudio(let defaults),
      .systemOutput(let defaults), .virtualOutput(let defaults),
      .outputAudio(let defaults), .virtualInput(let defaults):
      defaults.enabledCount
    case .visualizer(let defaults): defaults.enabledCount
    case .audioMixer(let defaults): defaults.enabledCount
    case .gain(let defaults): defaults.enabledCount
    case .channelRouter(let defaults): defaults.enabledCount
    case .signalGenerator(let defaults): defaults.enabledCount
    case .filePlayback(let defaults): defaults.enabledCount
    case .fileOutput(let defaults): defaults.enabledCount
    case .networkSend(let defaults): defaults.enabledCount
    case .networkReceive(let defaults): defaults.enabledCount
    case .delay(let defaults): defaults.enabledCount
    case .noiseGate(let defaults): defaults.enabledCount
    case .compressor(let defaults): defaults.enabledCount
    }
  }

  var isEmpty: Bool { enabledCount == 0 }

  func applying(to value: RoutingNodeValue) -> RoutingNodeValue {
    switch (self, value) {
    case (.applicationAudio(let defaults), .applicationAudio(let selection, let presentation)):
      .applicationAudio(
        selection: selection,
        channelPresentation: defaults.channelPresentation ?? presentation
      )
    case (.inputAudio(let defaults), .inputAudio(let selection, let presentation)):
      .inputAudio(
        selection: selection,
        channelPresentation: defaults.channelPresentation ?? presentation
      )
    case (.systemOutput(let defaults), .systemOutput(let selection, let presentation)):
      .systemOutput(
        selection: selection,
        channelPresentation: defaults.channelPresentation ?? presentation
      )
    case (.virtualOutput(let defaults), .virtualOutput(let selection, let presentation)):
      .virtualOutput(
        selection: selection,
        channelPresentation: defaults.channelPresentation ?? presentation
      )
    case (.outputAudio(let defaults), .outputAudio(let selection, let presentation)):
      .outputAudio(
        selection: selection,
        channelPresentation: defaults.channelPresentation ?? presentation
      )
    case (.virtualInput(let defaults), .virtualInput(let selection, let presentation)):
      .virtualInput(
        selection: selection,
        channelPresentation: defaults.channelPresentation ?? presentation
      )
    case (.visualizer(let defaults), .visualizer(let configuration)):
      .visualizer(configuration: defaults.applying(to: configuration))
    case (.audioMixer(let defaults), .audioMixer(let configuration)):
      .audioMixer(configuration: defaults.applying(to: configuration))
    case (.gain(let defaults), .gain(let configuration)):
      .gain(configuration: defaults.applying(to: configuration))
    case (.channelRouter(let defaults), .channelRouter(let configuration)):
      .channelRouter(configuration: defaults.applying(to: configuration))
    case (.signalGenerator(let defaults), .signalGenerator(let configuration)):
      .signalGenerator(configuration: defaults.applying(to: configuration))
    case (.filePlayback(let defaults), .filePlayback(let configuration)):
      .filePlayback(configuration: defaults.applying(to: configuration))
    case (.fileOutput(let defaults), .fileOutput(let configuration)):
      .fileOutput(configuration: defaults.applying(to: configuration))
    case (.networkSend(let defaults), .networkSend(let configuration)):
      .networkSend(configuration: defaults.applying(to: configuration))
    case (.networkReceive(let defaults), .networkReceive(let configuration)):
      .networkReceive(configuration: defaults.applying(to: configuration))
    case (.delay(let defaults), .delay(let configuration)):
      .delay(configuration: defaults.applying(to: configuration))
    case (.noiseGate(let defaults), .noiseGate(let configuration)):
      .noiseGate(configuration: defaults.applying(to: configuration))
    case (.compressor(let defaults), .compressor(let configuration)):
      .compressor(configuration: defaults.applying(to: configuration))
    default:
      value
    }
  }
}
