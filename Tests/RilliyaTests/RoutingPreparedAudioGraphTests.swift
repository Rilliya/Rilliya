import Foundation
import RilliyaDSP
import RilliyaRealtime
import Testing

@testable import Rilliya

struct RoutingPreparedAudioGraphTests {
  @Test
  func directSourcePreservesPCMAndSilencesUnusedDestinationChannels() throws {
    let sourceID = UUID()
    let outputID = UUID()
    let buffer = try makeFrameBuffer(channelCount: 1)
    try write([[0.25, -0.5, 0.75, -1]], to: buffer)
    let renderer = try makeRenderer(
      nodes: [sourceNode(id: sourceID, channelCount: 1), outputNode(id: outputID)],
      edges: [edge(from: sourceID, .all, to: outputID, .all)],
      outputNodeID: outputID,
      frameBuffers: [sourceID: buffer]
    )

    let rendered = render(renderer, channelCount: 2, frameCount: 4)

    #expect(rendered.result == .rendered)
    #expect(rendered.channels[0] == [0.25, -0.5, 0.75, -1])
    #expect(rendered.channels[1] == [0, 0, 0, 0])
  }

  @Test
  func sourceGainAndMuteAffectRenderedPCM() throws {
    let sourceID = UUID()
    let outputID = UUID()
    let buffer = try makeFrameBuffer(channelCount: 2)
    try write([[1, 0.5], [0.75, -0.75]], to: buffer)
    let controls = [
      0: RoutingAudioChannelControl(gainDecibels: -6, isMuted: false),
      1: RoutingAudioChannelControl(gainDecibels: 0, isMuted: true),
    ]
    let renderer = try makeRenderer(
      nodes: [
        sourceNode(id: sourceID, channelCount: 2, controls: controls),
        outputNode(id: outputID),
      ],
      edges: [edge(from: sourceID, .all, to: outputID, .all)],
      outputNodeID: outputID,
      frameBuffers: [sourceID: buffer]
    )

    let rendered = render(renderer, channelCount: 2, frameCount: 2)
    let gain = Float(pow(10, -6.0 / 20))

    #expect(rendered.result == .rendered)
    #expect(abs(rendered.channels[0][0] - gain) < 0.000_001)
    #expect(abs(rendered.channels[0][1] - 0.5 * gain) < 0.000_001)
    #expect(rendered.channels[1] == [0, 0])
  }

  @Test
  func sourceControlUpdatesRampWithoutRebuildingThePreparedGraph() throws {
    let sourceID = UUID()
    let outputID = UUID()
    let buffer = try makeFrameBuffer(channelCount: 1)
    try write([[1, 1, 1, 1]], to: buffer)
    let renderer = try makeRenderer(
      nodes: [sourceNode(id: sourceID, channelCount: 1), outputNode(id: outputID)],
      edges: [edge(from: sourceID, .all, to: outputID, .all)],
      outputNodeID: outputID,
      frameBuffers: [sourceID: buffer],
      outputChannelCount: 1
    )
    let mutedSource = sourceNode(
      id: sourceID,
      channelCount: 1,
      controls: [0: RoutingAudioChannelControl(gainDecibels: 0, isMuted: true)]
    )

    try renderer.updateControls(nodes: [mutedSource, outputNode(id: outputID)])
    let rendered = render(renderer, channelCount: 1, frameCount: 4)

    #expect(rendered.result == .rendered)
    #expect(rendered.channels[0][0] == 1)
    #expect(rendered.channels[0][1] < rendered.channels[0][0])
    #expect(rendered.channels[0][2] < rendered.channels[0][1])
    #expect(rendered.channels[0][3] < rendered.channels[0][2])
  }

  @Test
  func sharedCaptureIsReadOnceAndCanFanOutInsideOneRenderPlan() throws {
    let firstSourceID = UUID()
    let secondSourceID = UUID()
    let outputID = UUID()
    let buffer = try makeFrameBuffer(channelCount: 1)
    try write([[0.1, 0.2, 0.3]], to: buffer)
    let renderer = try makeRenderer(
      nodes: [
        sourceNode(id: firstSourceID, channelCount: 1),
        sourceNode(id: secondSourceID, channelCount: 1),
        outputNode(id: outputID),
      ],
      edges: [
        edge(from: firstSourceID, .all, to: outputID, .all),
        edge(from: secondSourceID, .all, to: outputID, .all),
      ],
      outputNodeID: outputID,
      frameBuffers: [firstSourceID: buffer, secondSourceID: buffer],
      outputChannelCount: 1
    )

    let rendered = render(renderer, channelCount: 1, frameCount: 3)

    #expect(rendered.channels[0] == [0.2, 0.4, 0.6])
    #expect(buffer.statistics().readFrameCount == 3)
  }

  @Test
  func captureBacklogIsTrimmedToTwoPreparedRenderQuanta() throws {
    let sourceID = UUID()
    let outputID = UUID()
    let buffer = try makeFrameBuffer(channelCount: 1, capacityFrameCount: 128)
    try write([Array(0..<64).map(Float.init)], to: buffer)
    let renderer = try makeRenderer(
      nodes: [sourceNode(id: sourceID, channelCount: 1), outputNode(id: outputID)],
      edges: [edge(from: sourceID, .all, to: outputID, .all)],
      outputNodeID: outputID,
      frameBuffers: [sourceID: buffer],
      outputChannelCount: 1,
      maximumFrameCount: 8
    )

    let rendered = render(renderer, channelCount: 1, frameCount: 8)

    #expect(rendered.channels[0] == Array(48..<56).map(Float.init))
    #expect(buffer.statistics().discardedFrameCount == 48)
  }

  @Test
  func signalGeneratorRendersWithoutACaptureBuffer() throws {
    let generatorID = UUID()
    let outputID = UUID()
    let renderer = try makeRenderer(
      nodes: [signalGeneratorNode(id: generatorID), outputNode(id: outputID)],
      edges: [edge(from: generatorID, .channel(0), to: outputID, .all)],
      outputNodeID: outputID,
      frameBuffers: [:],
      outputChannelCount: 2,
      maximumFrameCount: 32
    )

    let rendered = render(renderer, channelCount: 2, frameCount: 32)

    #expect(rendered.result == .rendered)
    #expect(rendered.channels[0].contains { abs($0) > 0.001 })
    #expect(rendered.channels[1] == Array(repeating: 0, count: 32))
  }

  @Test
  func visualizerPassThroughPreservesPCM() throws {
    let sourceID = UUID()
    let visualizerID = UUID()
    let outputID = UUID()
    let buffer = try makeFrameBuffer(channelCount: 2)
    try write([[0.1, 0.2], [-0.3, -0.4]], to: buffer)
    let renderer = try makeRenderer(
      nodes: [
        sourceNode(id: sourceID, channelCount: 2),
        visualizerNode(id: visualizerID),
        outputNode(id: outputID),
      ],
      edges: [
        edge(from: sourceID, .all, to: visualizerID, .all),
        edge(from: visualizerID, .all, to: outputID, .all),
      ],
      outputNodeID: outputID,
      frameBuffers: [sourceID: buffer]
    )

    let rendered = render(renderer, channelCount: 2, frameCount: 2)

    #expect(rendered.channels == [[0.1, 0.2], [-0.3, -0.4]])
  }

  @Test
  func inputDeviceThroughVisualizerPreservesPCM() throws {
    let inputID = UUID()
    let visualizerID = UUID()
    let outputID = UUID()
    let buffer = try makeFrameBuffer(channelCount: 1)
    try write([[0.2, -0.35, 0.6, -0.8]], to: buffer)
    let renderer = try makeRenderer(
      nodes: [
        inputSourceNode(id: inputID),
        separateVisualizerNode(id: visualizerID),
        outputNode(id: outputID),
      ],
      edges: [
        edge(from: inputID, .channel(0), to: visualizerID, .channel(0)),
        edge(from: visualizerID, .channel(0), to: outputID, .channel(0)),
      ],
      outputNodeID: outputID,
      frameBuffers: [inputID: buffer],
      outputChannelCount: 1
    )

    let rendered = render(renderer, channelCount: 1, frameCount: 4)

    #expect(rendered.result == .rendered)
    #expect(rendered.channels[0] == [0.2, -0.35, 0.6, -0.8])
  }

  @Test
  func delayRunsInTopologicalOrderBetweenMixers() throws {
    let sourceID = UUID()
    let firstMixerID = UUID()
    let delayID = UUID()
    let secondMixerID = UUID()
    let outputID = UUID()
    let buffer = try makeFrameBuffer(channelCount: 1)
    try write([[1] + Array(repeating: 0, count: 63)], to: buffer)
    let renderer = try makeRenderer(
      nodes: [
        sourceNode(id: sourceID, channelCount: 1),
        mixerNode(id: firstMixerID, controls: [:]),
        delayNode(id: delayID),
        mixerNode(id: secondMixerID, controls: [:]),
        outputNode(id: outputID),
      ],
      edges: [
        edge(from: sourceID, .all, to: firstMixerID, .channel(0)),
        edge(from: firstMixerID, .channel(0), to: delayID, .all),
        edge(from: delayID, .all, to: secondMixerID, .channel(0)),
        edge(from: secondMixerID, .channel(0), to: outputID, .all),
      ],
      outputNodeID: outputID,
      frameBuffers: [sourceID: buffer],
      outputChannelCount: 1,
      maximumFrameCount: 64
    )

    let rendered = render(renderer, channelCount: 1, frameCount: 64)

    #expect(rendered.result == .rendered)
    #expect(rendered.channels[0][0..<48].allSatisfy { $0 == 0 })
    #expect(rendered.channels[0][48] == 1)
    #expect(rendered.channels[0][49...].allSatisfy { $0 == 0 })
  }

  @Test
  func noiseGateAttenuatesQuietFramesInsideThePreparedRenderGraph() throws {
    let sourceID = UUID()
    let gateID = UUID()
    let outputID = UUID()
    let buffer = try makeFrameBuffer(channelCount: 2)
    try write([[0.01, 0.2, 0.01], [0.005, 0.02, 0.005]], to: buffer)
    let renderer = try makeRenderer(
      nodes: [
        sourceNode(id: sourceID, channelCount: 2),
        noiseGateNode(id: gateID),
        outputNode(id: outputID),
      ],
      edges: [
        edge(from: sourceID, .all, to: gateID, .all),
        edge(from: gateID, .all, to: outputID, .all),
      ],
      outputNodeID: outputID,
      frameBuffers: [sourceID: buffer]
    )

    let rendered = render(renderer, channelCount: 2, frameCount: 3)

    #expect(rendered.result == .rendered)
    #expect(abs(rendered.channels[0][0] - 0.0001) < 0.000_001)
    #expect(rendered.channels[0][1] == 0.2)
    #expect(abs(rendered.channels[1][0] - 0.00005) < 0.000_001)
    #expect(rendered.channels[1][1] == 0.02)
  }

  @Test
  func noiseGateControlUpdatesApplyWithoutRebuildingThePreparedGraph() throws {
    let sourceID = UUID()
    let gateID = UUID()
    let outputID = UUID()
    let buffer = try makeFrameBuffer(channelCount: 1)
    try write([[0.01, 0.01]], to: buffer)
    let renderer = try makeRenderer(
      nodes: [
        sourceNode(id: sourceID, channelCount: 1),
        noiseGateNode(id: gateID),
        outputNode(id: outputID),
      ],
      edges: [
        edge(from: sourceID, .all, to: gateID, .all),
        edge(from: gateID, .all, to: outputID, .all),
      ],
      outputNodeID: outputID,
      frameBuffers: [sourceID: buffer],
      outputChannelCount: 1
    )
    let updatedGate = noiseGateNode(
      id: gateID,
      configuration: RoutingNoiseGateConfiguration(
        thresholdDecibels: -20,
        hysteresisDecibels: 6,
        attackSeconds: 0,
        holdSeconds: 0,
        releaseSeconds: 0,
        reductionDecibels: 20
      )
    )

    let initial = render(renderer, channelCount: 1, frameCount: 1)
    try renderer.updateControls(
      nodes: [
        sourceNode(id: sourceID, channelCount: 1),
        updatedGate,
        outputNode(id: outputID),
      ]
    )
    let updated = render(renderer, channelCount: 1, frameCount: 1)

    #expect(abs(initial.channels[0][0] - 0.0001) < 0.000_001)
    #expect(abs(updated.channels[0][0] - 0.001) < 0.000_001)
  }

  @Test
  func mixerSumsInputsAndAppliesOutputControl() throws {
    let firstSourceID = UUID()
    let secondSourceID = UUID()
    let mixerID = UUID()
    let outputID = UUID()
    let firstBuffer = try makeFrameBuffer(channelCount: 1)
    let secondBuffer = try makeFrameBuffer(channelCount: 1)
    try write([[0.25, 0.5]], to: firstBuffer)
    try write([[0.75, -0.25]], to: secondBuffer)
    let mixerControl = RoutingAudioChannelControl(gainDecibels: -6, isMuted: false)
    let renderer = try makeRenderer(
      nodes: [
        sourceNode(id: firstSourceID, channelCount: 1),
        sourceNode(id: secondSourceID, channelCount: 1),
        mixerNode(id: mixerID, controls: [0: mixerControl]),
        outputNode(id: outputID),
      ],
      edges: [
        edge(from: firstSourceID, .all, to: mixerID, .channel(0)),
        edge(from: secondSourceID, .all, to: mixerID, .channel(0)),
        edge(from: mixerID, .channel(0), to: outputID, .all),
      ],
      outputNodeID: outputID,
      frameBuffers: [firstSourceID: firstBuffer, secondSourceID: secondBuffer]
    )

    let rendered = render(renderer, channelCount: 2, frameCount: 2)
    let gain = Float(pow(10, -6.0 / 20))

    #expect(abs(rendered.channels[0][0] - gain) < 0.000_001)
    #expect(abs(rendered.channels[0][1] - 0.25 * gain) < 0.000_001)
    #expect(rendered.channels[1] == [0, 0])
  }

  @Test
  func compilerRejectsGraphFeedbackCycles() throws {
    let firstVisualizerID = UUID()
    let secondVisualizerID = UUID()
    let outputID = UUID()
    let nodes = [
      visualizerNode(id: firstVisualizerID),
      visualizerNode(id: secondVisualizerID),
      outputNode(id: outputID),
    ]
    let edges = [
      edge(from: firstVisualizerID, .all, to: secondVisualizerID, .all),
      edge(from: secondVisualizerID, .all, to: firstVisualizerID, .all),
      edge(from: secondVisualizerID, .all, to: outputID, .all),
    ]

    #expect(throws: RoutingPreparedAudioGraphError.cycle) {
      try makeRenderer(
        nodes: nodes,
        edges: edges,
        outputNodeID: outputID,
        frameBuffers: [:]
      )
    }
  }

  @Test
  func compilerRejectsImplicitSampleRateConversion() throws {
    let sourceID = UUID()
    let outputID = UUID()
    let buffer = try makeFrameBuffer(channelCount: 1, sampleRate: 44_100)

    #expect(throws: RoutingPreparedAudioGraphError.incompatibleSampleRate(sourceID)) {
      try makeRenderer(
        nodes: [sourceNode(id: sourceID, channelCount: 1), outputNode(id: outputID)],
        edges: [edge(from: sourceID, .all, to: outputID, .all)],
        outputNodeID: outputID,
        frameBuffers: [sourceID: buffer]
      )
    }
  }

  private func makeRenderer(
    nodes: [RoutingWorkspaceNode],
    edges: [RoutingWorkspaceEdge],
    outputNodeID: UUID,
    frameBuffers: [UUID: AudioRealtimeFrameBuffer],
    outputChannelCount: Int = 2,
    maximumFrameCount: Int = 32
  ) throws -> RoutingPreparedAudioGraphSource {
    try RoutingPreparedAudioGraphSource(
      preparation: AudioRenderPreparation(
        format: AudioProcessingFormat(sampleRate: 48_000, channelCount: outputChannelCount),
        maximumFrameCount: maximumFrameCount
      ),
      nodes: nodes,
      edges: edges,
      outputNodeID: outputNodeID,
      frameBuffers: frameBuffers
    )
  }

  private func sourceNode(
    id: UUID,
    channelCount: Int,
    controls: [Int: RoutingAudioChannelControl] = [:]
  ) -> RoutingWorkspaceNode {
    RoutingWorkspaceNode(
      id: id,
      value: .applicationAudio(
        selection: nil,
        channelPresentation: channelCount == 1 ? .separate(channelCount: 1) : .aggregate
      ),
      frame: .zero,
      audioChannelControls: controls
    )
  }

  private func outputNode(id: UUID) -> RoutingWorkspaceNode {
    RoutingWorkspaceNode(
      id: id,
      value: .outputAudio(selection: nil, channelPresentation: .aggregate),
      frame: .zero
    )
  }

  private func inputSourceNode(id: UUID) -> RoutingWorkspaceNode {
    RoutingWorkspaceNode(
      id: id,
      value: .inputAudio(
        selection: nil,
        channelPresentation: .separate(channelCount: 1)
      ),
      frame: .zero
    )
  }

  private func visualizerNode(id: UUID) -> RoutingWorkspaceNode {
    RoutingWorkspaceNode(
      id: id,
      value: .visualizer(configuration: .initial),
      frame: .zero
    )
  }

  private func separateVisualizerNode(id: UUID) -> RoutingWorkspaceNode {
    RoutingWorkspaceNode(
      id: id,
      value: .visualizer(
        configuration: RoutingVisualizerConfiguration(
          mode: .separate,
          availableChannelCount: 1,
          selectedChannels: [0]
        )
      ),
      frame: .zero
    )
  }

  private func mixerNode(
    id: UUID,
    controls: [Int: RoutingAudioChannelControl]
  ) -> RoutingWorkspaceNode {
    RoutingWorkspaceNode(
      id: id,
      value: .audioMixer(configuration: .initial),
      frame: .zero,
      audioChannelControls: controls
    )
  }

  private func signalGeneratorNode(id: UUID) -> RoutingWorkspaceNode {
    RoutingWorkspaceNode(
      id: id,
      value: .signalGenerator(configuration: .initial),
      frame: .zero
    )
  }

  private func delayNode(id: UUID) -> RoutingWorkspaceNode {
    RoutingWorkspaceNode(
      id: id,
      value: .delay(
        configuration: RoutingDelayConfiguration(
          delaySeconds: 0.001,
          feedback: 0,
          dryWetMix: 1
        )
      ),
      frame: .zero
    )
  }

  private func noiseGateNode(
    id: UUID,
    configuration: RoutingNoiseGateConfiguration = RoutingNoiseGateConfiguration(
      thresholdDecibels: -20,
      hysteresisDecibels: 6,
      attackSeconds: 0,
      holdSeconds: 0,
      releaseSeconds: 0,
      reductionDecibels: 40
    )
  ) -> RoutingWorkspaceNode {
    RoutingWorkspaceNode(
      id: id,
      value: .noiseGate(configuration: configuration),
      frame: .zero
    )
  }

  private func edge(
    from sourceID: UUID,
    _ sourceChannel: RoutingAudioPortChannel,
    to targetID: UUID,
    _ targetChannel: RoutingAudioPortChannel
  ) -> RoutingWorkspaceEdge {
    RoutingWorkspaceEdge(
      id: UUID(),
      source: RoutingWorkspacePortAddress(
        nodeID: sourceID,
        portID: RoutingGraphPortID(direction: .output, channel: sourceChannel)
      ),
      target: RoutingWorkspacePortAddress(
        nodeID: targetID,
        portID: RoutingGraphPortID(direction: .input, channel: targetChannel)
      )
    )
  }

  private func makeFrameBuffer(
    channelCount: Int,
    sampleRate: Double = 48_000,
    capacityFrameCount: Int = 64
  ) throws -> AudioRealtimeFrameBuffer {
    try AudioRealtimeFrameBuffer(
      format: AudioProcessingFormat(sampleRate: sampleRate, channelCount: channelCount),
      capacityFrameCount: capacityFrameCount
    )
  }

  private func write(
    _ channels: [[Float]],
    to frameBuffer: AudioRealtimeFrameBuffer
  ) throws {
    let frameCount = try #require(channels.first?.count)
    #expect(channels.count == frameBuffer.format.channelCount)
    #expect(channels.allSatisfy { $0.count == frameCount })
    let samples = channels.map { channel -> UnsafeMutablePointer<Float> in
      let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
      pointer.initialize(from: channel, count: frameCount)
      return pointer
    }
    defer {
      for pointer in samples {
        pointer.deinitialize(count: frameCount)
        pointer.deallocate()
      }
    }
    let pointers = UnsafeMutablePointer<UnsafePointer<Float>>.allocate(capacity: samples.count)
    defer {
      pointers.deinitialize(count: samples.count)
      pointers.deallocate()
    }
    for (index, pointer) in samples.enumerated() {
      pointers.advanced(by: index).initialize(to: UnsafePointer(pointer))
    }
    #expect(
      frameBuffer.writePlanar(
        UnsafeBufferPointer(start: pointers, count: samples.count),
        frameCount: frameCount
      ) == frameCount
    )
  }

  private func render(
    _ renderer: RoutingPreparedAudioGraphSource,
    channelCount: Int,
    frameCount: Int
  ) -> (result: AudioRenderResult, channels: [[Float]]) {
    let samples = (0..<channelCount).map { _ -> UnsafeMutablePointer<Float> in
      let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frameCount)
      pointer.initialize(repeating: .nan, count: frameCount)
      return pointer
    }
    defer {
      for pointer in samples {
        pointer.deinitialize(count: frameCount)
        pointer.deallocate()
      }
    }
    let pointers = UnsafeMutablePointer<UnsafeMutablePointer<Float>>.allocate(
      capacity: channelCount
    )
    defer {
      pointers.deinitialize(count: channelCount)
      pointers.deallocate()
    }
    for (index, pointer) in samples.enumerated() {
      pointers.advanced(by: index).initialize(to: pointer)
    }
    let result = renderer.render(
      outputChannels: UnsafeBufferPointer(start: pointers, count: channelCount),
      frameCount: frameCount
    )
    return (result, samples.map { Array(UnsafeBufferPointer(start: $0, count: frameCount)) })
  }
}
