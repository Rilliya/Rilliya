import Foundation
import Testing

@testable import Rilliya

@Suite("Rilliya settings")
struct RilliyaSettingsTests {
  @Test @MainActor
  func connectionInformationPersistsWithoutUsingDebugTerminology() throws {
    let suiteName = "moe.uwucocoa.rilliya.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = RilliyaSettings(defaults: defaults)
    #expect(first.appearance == .system)
    #expect(first.showsInDock)
    #expect(!first.showsInStatusBar)
    #expect(first.showsWorkflowsInStatusMenu)
    #expect(first.connectionInformationLevel == .format)
    #expect(first.defaultSeparateChannelLayout == .stereo)
    #expect(first.showsMiniMapByDefault)
    #expect(first.showsDisabledPortCrosses)
    #expect(!first.addsNodesOnPaletteClick)
    #expect(first.nodeAccentOverrides.isEmpty)
    #expect(first.networkSendParameterDefaults == .empty)

    first.appearance = .dark
    first.setShowsInStatusBar(true)
    first.setShowsInDock(false)
    first.showsWorkflowsInStatusMenu = false
    first.connectionInformationLevel = .channels
    first.defaultSeparateChannelLayout = .surround71
    first.showsMiniMapByDefault = false
    first.showsDisabledPortCrosses = false
    first.addsNodesOnPaletteClick = true
    first.setNodeAccentOverride(.iris, for: .visualizer)
    first.setNodeAccentOverride(.mint, for: .inputAudio)
    let restored = RilliyaSettings(defaults: defaults)

    #expect(restored.appearance == .dark)
    #expect(!restored.showsInDock)
    #expect(restored.showsInStatusBar)
    #expect(!restored.showsWorkflowsInStatusMenu)
    #expect(restored.connectionInformationLevel == .channels)
    #expect(restored.defaultSeparateChannelLayout == .surround71)
    #expect(!restored.showsMiniMapByDefault)
    #expect(!restored.showsDisabledPortCrosses)
    #expect(restored.addsNodesOnPaletteClick)
    #expect(restored.nodeAccentOverride(for: .visualizer) == .iris)
    #expect(restored.nodeAccentOverride(for: .inputAudio) == .mint)
    #expect(restored.nodeAccentOverride(for: .delay) == nil)
    #expect(restored.resolvedAccentID(for: .delay) == .wisteria)
    #expect(!RoutingConnectionInformationLevel.allCases.map(\.rawValue).contains("debug"))
  }

  @Test @MainActor
  func networkSendParameterDefaultsPersistAndIgnoreUnreadableEntries() throws {
    let suiteName = "moe.uwucocoa.rilliya.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let first = RilliyaSettings(defaults: defaults)
    var parameterDefaults = RoutingNetworkSendParameterDefaults.empty
    parameterDefaults.wireEncoding = .opus
    parameterDefaults.bitRate = 96_000
    parameterDefaults.sampleRate = 48_000
    parameterDefaults.channelCount = 4
    first.setNetworkSendParameterDefaults(parameterDefaults)

    let restored = RilliyaSettings(defaults: defaults)
    #expect(restored.networkSendParameterDefaults == parameterDefaults)

    defaults.set(
      [
        RoutingNodeKind.networkSend.rawValue: try JSONEncoder().encode(parameterDefaults)
      ],
      forKey: "moe.uwucocoa.rilliya.node-parameter-defaults"
    )
    #expect(RilliyaSettings(defaults: defaults).networkSendParameterDefaults == parameterDefaults)

    defaults.set(
      [RoutingNodeKind.networkSend.rawValue: "not encoded defaults"],
      forKey: "moe.uwucocoa.rilliya.node-parameter-defaults"
    )
    #expect(RilliyaSettings(defaults: defaults).networkSendParameterDefaults == .empty)
  }

  @Test @MainActor
  func networkSendNodesUseAndClearParameterDefaults() throws {
    let suiteName = "moe.uwucocoa.rilliya.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = RilliyaSettings(defaults: defaults)
    var parameterDefaults = RoutingNetworkSendParameterDefaults.empty
    parameterDefaults.wireEncoding = .opus
    parameterDefaults.bitRate = 96_000
    parameterDefaults.channelCount = 4
    settings.setNetworkSendParameterDefaults(parameterDefaults)
    let customizedWorkspace = RoutingWorkspaceModel(settings: settings)

    let customizedID = customizedWorkspace.addNetworkSendNode(centeredAt: .zero)
    let customized = try #require(customizedWorkspace.node(id: customizedID))
    guard case .networkSend(let customizedConfiguration) = customized.value else {
      Issue.record("Expected a network send node")
      return
    }
    #expect(customizedConfiguration.wire.encoding == .opus)
    #expect(customizedConfiguration.wire.bitRate == 96_000)
    #expect(customizedConfiguration.channelCount == 4)
    #expect(
      customizedConfiguration.sampleRate == RoutingNetworkSendConfiguration.initial.sampleRate)
    #expect(customizedConfiguration.host == RoutingNetworkSendConfiguration.initial.host)

    settings.setNetworkSendParameterDefaults(.empty)
    let resetWorkspace = RoutingWorkspaceModel(settings: settings)
    let resetID = resetWorkspace.addNetworkSendNode(centeredAt: .zero)
    #expect(
      resetWorkspace.node(id: resetID)?.value
        == .networkSend(configuration: RoutingNetworkSendConfiguration.initial)
    )
  }

  @Test @MainActor
  func parameterDefaultsPersistForEveryConfigurableNodeKind() throws {
    let suiteName = "moe.uwucocoa.rilliya.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let first = RilliyaSettings(defaults: defaults)

    for parameterDefaults in Self.sampleParameterDefaults {
      first.setNodeParameterDefaults(parameterDefaults)
    }

    let restored = RilliyaSettings(defaults: defaults)
    #expect(restored.nodeParameterDefaults.count == Self.sampleParameterDefaults.count)
    for parameterDefaults in Self.sampleParameterDefaults {
      #expect(restored.parameterDefaults(for: parameterDefaults.kind) == parameterDefaults)
    }
  }

  @Test @MainActor
  func everyConfigurableNodeUsesAndClearsSparseParameterDefaults() async throws {
    let suiteName = "moe.uwucocoa.rilliya.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = RilliyaSettings(defaults: defaults)
    for parameterDefaults in Self.sampleParameterDefaults {
      settings.setNodeParameterDefaults(parameterDefaults)
    }

    let directWorkspace = RoutingWorkspaceModel(settings: settings)
    for parameterDefaults in Self.sampleParameterDefaults {
      let nodeID = Self.addDirectNode(of: parameterDefaults.kind, to: directWorkspace)
      let expected = parameterDefaults.applying(to: Self.initialValue(for: parameterDefaults.kind))
      #expect(directWorkspace.node(id: nodeID)?.value == expected)
    }

    let paletteWorkspace = RoutingWorkspaceModel(settings: settings)
    for parameterDefaults in Self.sampleParameterDefaults {
      let nodeID = await paletteWorkspace.addNode(of: parameterDefaults.kind, centeredAt: .zero)
      let expected = parameterDefaults.applying(to: Self.initialValue(for: parameterDefaults.kind))
      #expect(paletteWorkspace.node(id: nodeID)?.value == expected)
    }

    for parameterDefaults in Self.sampleParameterDefaults {
      settings.setNodeParameterDefaults(Self.emptyDefaults(for: parameterDefaults.kind))
    }
    let resetWorkspace = RoutingWorkspaceModel(settings: settings)
    for parameterDefaults in Self.sampleParameterDefaults {
      let nodeID = Self.addDirectNode(of: parameterDefaults.kind, to: resetWorkspace)
      #expect(
        resetWorkspace.node(id: nodeID)?.value == Self.initialValue(for: parameterDefaults.kind))
    }
  }

  @Test @MainActor
  func applicationAlwaysKeepsOnePresentationSurfaceReachable() throws {
    let suiteName = "moe.uwucocoa.rilliya.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = RilliyaSettings(defaults: defaults)

    settings.setShowsInDock(false)
    #expect(!settings.showsInDock)
    #expect(settings.showsInStatusBar)

    settings.setShowsInStatusBar(false)
    #expect(settings.showsInDock)
    #expect(!settings.showsInStatusBar)
  }

  @Test @MainActor
  func resettingAnAccentReturnsToTheBuiltInDefault() throws {
    let suiteName = "moe.uwucocoa.rilliya.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = RilliyaSettings(defaults: defaults)

    settings.setNodeAccentOverride(.fuchsia, for: .signalGenerator)
    #expect(settings.resolvedAccentID(for: .signalGenerator) == .fuchsia)

    settings.setNodeAccentOverride(nil, for: .signalGenerator)
    #expect(settings.nodeAccentOverride(for: .signalGenerator) == nil)
    #expect(settings.resolvedAccentID(for: .signalGenerator) == .poppy)
  }

  private static var sampleParameterDefaults: [RoutingNodeParameterDefaults] {
    var channels = RoutingChannelPresentationParameterDefaults.empty
    channels.channelPresentation = .separate(channelCount: 4)

    var visualizer = RoutingVisualizerParameterDefaults.empty
    visualizer.inputMode = .separate
    visualizer.displayMode = .separate
    visualizer.outputMode = .separate
    visualizer.channelSelection = .preset(.quadraphonic)
    visualizer.includesMixedOutput = true

    var mixer = RoutingAudioMixerParameterDefaults.empty
    mixer.channelCount = 6

    var gain = RoutingGainParameterDefaults.empty
    gain.gainDecibels = -6
    gain.isMuted = true
    gain.isPolarityInverted = true

    var router = RoutingChannelRouterParameterDefaults.empty
    router.routing = RoutingChannelRouterConfiguration.initial.resized(
      inputChannelCount: 4,
      outputChannelCount: 3
    )

    var generator = RoutingSignalGeneratorParameterDefaults.empty
    generator.waveform = .square
    generator.frequency = 880
    generator.amplitude = 0.5

    var playback = RoutingFilePlaybackParameterDefaults.empty
    playback.loopMode = .infinite

    var fileOutput = RoutingFileOutputParameterDefaults.empty
    fileOutput.format = RoutingFileOutputFormatDefault(
      container: .m4a,
      encoding: .aac(bitRate: 128_000)
    )
    fileOutput.sampleRate = 44_100
    fileOutput.channelCount = 4

    var networkSend = RoutingNetworkSendParameterDefaults.empty
    networkSend.wireEncoding = .opus
    networkSend.bitRate = 96_000
    networkSend.sampleRate = 48_000
    networkSend.channelCount = 4

    var networkReceive = RoutingNetworkReceiveParameterDefaults.empty
    networkReceive.sampleRate = 96_000
    networkReceive.channelCount = 6
    networkReceive.adoptsSenderFormat = true
    networkReceive.jitterTargetMilliseconds = 20
    networkReceive.jitterCorrection = .discard

    var delay = RoutingDelayParameterDefaults.empty
    delay.delaySeconds = 0.75
    delay.feedback = 0.5
    delay.dryWetMix = 0.8

    var gate = RoutingNoiseGateParameterDefaults.empty
    gate.thresholdDecibels = -32
    gate.hysteresisDecibels = 4
    gate.attackSeconds = 0.01
    gate.holdSeconds = 0.1
    gate.releaseSeconds = 0.25
    gate.reductionDecibels = 48

    var compressor = RoutingCompressorParameterDefaults.empty
    compressor.thresholdDecibels = -12
    compressor.ratio = 8
    compressor.kneeDecibels = 3
    compressor.attackSeconds = 0.02
    compressor.releaseSeconds = 0.25
    compressor.makeupGainDecibels = 2

    return [
      .applicationAudio(channels),
      .inputAudio(channels),
      .systemOutput(channels),
      .virtualOutput(channels),
      .outputAudio(channels),
      .virtualInput(channels),
      .visualizer(visualizer),
      .audioMixer(mixer),
      .gain(gain),
      .channelRouter(router),
      .signalGenerator(generator),
      .filePlayback(playback),
      .fileOutput(fileOutput),
      .networkSend(networkSend),
      .networkReceive(networkReceive),
      .delay(delay),
      .noiseGate(gate),
      .compressor(compressor),
    ]
  }

  @MainActor
  private static func addDirectNode(
    of kind: RoutingNodeKind,
    to workspace: RoutingWorkspaceModel
  ) -> UUID {
    switch kind {
    case .applicationAudio: workspace.addApplicationAudioNode(centeredAt: .zero)
    case .inputAudio: workspace.addInputAudioNode(centeredAt: .zero)
    case .systemOutput: workspace.addSystemOutputNode(centeredAt: .zero)
    case .virtualOutput: workspace.addVirtualOutputNode(centeredAt: .zero)
    case .outputAudio: workspace.addOutputAudioNode(centeredAt: .zero)
    case .virtualInput: workspace.addVirtualInputNode(centeredAt: .zero)
    case .visualizer: workspace.addVisualizerNode(centeredAt: .zero)
    case .audioMixer: workspace.addAudioMixerNode(centeredAt: .zero)
    case .gain: workspace.addGainNode(centeredAt: .zero)
    case .channelRouter: workspace.addChannelRouterNode(centeredAt: .zero)
    case .peakLevel: workspace.addPeakLevelNode(centeredAt: .zero)
    case .signalGenerator: workspace.addSignalGeneratorNode(centeredAt: .zero)
    case .filePlayback: workspace.addFilePlaybackNode(centeredAt: .zero)
    case .fileOutput: workspace.addFileOutputNode(centeredAt: .zero)
    case .networkSend: workspace.addNetworkSendNode(centeredAt: .zero)
    case .networkReceive: workspace.addNetworkReceiveNode(centeredAt: .zero)
    case .delay: workspace.addDelayNode(centeredAt: .zero)
    case .noiseGate: workspace.addNoiseGateNode(centeredAt: .zero)
    case .compressor: workspace.addCompressorNode(centeredAt: .zero)
    }
  }

  private static func initialValue(for kind: RoutingNodeKind) -> RoutingNodeValue {
    switch kind {
    case .applicationAudio:
      .applicationAudio(selection: nil, channelPresentation: .aggregate)
    case .inputAudio:
      .inputAudio(selection: nil, channelPresentation: .aggregate)
    case .systemOutput:
      .systemOutput(selection: nil, channelPresentation: .aggregate)
    case .virtualOutput:
      .virtualOutput(selection: nil, channelPresentation: .aggregate)
    case .outputAudio:
      .outputAudio(selection: nil, channelPresentation: .aggregate)
    case .virtualInput:
      .virtualInput(selection: nil, channelPresentation: .aggregate)
    case .visualizer: .visualizer(configuration: .initial)
    case .audioMixer: .audioMixer(configuration: .initial)
    case .gain: .gain(configuration: .initial)
    case .channelRouter: .channelRouter(configuration: .initial)
    case .peakLevel: .peakLevel
    case .signalGenerator: .signalGenerator(configuration: .initial)
    case .filePlayback: .filePlayback(configuration: .initial)
    case .fileOutput: .fileOutput(configuration: .initial)
    case .networkSend: .networkSend(configuration: .initial)
    case .networkReceive: .networkReceive(configuration: .initial)
    case .delay: .delay(configuration: .initial)
    case .noiseGate: .noiseGate(configuration: .initial)
    case .compressor: .compressor(configuration: .initial)
    }
  }

  private static func emptyDefaults(for kind: RoutingNodeKind) -> RoutingNodeParameterDefaults {
    switch kind {
    case .applicationAudio: .applicationAudio(.empty)
    case .inputAudio: .inputAudio(.empty)
    case .systemOutput: .systemOutput(.empty)
    case .virtualOutput: .virtualOutput(.empty)
    case .outputAudio: .outputAudio(.empty)
    case .virtualInput: .virtualInput(.empty)
    case .visualizer: .visualizer(.empty)
    case .audioMixer: .audioMixer(.empty)
    case .gain: .gain(.empty)
    case .channelRouter: .channelRouter(.empty)
    case .peakLevel: preconditionFailure("Peak Level has no configurable defaults")
    case .signalGenerator: .signalGenerator(.empty)
    case .filePlayback: .filePlayback(.empty)
    case .fileOutput: .fileOutput(.empty)
    case .networkSend: .networkSend(.empty)
    case .networkReceive: .networkReceive(.empty)
    case .delay: .delay(.empty)
    case .noiseGate: .noiseGate(.empty)
    case .compressor: .compressor(.empty)
    }
  }
}
