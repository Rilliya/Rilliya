import FlowingDayControls
import FlowingDayPreferences
import RilliyaDSP
import RilliyaFileWriting
import SwiftUI

enum RilliyaNodeDefaultsCategory: String, CaseIterable, Hashable {
  case sources
  case destinations
  case routing
  case measurement
  case processing

  var title: String {
    switch self {
    case .sources: "Sources"
    case .destinations: "Destinations"
    case .routing: "Routing & Level"
    case .measurement: "Measurement"
    case .processing: "Dynamics & Effects"
    }
  }

  private var kinds: [RoutingNodeKind] {
    switch self {
    case .sources:
      [
        .applicationAudio,
        .inputAudio,
        .systemOutput,
        .virtualOutput,
        .signalGenerator,
        .filePlayback,
        .networkReceive,
      ]
    case .destinations:
      [.outputAudio, .virtualInput, .fileOutput, .networkSend]
    case .routing:
      [.audioMixer, .gain, .channelRouter]
    case .measurement:
      [.visualizer]
    case .processing:
      [.delay, .noiseGate, .compressor]
    }
  }

  func kinds(matching searchText: String) -> [RoutingNodeKind] {
    let terms =
      searchText
      .split(whereSeparator: \Character.isWhitespace)
      .map { $0.lowercased() }
    guard !terms.isEmpty else { return kinds }
    return kinds.filter { kind in
      let searchableText = ([kind.title] + kind.parameterSearchTerms)
        .joined(separator: " ")
        .lowercased()
      return terms.allSatisfy(searchableText.contains)
    }
  }
}

extension RoutingNodeKind {
  fileprivate var parameterSearchTerms: [String] {
    switch self {
    case .applicationAudio, .inputAudio, .systemOutput, .virtualOutput, .outputAudio,
      .virtualInput:
      ["port presentation channels aggregate separate"]
    case .visualizer:
      ["input display output mode waveform channel set mixed output"]
    case .audioMixer:
      ["channel layout mixer"]
    case .gain:
      ["level decibels mute polarity invert"]
    case .channelRouter:
      ["routing map inputs outputs channels silence"]
    case .signalGenerator:
      ["waveform frequency amplitude tone noise"]
    case .filePlayback:
      ["loop repeat playback count"]
    case .fileOutput:
      ["file format container encoding sample rate channels"]
    case .networkSend:
      ["wire format bit rate sample rate channels opus aac"]
    case .networkReceive:
      ["sender format sample rate channels buffer jitter delay catch-up correction"]
    case .delay:
      ["delay time feedback dry wet mix"]
    case .noiseGate:
      ["threshold hysteresis attack hold release reduction"]
    case .compressor:
      ["threshold ratio knee attack release makeup gain"]
    case .peakLevel:
      []
    }
  }
}

struct RilliyaNodeDefaultsRows: View {
  @Bindable var settings: RilliyaSettings
  @Binding var expandedKind: RoutingNodeKind?
  let kinds: [RoutingNodeKind]

  var body: some View {
    if kinds.isEmpty {
      PreferencesEmptyRow(
        "No nodes or parameters match this search.",
        symbol: "magnifyingglass"
      )
    } else {
      ForEach(kinds, id: \.self) { kind in
        if kind == .networkSend {
          RilliyaNetworkSendDefaultsRow(
            settings: settings,
            isExpanded: expansion(for: kind)
          )
        } else {
          RilliyaNodeDefaultsRow(
            kind: kind,
            settings: settings,
            isExpanded: expansion(for: kind)
          )
        }
      }
    }
  }

  private func expansion(for kind: RoutingNodeKind) -> Binding<Bool> {
    Binding(
      get: { expandedKind == kind },
      set: { expandedKind = $0 ? kind : nil }
    )
  }
}

private struct RilliyaNodeDefaultsRow: View {
  let kind: RoutingNodeKind
  @Bindable var settings: RilliyaSettings
  @Binding var isExpanded: Bool

  var body: some View {
    VStack(spacing: 0) {
      PreferencesExpandableRow(
        symbol: kind.systemImage,
        title: kind.title,
        caption: enabledDescription,
        isExpanded: $isExpanded
      )
      PreferencesDependentRows(isVisible: isExpanded, showsSeparator: false) {
        controls
      }
    }
  }

  private var enabledDescription: String {
    let count = settings.parameterDefaults(for: kind)?.enabledCount ?? 0
    return count == 0 ? "Use Rilliya defaults" : "\(count) custom default\(count == 1 ? "" : "s")"
  }

  @ViewBuilder
  private var controls: some View {
    switch kind {
    case .applicationAudio, .inputAudio, .systemOutput, .virtualOutput, .outputAudio,
      .virtualInput:
      channelPresentationControls
    case .visualizer:
      visualizerControls
    case .audioMixer:
      audioMixerControls
    case .gain:
      gainControls
    case .channelRouter:
      channelRouterControls
    case .signalGenerator:
      signalGeneratorControls
    case .filePlayback:
      filePlaybackControls
    case .fileOutput:
      fileOutputControls
    case .networkReceive:
      networkReceiveControls
    case .delay:
      delayControls
    case .noiseGate:
      noiseGateControls
    case .compressor:
      compressorControls
    case .networkSend, .peakLevel:
      EmptyView()
    }
  }

  private var channelPresentationControls: some View {
    RilliyaDefaultParameter(
      title: "Port presentation",
      caption: "Choose how a new node exposes its audio channels.",
      value: channelDefaults.channelPresentation,
      fallback: .aggregate,
      update: { value in editChannelDefaults { $0.channelPresentation = value } },
      control: { selection in
        PreferencesPopupRow(
          symbol: "point.3.connected.trianglepath.dotted",
          title: "Presentation",
          caption: "Keep all channels together or expose a fixed number separately.",
          minimumControlWidth: 170,
          selection: selection,
          options: Self.channelPresentationOptions
        )
      }
    )
  }

  private var visualizerControls: some View {
    VStack(spacing: 0) {
      RilliyaDefaultParameter(
        title: "Input mode",
        caption: "Choose one cable or one cable per channel.",
        value: visualizerDefaults.inputMode,
        fallback: RoutingVisualizerConfiguration.initial.inputMode,
        update: { value in editVisualizerDefaults { $0.inputMode = value } }
      ) { selection in
        modePopup(title: "Input", selection: selection)
      }
      parameterSeparator
      RilliyaDefaultParameter(
        title: "Display mode",
        caption: "Choose a mixed waveform or separate lanes.",
        value: visualizerDefaults.displayMode,
        fallback: RoutingVisualizerConfiguration.initial.displayMode,
        update: { value in editVisualizerDefaults { $0.displayMode = value } }
      ) { selection in
        modePopup(title: "Display", selection: selection)
      }
      parameterSeparator
      RilliyaDefaultParameter(
        title: "Output mode",
        caption: "Choose one cable or one cable per channel.",
        value: visualizerDefaults.outputMode,
        fallback: RoutingVisualizerConfiguration.initial.outputMode,
        update: { value in editVisualizerDefaults { $0.outputMode = value } }
      ) { selection in
        modePopup(title: "Output", selection: selection)
      }
      parameterSeparator
      RilliyaDefaultParameter(
        title: "Channel set",
        caption: "Choose the channels shown by separate lanes.",
        value: visualizerDefaults.channelSelection,
        fallback: RoutingVisualizerConfiguration.initial.channelSelection,
        update: { value in editVisualizerDefaults { $0.channelSelection = value } }
      ) { selection in
        PreferencesPopupRow(
          symbol: "waveform",
          title: "Channels",
          caption: "The selected layout becomes the preview for a new visualizer.",
          minimumControlWidth: 160,
          selection: selection,
          options: RoutingVisualizerChannelPreset.allCases.map { preset in
            FlowingSelectOption(
              RoutingVisualizerChannelSelection.preset(preset),
              label: Self.channelPresetLabel(preset)
            )
          }
        )
      }
      parameterSeparator
      booleanParameter(
        title: "Mixed output",
        caption: "Add the normalized mono convenience output.",
        value: visualizerDefaults.includesMixedOutput,
        fallback: RoutingVisualizerConfiguration.initial.includesMixedOutput,
        update: { value in editVisualizerDefaults { $0.includesMixedOutput = value } }
      )
    }
  }

  private var audioMixerControls: some View {
    RilliyaDefaultParameter(
      title: "Channel layout",
      caption: "Choose the number of mixer inputs and output channels.",
      value: audioMixerDefaults.channelCount,
      fallback: RoutingAudioMixerConfiguration.initial.channelCount,
      update: { value in editAudioMixerDefaults { $0.channelCount = value } },
      control: { selection in
        PreferencesPopupRow(
          symbol: "slider.horizontal.3",
          title: "Channels",
          caption: "New mixers start with this channel layout.",
          minimumControlWidth: 150,
          selection: selection,
          options: [1, 2, 4, 6, 8].map {
            FlowingSelectOption($0, label: Self.channelCountLabel($0))
          }
        )
      }
    )
  }

  private var gainControls: some View {
    VStack(spacing: 0) {
      RilliyaDefaultParameter(
        title: "Level",
        caption: "Choose the starting gain in decibels.",
        value: gainDefaults.gainDecibels,
        fallback: RoutingGainConfiguration.initial.gainDecibels,
        update: { value in editGainDefaults { $0.gainDecibels = value } }
      ) { value in
        PreferencesSliderRow(
          symbol: "speaker.wave.2",
          title: "Gain",
          value: value,
          in: RoutingGainConfiguration
            .minimumGainDecibels...RoutingGainConfiguration.maximumGainDecibels,
          step: 0.5,
          format: Self.decibelLabel
        )
      }
      parameterSeparator
      booleanParameter(
        title: "Mute",
        caption: "Choose whether a new Gain node starts muted.",
        value: gainDefaults.isMuted,
        fallback: RoutingGainConfiguration.initial.isMuted,
        update: { value in editGainDefaults { $0.isMuted = value } }
      )
      parameterSeparator
      booleanParameter(
        title: "Polarity",
        caption: "Choose whether a new Gain node starts inverted.",
        value: gainDefaults.isPolarityInverted,
        fallback: RoutingGainConfiguration.initial.isPolarityInverted,
        trueLabel: "Inverted",
        falseLabel: "Normal",
        update: { value in editGainDefaults { $0.isPolarityInverted = value } }
      )
    }
  }

  private var channelRouterControls: some View {
    RilliyaDefaultParameter(
      title: "Routing map",
      caption: "Store channel counts and every output mapping as one consistent default.",
      value: channelRouterDefaults.routing,
      fallback: RoutingChannelRouterConfiguration.initial,
      update: { value in editChannelRouterDefaults { $0.routing = value } },
      control: { configuration in
        RilliyaChannelRouterDefaultControls(configuration: configuration)
      }
    )
  }

  private var signalGeneratorControls: some View {
    VStack(spacing: 0) {
      RilliyaDefaultParameter(
        title: "Waveform",
        caption: "Choose the source shape for a new generator.",
        value: signalGeneratorDefaults.waveform,
        fallback: RoutingSignalGeneratorConfiguration.initial.waveform,
        update: { value in editSignalGeneratorDefaults { $0.waveform = value } }
      ) { selection in
        PreferencesPopupRow(
          symbol: "waveform.path",
          title: "Waveform",
          minimumControlWidth: 150,
          selection: selection,
          options: AudioSignalGeneratorWaveform.allCases.map {
            FlowingSelectOption($0, label: $0.displayName)
          }
        )
      }
      parameterSeparator
      RilliyaDefaultParameter(
        title: "Frequency",
        caption: "Choose the starting tone frequency.",
        value: signalGeneratorDefaults.frequency,
        fallback: RoutingSignalGeneratorConfiguration.initial.frequency,
        update: { value in editSignalGeneratorDefaults { $0.frequency = value } }
      ) { value in
        PreferencesSliderRow(
          symbol: "tuningfork",
          title: "Frequency",
          value: Self.logarithmicFrequency(value),
          in: 0...1,
          format: { _ in "\(Int(value.wrappedValue.rounded())) Hz" }
        )
      }
      parameterSeparator
      RilliyaDefaultParameter(
        title: "Amplitude",
        caption: "Choose the starting full-scale amplitude.",
        value: signalGeneratorDefaults.amplitude,
        fallback: RoutingSignalGeneratorConfiguration.initial.amplitude,
        update: { value in editSignalGeneratorDefaults { $0.amplitude = value } }
      ) { value in
        PreferencesSliderRow(
          symbol: "speaker.wave.2",
          title: "Amplitude",
          value: Self.double(value),
          in: 0...1,
          step: 0.01,
          format: Self.percentLabel
        )
      }
    }
  }

  private var filePlaybackControls: some View {
    RilliyaDefaultParameter(
      title: "Looping",
      caption: "Choose how many times a newly selected file plays.",
      value: filePlaybackDefaults.loopMode,
      fallback: RoutingFilePlaybackConfiguration.initial.loopMode,
      update: { value in editFilePlaybackDefaults { $0.loopMode = value } },
      control: { selection in
        PreferencesPopupRow(
          symbol: "repeat",
          title: "Playback",
          caption: "The file itself remains unselected until you choose it on the node.",
          minimumControlWidth: 160,
          selection: selection,
          options: Self.loopModeOptions.map {
            FlowingSelectOption($0, label: $0.description)
          }
        )
      }
    )
  }

  private var fileOutputControls: some View {
    VStack(spacing: 0) {
      RilliyaDefaultParameter(
        title: "File format",
        caption: "Store the container and its compatible encoding together.",
        value: fileOutputDefaults.format,
        fallback: RoutingFileOutputFormatDefault(
          container: RoutingFileOutputConfiguration.initial.container,
          encoding: RoutingFileOutputConfiguration.initial.encoding
        ),
        update: { value in editFileOutputDefaults { $0.format = value } }
      ) { selection in
        PreferencesPopupRow(
          symbol: "waveform",
          title: "Format",
          caption: "The destination remains unselected until you choose it on the node.",
          minimumControlWidth: 180,
          selection: selection,
          options: Self.fileOutputFormatOptions.map {
            FlowingSelectOption($0, label: Self.fileOutputFormatLabel($0))
          }
        )
      }
      parameterSeparator
      RilliyaDefaultParameter(
        title: "Sample rate",
        caption: "Choose the rate requested by a new file output.",
        value: fileOutputDefaults.sampleRate,
        fallback: RoutingFileOutputConfiguration.initial.sampleRate,
        update: { value in editFileOutputDefaults { $0.sampleRate = value } }
      ) { selection in
        PreferencesPopupRow(
          symbol: "waveform.path.ecg",
          title: "Rate",
          minimumControlWidth: 150,
          selection: selection,
          options: RoutingFileOutputConfiguration.commonSampleRates.map {
            FlowingSelectOption($0, label: Self.sampleRateLabel($0))
          }
        )
      }
      parameterSeparator
      RilliyaDefaultParameter(
        title: "Channels",
        caption: "Choose the channel count requested by a new file output.",
        value: fileOutputDefaults.channelCount,
        fallback: RoutingFileOutputConfiguration.initial.channelCount,
        update: { value in editFileOutputDefaults { $0.channelCount = value } }
      ) { value in
        PreferencesSliderRow(
          symbol: "speaker.wave.2",
          title: "Channels",
          value: Self.double(value),
          in: 1...Double(RoutingFileOutputConfiguration.maximumEditableChannelCount),
          step: 1,
          format: { "\(Int($0.rounded())) ch" }
        )
      }
    }
  }

  private var networkReceiveControls: some View {
    VStack(spacing: 0) {
      booleanParameter(
        title: "Sender format",
        caption: "Choose whether a new receiver learns its format automatically.",
        value: networkReceiveDefaults.adoptsSenderFormat,
        fallback: RoutingNetworkReceiveConfiguration.initial.adoptsSenderFormat,
        trueLabel: "Automatic",
        falseLabel: "Manual",
        update: { value in editNetworkReceiveDefaults { $0.adoptsSenderFormat = value } }
      )
      parameterSeparator
      RilliyaDefaultParameter(
        title: "Sample rate",
        caption: "Choose the manual rate or automatic fallback.",
        value: networkReceiveDefaults.sampleRate,
        fallback: RoutingNetworkReceiveConfiguration.initial.sampleRate,
        update: { value in editNetworkReceiveDefaults { $0.sampleRate = value } }
      ) { selection in
        PreferencesPopupRow(
          symbol: "waveform.path.ecg",
          title: "Rate",
          minimumControlWidth: 150,
          selection: selection,
          options: [44_100.0, 48_000.0, 96_000.0].map {
            FlowingSelectOption($0, label: Self.sampleRateLabel($0))
          }
        )
      }
      parameterSeparator
      RilliyaDefaultParameter(
        title: "Channels",
        caption: "Choose the manual channel count or automatic fallback.",
        value: networkReceiveDefaults.channelCount,
        fallback: RoutingNetworkReceiveConfiguration.initial.channelCount,
        update: { value in editNetworkReceiveDefaults { $0.channelCount = value } }
      ) { selection in
        PreferencesPopupRow(
          symbol: "speaker.wave.2",
          title: "Channels",
          minimumControlWidth: 150,
          selection: selection,
          options: [1, 2, 4, 6, 8].map {
            FlowingSelectOption($0, label: "\($0) ch")
          }
        )
      }
      parameterSeparator
      RilliyaDefaultParameter(
        title: "Buffer target",
        caption: "Choose how long a new receiver waits before playback.",
        value: networkReceiveDefaults.jitterTargetMilliseconds,
        fallback: RoutingNetworkJitterControls.initial.targetMilliseconds,
        update: { value in editNetworkReceiveDefaults { $0.jitterTargetMilliseconds = value } }
      ) { value in
        PreferencesSliderRow(
          symbol: "timer",
          title: "Target delay",
          value: Self.double(value),
          in: Double(
            RoutingNetworkJitterControls.minimumTargetMilliseconds)...Double(
              RoutingNetworkJitterControls.maximumTargetMilliseconds),
          step: 1,
          format: { "\(Int($0.rounded())) ms" }
        )
      }
      parameterSeparator
      RilliyaDefaultParameter(
        title: "Catch-up method",
        caption: "Choose how a new receiver shortens a long queue.",
        value: networkReceiveDefaults.jitterCorrection,
        fallback: RoutingNetworkJitterControls.initial.correction,
        update: { value in editNetworkReceiveDefaults { $0.jitterCorrection = value } }
      ) { selection in
        PreferencesPopupRow(
          symbol: "forward.end",
          title: "Correction",
          minimumControlWidth: 150,
          selection: selection,
          options: RoutingNetworkJitterCorrection.allCases.map {
            FlowingSelectOption($0, label: $0.displayName)
          }
        )
      }
    }
  }

  private var delayControls: some View {
    VStack(spacing: 0) {
      RilliyaDefaultParameter(
        title: "Delay time",
        caption: "Choose the starting delay interval.",
        value: delayDefaults.delaySeconds,
        fallback: RoutingDelayConfiguration.initial.delaySeconds,
        update: { value in editDelayDefaults { $0.delaySeconds = value } }
      ) { value in
        PreferencesSliderRow(
          symbol: "clock",
          title: "Delay",
          value: value,
          in: RoutingDelayConfiguration
            .minimumDelaySeconds...RoutingDelayConfiguration.maximumDelaySeconds,
          step: 0.001,
          format: Self.secondsLabel
        )
      }
      parameterSeparator
      RilliyaDefaultParameter(
        title: "Feedback",
        caption: "Choose how much delayed signal returns to the input.",
        value: delayDefaults.feedback,
        fallback: RoutingDelayConfiguration.initial.feedback,
        update: { value in editDelayDefaults { $0.feedback = value } }
      ) { value in
        PreferencesSliderRow(
          symbol: "arrow.trianglehead.2.clockwise.rotate.90",
          title: "Feedback",
          value: Self.double(value),
          in: -Double(
            RoutingDelayConfiguration.maximumFeedback)...Double(
              RoutingDelayConfiguration.maximumFeedback),
          step: 0.01,
          format: Self.signedPercentLabel
        )
      }
      parameterSeparator
      RilliyaDefaultParameter(
        title: "Dry/wet mix",
        caption: "Choose the balance between direct and delayed audio.",
        value: delayDefaults.dryWetMix,
        fallback: RoutingDelayConfiguration.initial.dryWetMix,
        update: { value in editDelayDefaults { $0.dryWetMix = value } }
      ) { value in
        PreferencesSliderRow(
          symbol: "circle.lefthalf.filled",
          title: "Mix",
          value: Self.double(value),
          in: 0...1,
          step: 0.01,
          format: Self.percentLabel
        )
      }
    }
  }

  private var noiseGateControls: some View {
    VStack(spacing: 0) {
      floatSliderParameter(
        title: "Threshold",
        caption: "Choose the level where a new gate opens.",
        value: noiseGateDefaults.thresholdDecibels,
        fallback: RoutingNoiseGateConfiguration.initial.thresholdDecibels,
        range: Double(
          RoutingNoiseGateConfiguration.minimumThresholdDecibels)...Double(
            RoutingNoiseGateConfiguration.maximumThresholdDecibels),
        step: 0.5,
        format: Self.decibelLabel,
        update: { value in editNoiseGateDefaults { $0.thresholdDecibels = value } }
      )
      parameterSeparator
      floatSliderParameter(
        title: "Hysteresis",
        caption: "Choose the separation between opening and closing levels.",
        value: noiseGateDefaults.hysteresisDecibels,
        fallback: RoutingNoiseGateConfiguration.initial.hysteresisDecibels,
        range: 0...Double(RoutingNoiseGateConfiguration.maximumHysteresisDecibels),
        step: 0.5,
        format: Self.unsignedDecibelLabel,
        update: { value in editNoiseGateDefaults { $0.hysteresisDecibels = value } }
      )
      parameterSeparator
      doubleSliderParameter(
        title: "Attack",
        caption: "Choose how quickly a new gate opens.",
        value: noiseGateDefaults.attackSeconds,
        fallback: RoutingNoiseGateConfiguration.initial.attackSeconds,
        range: 0...RoutingNoiseGateConfiguration.maximumAttackSeconds,
        step: 0.001,
        format: Self.secondsLabel,
        update: { value in editNoiseGateDefaults { $0.attackSeconds = value } }
      )
      parameterSeparator
      doubleSliderParameter(
        title: "Hold",
        caption: "Choose how long a new gate stays open.",
        value: noiseGateDefaults.holdSeconds,
        fallback: RoutingNoiseGateConfiguration.initial.holdSeconds,
        range: 0...RoutingNoiseGateConfiguration.maximumHoldSeconds,
        step: 0.001,
        format: Self.secondsLabel,
        update: { value in editNoiseGateDefaults { $0.holdSeconds = value } }
      )
      parameterSeparator
      doubleSliderParameter(
        title: "Release",
        caption: "Choose how quickly a new gate closes.",
        value: noiseGateDefaults.releaseSeconds,
        fallback: RoutingNoiseGateConfiguration.initial.releaseSeconds,
        range: 0...RoutingNoiseGateConfiguration.maximumReleaseSeconds,
        step: 0.001,
        format: Self.secondsLabel,
        update: { value in editNoiseGateDefaults { $0.releaseSeconds = value } }
      )
      parameterSeparator
      floatSliderParameter(
        title: "Reduction",
        caption: "Choose how much a closed gate attenuates.",
        value: noiseGateDefaults.reductionDecibels,
        fallback: RoutingNoiseGateConfiguration.initial.reductionDecibels,
        range: 0...Double(RoutingNoiseGateConfiguration.maximumReductionDecibels),
        step: 0.5,
        format: Self.unsignedDecibelLabel,
        update: { value in editNoiseGateDefaults { $0.reductionDecibels = value } }
      )
    }
  }

  private var compressorControls: some View {
    VStack(spacing: 0) {
      floatSliderParameter(
        title: "Threshold",
        caption: "Choose the level where compression begins.",
        value: compressorDefaults.thresholdDecibels,
        fallback: RoutingCompressorConfiguration.initial.thresholdDecibels,
        range: Double(
          RoutingCompressorConfiguration.minimumThresholdDecibels)...Double(
            RoutingCompressorConfiguration.maximumThresholdDecibels),
        step: 0.5,
        format: Self.decibelLabel,
        update: { value in editCompressorDefaults { $0.thresholdDecibels = value } }
      )
      parameterSeparator
      floatSliderParameter(
        title: "Ratio",
        caption: "Choose how strongly levels above the threshold are reduced.",
        value: compressorDefaults.ratio,
        fallback: RoutingCompressorConfiguration.initial.ratio,
        range: Double(
          RoutingCompressorConfiguration.minimumRatio)...Double(
            RoutingCompressorConfiguration.maximumRatio),
        step: 0.5,
        format: { String(format: "%.1f:1", $0) },
        update: { value in editCompressorDefaults { $0.ratio = value } }
      )
      parameterSeparator
      floatSliderParameter(
        title: "Knee",
        caption: "Choose how gradually compression reaches its ratio.",
        value: compressorDefaults.kneeDecibels,
        fallback: RoutingCompressorConfiguration.initial.kneeDecibels,
        range: 0...Double(RoutingCompressorConfiguration.maximumKneeDecibels),
        step: 0.5,
        format: Self.unsignedDecibelLabel,
        update: { value in editCompressorDefaults { $0.kneeDecibels = value } }
      )
      parameterSeparator
      doubleSliderParameter(
        title: "Attack",
        caption: "Choose how quickly compression engages.",
        value: compressorDefaults.attackSeconds,
        fallback: RoutingCompressorConfiguration.initial.attackSeconds,
        range: 0...RoutingCompressorConfiguration.maximumAttackSeconds,
        step: 0.001,
        format: Self.secondsLabel,
        update: { value in editCompressorDefaults { $0.attackSeconds = value } }
      )
      parameterSeparator
      doubleSliderParameter(
        title: "Release",
        caption: "Choose how quickly compression relaxes.",
        value: compressorDefaults.releaseSeconds,
        fallback: RoutingCompressorConfiguration.initial.releaseSeconds,
        range: 0...RoutingCompressorConfiguration.maximumReleaseSeconds,
        step: 0.001,
        format: Self.secondsLabel,
        update: { value in editCompressorDefaults { $0.releaseSeconds = value } }
      )
      parameterSeparator
      floatSliderParameter(
        title: "Makeup gain",
        caption: "Choose the level added after compression.",
        value: compressorDefaults.makeupGainDecibels,
        fallback: RoutingCompressorConfiguration.initial.makeupGainDecibels,
        range: Double(
          RoutingCompressorConfiguration.minimumMakeupGainDecibels)...Double(
            RoutingCompressorConfiguration.maximumMakeupGainDecibels),
        step: 0.5,
        format: Self.decibelLabel,
        update: { value in editCompressorDefaults { $0.makeupGainDecibels = value } }
      )
    }
  }

  private var parameterSeparator: some View {
    PreferencesRowSeparator(leadingEdge: .iconText)
  }

  private func modePopup(
    title: String,
    selection: Binding<RoutingVisualizerMode>
  ) -> some View {
    PreferencesPopupRow(
      symbol: "rectangle.split.3x1",
      title: title,
      minimumControlWidth: 150,
      selection: selection,
      options: [
        FlowingSelectOption(.mixed, label: "Together"),
        FlowingSelectOption(.separate, label: "Per channel"),
      ]
    )
  }

  private func booleanParameter(
    title: String,
    caption: String,
    value: Bool?,
    fallback: Bool,
    trueLabel: String = "On",
    falseLabel: String = "Off",
    update: @escaping (Bool?) -> Void
  ) -> some View {
    RilliyaDefaultParameter(
      title: title,
      caption: caption,
      value: value,
      fallback: fallback,
      update: update
    ) { selection in
      PreferencesPopupRow(
        symbol: "switch.2",
        title: "Value",
        minimumControlWidth: 140,
        selection: selection,
        options: [
          FlowingSelectOption(false, label: falseLabel),
          FlowingSelectOption(true, label: trueLabel),
        ]
      )
    }
  }

  private func floatSliderParameter(
    title: String,
    caption: String,
    value: Float?,
    fallback: Float,
    range: ClosedRange<Double>,
    step: Double,
    format: @escaping (Double) -> String,
    update: @escaping (Float?) -> Void
  ) -> some View {
    RilliyaDefaultParameter(
      title: title,
      caption: caption,
      value: value,
      fallback: fallback,
      update: update
    ) { value in
      PreferencesSliderRow(
        symbol: "slider.horizontal.3",
        title: title,
        value: Self.double(value),
        in: range,
        step: step,
        format: format
      )
    }
  }

  private func doubleSliderParameter(
    title: String,
    caption: String,
    value: Double?,
    fallback: Double,
    range: ClosedRange<Double>,
    step: Double,
    format: @escaping (Double) -> String,
    update: @escaping (Double?) -> Void
  ) -> some View {
    RilliyaDefaultParameter(
      title: title,
      caption: caption,
      value: value,
      fallback: fallback,
      update: update
    ) { value in
      PreferencesSliderRow(
        symbol: "slider.horizontal.3",
        title: title,
        value: value,
        in: range,
        step: step,
        format: format
      )
    }
  }

  private var channelDefaults: RoutingChannelPresentationParameterDefaults {
    switch settings.parameterDefaults(for: kind) {
    case .applicationAudio(let defaults), .inputAudio(let defaults),
      .systemOutput(let defaults), .virtualOutput(let defaults),
      .outputAudio(let defaults), .virtualInput(let defaults):
      defaults
    default:
      .empty
    }
  }

  private func editChannelDefaults(
    _ change: (inout RoutingChannelPresentationParameterDefaults) -> Void
  ) {
    var updated = channelDefaults
    change(&updated)
    switch kind {
    case .applicationAudio: settings.setNodeParameterDefaults(.applicationAudio(updated))
    case .inputAudio: settings.setNodeParameterDefaults(.inputAudio(updated))
    case .systemOutput: settings.setNodeParameterDefaults(.systemOutput(updated))
    case .virtualOutput: settings.setNodeParameterDefaults(.virtualOutput(updated))
    case .outputAudio: settings.setNodeParameterDefaults(.outputAudio(updated))
    case .virtualInput: settings.setNodeParameterDefaults(.virtualInput(updated))
    default: break
    }
  }

  private var visualizerDefaults: RoutingVisualizerParameterDefaults {
    guard case .visualizer(let defaults) = settings.parameterDefaults(for: .visualizer) else {
      return .empty
    }
    return defaults
  }

  private func editVisualizerDefaults(
    _ change: (inout RoutingVisualizerParameterDefaults) -> Void
  ) {
    var updated = visualizerDefaults
    change(&updated)
    settings.setNodeParameterDefaults(.visualizer(updated))
  }

  private var audioMixerDefaults: RoutingAudioMixerParameterDefaults {
    guard case .audioMixer(let defaults) = settings.parameterDefaults(for: .audioMixer) else {
      return .empty
    }
    return defaults
  }

  private func editAudioMixerDefaults(
    _ change: (inout RoutingAudioMixerParameterDefaults) -> Void
  ) {
    var updated = audioMixerDefaults
    change(&updated)
    settings.setNodeParameterDefaults(.audioMixer(updated))
  }

  private var gainDefaults: RoutingGainParameterDefaults {
    guard case .gain(let defaults) = settings.parameterDefaults(for: .gain) else { return .empty }
    return defaults
  }

  private func editGainDefaults(_ change: (inout RoutingGainParameterDefaults) -> Void) {
    var updated = gainDefaults
    change(&updated)
    settings.setNodeParameterDefaults(.gain(updated))
  }

  private var channelRouterDefaults: RoutingChannelRouterParameterDefaults {
    guard case .channelRouter(let defaults) = settings.parameterDefaults(for: .channelRouter) else {
      return .empty
    }
    return defaults
  }

  private func editChannelRouterDefaults(
    _ change: (inout RoutingChannelRouterParameterDefaults) -> Void
  ) {
    var updated = channelRouterDefaults
    change(&updated)
    settings.setNodeParameterDefaults(.channelRouter(updated))
  }

  private var signalGeneratorDefaults: RoutingSignalGeneratorParameterDefaults {
    guard case .signalGenerator(let defaults) = settings.parameterDefaults(for: .signalGenerator)
    else { return .empty }
    return defaults
  }

  private func editSignalGeneratorDefaults(
    _ change: (inout RoutingSignalGeneratorParameterDefaults) -> Void
  ) {
    var updated = signalGeneratorDefaults
    change(&updated)
    settings.setNodeParameterDefaults(.signalGenerator(updated))
  }

  private var filePlaybackDefaults: RoutingFilePlaybackParameterDefaults {
    guard case .filePlayback(let defaults) = settings.parameterDefaults(for: .filePlayback) else {
      return .empty
    }
    return defaults
  }

  private func editFilePlaybackDefaults(
    _ change: (inout RoutingFilePlaybackParameterDefaults) -> Void
  ) {
    var updated = filePlaybackDefaults
    change(&updated)
    settings.setNodeParameterDefaults(.filePlayback(updated))
  }

  private var fileOutputDefaults: RoutingFileOutputParameterDefaults {
    guard case .fileOutput(let defaults) = settings.parameterDefaults(for: .fileOutput) else {
      return .empty
    }
    return defaults
  }

  private func editFileOutputDefaults(
    _ change: (inout RoutingFileOutputParameterDefaults) -> Void
  ) {
    var updated = fileOutputDefaults
    change(&updated)
    settings.setNodeParameterDefaults(.fileOutput(updated))
  }

  private var networkReceiveDefaults: RoutingNetworkReceiveParameterDefaults {
    guard case .networkReceive(let defaults) = settings.parameterDefaults(for: .networkReceive)
    else { return .empty }
    return defaults
  }

  private func editNetworkReceiveDefaults(
    _ change: (inout RoutingNetworkReceiveParameterDefaults) -> Void
  ) {
    var updated = networkReceiveDefaults
    change(&updated)
    settings.setNodeParameterDefaults(.networkReceive(updated))
  }

  private var delayDefaults: RoutingDelayParameterDefaults {
    guard case .delay(let defaults) = settings.parameterDefaults(for: .delay) else { return .empty }
    return defaults
  }

  private func editDelayDefaults(_ change: (inout RoutingDelayParameterDefaults) -> Void) {
    var updated = delayDefaults
    change(&updated)
    settings.setNodeParameterDefaults(.delay(updated))
  }

  private var noiseGateDefaults: RoutingNoiseGateParameterDefaults {
    guard case .noiseGate(let defaults) = settings.parameterDefaults(for: .noiseGate) else {
      return .empty
    }
    return defaults
  }

  private func editNoiseGateDefaults(
    _ change: (inout RoutingNoiseGateParameterDefaults) -> Void
  ) {
    var updated = noiseGateDefaults
    change(&updated)
    settings.setNodeParameterDefaults(.noiseGate(updated))
  }

  private var compressorDefaults: RoutingCompressorParameterDefaults {
    guard case .compressor(let defaults) = settings.parameterDefaults(for: .compressor) else {
      return .empty
    }
    return defaults
  }

  private func editCompressorDefaults(
    _ change: (inout RoutingCompressorParameterDefaults) -> Void
  ) {
    var updated = compressorDefaults
    change(&updated)
    settings.setNodeParameterDefaults(.compressor(updated))
  }

  private static let channelPresentationOptions: [FlowingSelectOption<RoutingChannelPresentation>] =
    [
      FlowingSelectOption(.aggregate, label: "All Channels"),
      FlowingSelectOption(.separate(channelCount: 1), label: "Separate · Mono"),
      FlowingSelectOption(.separate(channelCount: 2), label: "Separate · Stereo"),
      FlowingSelectOption(.separate(channelCount: 4), label: "Separate · Quad"),
      FlowingSelectOption(.separate(channelCount: 6), label: "Separate · 5.1"),
      FlowingSelectOption(.separate(channelCount: 8), label: "Separate · 7.1"),
    ]

  private static let loopModeOptions: [RoutingFilePlaybackLoopMode] = [
    .once,
    .playCount(2),
    .playCount(3),
    .playCount(5),
    .playCount(10),
    .playCount(100),
    .infinite,
  ]

  private static let fileOutputFormatOptions: [RoutingFileOutputFormatDefault] = [
    RoutingFileOutputFormatDefault(container: .wave, encoding: .integerPCM(bitDepth: 16)),
    RoutingFileOutputFormatDefault(container: .wave, encoding: .integerPCM(bitDepth: 24)),
    RoutingFileOutputFormatDefault(container: .wave, encoding: .float32PCM),
    RoutingFileOutputFormatDefault(container: .aiff, encoding: .integerPCM(bitDepth: 16)),
    RoutingFileOutputFormatDefault(container: .aiff, encoding: .integerPCM(bitDepth: 24)),
    RoutingFileOutputFormatDefault(
      container: .coreAudioFormat,
      encoding: .float32PCM
    ),
    RoutingFileOutputFormatDefault(
      container: .m4a,
      encoding: .aac(bitRate: RoutingFileOutputConfiguration.defaultAACBitRate)
    ),
    RoutingFileOutputFormatDefault(
      container: .m4a,
      encoding: .appleLossless(bitDepth: RoutingFileOutputConfiguration.defaultBitDepth)
    ),
  ]

  private static func channelPresetLabel(_ preset: RoutingVisualizerChannelPreset) -> String {
    channelCountLabel(preset.rawValue)
  }

  private static func channelCountLabel(_ count: Int) -> String {
    switch count {
    case 1: "Mono · 1 ch"
    case 2: "Stereo · 2 ch"
    case 4: "Quad · 4 ch"
    case 6: "5.1 · 6 ch"
    case 8: "7.1 · 8 ch"
    default: "\(count) ch"
    }
  }

  private static func fileOutputFormatLabel(_ format: RoutingFileOutputFormatDefault) -> String {
    "\(format.container.displayName) · \(format.encoding.displayName)"
  }

  private static func sampleRateLabel(_ sampleRate: Double) -> String {
    sampleRate.truncatingRemainder(dividingBy: 1_000) == 0
      ? "\(Int(sampleRate / 1_000)) kHz"
      : String(format: "%.1f kHz", sampleRate / 1_000)
  }

  private static func decibelLabel(_ value: Double) -> String {
    value <= RoutingGainConfiguration.minimumGainDecibels
      ? "−∞ dB"
      : String(format: "%+.1f dB", value)
  }

  private static func unsignedDecibelLabel(_ value: Double) -> String {
    String(format: "%.1f dB", value)
  }

  private static func secondsLabel(_ value: Double) -> String {
    value < 1 ? "\(Int((value * 1_000).rounded())) ms" : String(format: "%.2f s", value)
  }

  private static func percentLabel(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
  }

  private static func signedPercentLabel(_ value: Double) -> String {
    String(format: "%+.0f%%", value * 100)
  }

  private static func double(_ value: Binding<Float>) -> Binding<Double> {
    Binding(
      get: { Double(value.wrappedValue) },
      set: { value.wrappedValue = Float($0) }
    )
  }

  private static func double(_ value: Binding<Int>) -> Binding<Double> {
    Binding(
      get: { Double(value.wrappedValue) },
      set: { value.wrappedValue = Int($0.rounded()) }
    )
  }

  private static func logarithmicFrequency(_ value: Binding<Double>) -> Binding<Double> {
    let minimum = RoutingSignalGeneratorConfiguration.minimumFrequency
    let maximum = RoutingSignalGeneratorConfiguration.maximumFrequency
    let span = log(maximum / minimum)
    return Binding(
      get: { log(value.wrappedValue / minimum) / span },
      set: { value.wrappedValue = minimum * exp(min(max($0, 0), 1) * span) }
    )
  }
}

private struct RilliyaDefaultParameter<Value, Control: View>: View {
  let title: String
  let caption: String
  let value: Value?
  let fallback: Value
  let update: (Value?) -> Void
  let control: (Binding<Value>) -> Control

  init(
    title: String,
    caption: String,
    value: Value?,
    fallback: Value,
    update: @escaping (Value?) -> Void,
    @ViewBuilder control: @escaping (Binding<Value>) -> Control
  ) {
    self.title = title
    self.caption = caption
    self.value = value
    self.fallback = fallback
    self.update = update
    self.control = control
  }

  var body: some View {
    PreferencesSwitchGroup(
      symbol: "arrow.turn.down.right",
      title: title,
      caption: caption,
      isOn: isEnabled
    ) {
      control(valueBinding)
    }
  }

  private var isEnabled: Binding<Bool> {
    Binding(
      get: { value != nil },
      set: { update($0 ? fallback : nil) }
    )
  }

  private var valueBinding: Binding<Value> {
    Binding(
      get: { value ?? fallback },
      set: { update($0) }
    )
  }
}

private struct RilliyaChannelRouterDefaultControls: View {
  @Binding var configuration: RoutingChannelRouterConfiguration

  private let channelCounts = Array(
    RoutingChannelRouterConfiguration
      .minimumChannelCount...RoutingChannelRouterConfiguration.maximumChannelCount
  )

  var body: some View {
    VStack(spacing: 0) {
      PreferencesPopupRow(
        symbol: "arrow.right.to.line",
        title: "Inputs",
        minimumControlWidth: 140,
        selection: inputChannelCount,
        options: channelCounts.map { FlowingSelectOption($0, label: "\($0) ch") }
      )
      PreferencesRowSeparator(leadingEdge: .iconText)
      PreferencesPopupRow(
        symbol: "arrow.left.to.line",
        title: "Outputs",
        minimumControlWidth: 140,
        selection: outputChannelCount,
        options: channelCounts.map { FlowingSelectOption($0, label: "\($0) ch") }
      )
      ForEach(0..<configuration.outputChannelCount, id: \.self) { outputChannel in
        PreferencesRowSeparator(leadingEdge: .iconText)
        PreferencesPopupRow(
          symbol: "arrow.right",
          title: "Output \(outputChannel + 1)",
          minimumControlWidth: 140,
          selection: source(for: outputChannel),
          options: sourceOptions
        )
      }
    }
  }

  private var inputChannelCount: Binding<Int> {
    Binding(
      get: { configuration.inputChannelCount },
      set: {
        configuration = configuration.resized(
          inputChannelCount: $0,
          outputChannelCount: configuration.outputChannelCount
        )
      }
    )
  }

  private var outputChannelCount: Binding<Int> {
    Binding(
      get: { configuration.outputChannelCount },
      set: {
        configuration = configuration.resized(
          inputChannelCount: configuration.inputChannelCount,
          outputChannelCount: $0
        )
      }
    )
  }

  private var sourceOptions: [FlowingSelectOption<Int?>] {
    [FlowingSelectOption(nil, label: "Silence")]
      + (0..<configuration.inputChannelCount).map {
        FlowingSelectOption(Optional($0), label: "Input \($0 + 1)")
      }
  }

  private func source(for outputChannel: Int) -> Binding<Int?> {
    Binding(
      get: { configuration.outputSources[outputChannel] },
      set: { configuration = configuration.routing(sourceChannel: $0, to: outputChannel) }
    )
  }
}
