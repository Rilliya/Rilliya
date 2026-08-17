import Foundation
import RilliyaCapture
import RilliyaCore
import RilliyaRealtime
import Testing
@testable import Rilliya

struct RoutingResolvedAudioSignalTests {
  @Test
  func visualizerPassThroughPreservesChannelsAndOffersAnExplicitMonoMix() throws {
    let sourceID = UUID()
    let visualizerID = UUID()
    let source = RoutingWorkspaceNode(
      id: sourceID,
      value: .applicationAudio(selection: nil, channelPresentation: .separate(channelCount: 2)),
      frame: .zero
    )
    let visualizer = RoutingWorkspaceNode(
      id: visualizerID,
      value: .visualizer(
        configuration: RoutingVisualizerConfiguration(
          mode: .separate,
          availableChannelCount: 2,
          selectedChannels: [0, 1],
          includesMixedOutput: true
        )
      ),
      frame: .zero
    )
    let edges = [0, 1].map { channelIndex in
      RoutingWorkspaceEdge(
        id: UUID(),
        source: RoutingWorkspacePortAddress(
          nodeID: sourceID,
          portID: RoutingGraphPortID(direction: .output, channel: .channel(channelIndex))
        ),
        target: RoutingWorkspacePortAddress(
          nodeID: visualizerID,
          portID: RoutingGraphPortID(direction: .input, channel: .channel(channelIndex))
        )
      )
    }
    let snapshot = try makeSnapshot(waveforms: [[1, -1], [0, 1]], peaks: [1, 1])
    let resolver = RoutingAudioSignalResolver(
      nodes: [source, visualizer],
      activeEdges: edges,
      snapshotForNode: { $0 == sourceID ? snapshot : nil }
    )

    let passThrough = resolver.resolveOutput(
      RoutingWorkspacePortAddress(
        nodeID: visualizerID,
        portID: RoutingGraphPortID(direction: .output, channel: .channel(1))
      )
    )
    let mixed = resolver.resolveOutput(
      RoutingWorkspacePortAddress(
        nodeID: visualizerID,
        portID: RoutingGraphPortID(direction: .output, channel: .all)
      )
    )

    #expect(passThrough.map(\.waveform) == [[0, 1]])
    #expect(mixed.map(\.waveform) == [[0.5, 0]])
  }

  @Test
  func resolverStopsAtCyclesInsteadOfRecursingIndefinitely() {
    let firstID = UUID()
    let secondID = UUID()
    let value = RoutingNodeValue.visualizer(configuration: .initial)
    let first = RoutingWorkspaceNode(id: firstID, value: value, frame: .zero)
    let second = RoutingWorkspaceNode(id: secondID, value: value, frame: .zero)
    let edges = [
      edge(sourceID: firstID, targetID: secondID),
      edge(sourceID: secondID, targetID: firstID),
    ]
    let resolver = RoutingAudioSignalResolver(
      nodes: [first, second],
      activeEdges: edges,
      snapshotForNode: { _ in nil }
    )

    let signals = resolver.resolveOutput(
      RoutingWorkspacePortAddress(
        nodeID: firstID,
        portID: RoutingGraphPortID(direction: .output, channel: .all)
      )
    )

    #expect(signals.isEmpty)
  }

  @Test
  func audioMixerSumsEveryInputWithoutHiddenNormalization() throws {
    let firstSourceID = UUID()
    let secondSourceID = UUID()
    let mixerID = UUID()
    let sources = [firstSourceID, secondSourceID].map { sourceID in
      RoutingWorkspaceNode(
        id: sourceID,
        value: .applicationAudio(
          selection: nil,
          channelPresentation: .separate(channelCount: 1)
        ),
        frame: .zero
      )
    }
    let mixer = RoutingWorkspaceNode(
      id: mixerID,
      value: .audioMixer(configuration: RoutingAudioMixerConfiguration(channelCount: 1)),
      frame: .zero
    )
    let edges = [firstSourceID, secondSourceID].map { sourceID in
      RoutingWorkspaceEdge(
        id: UUID(),
        source: RoutingWorkspacePortAddress(
          nodeID: sourceID,
          portID: RoutingGraphPortID(direction: .output, channel: .channel(0))
        ),
        target: RoutingWorkspacePortAddress(
          nodeID: mixerID,
          portID: RoutingGraphPortID(direction: .input, channel: .channel(0))
        )
      )
    }
    let firstSnapshot = try makeSnapshot(waveforms: [[0.25, 0.5]], peaks: [0.5])
    let secondSnapshot = try makeSnapshot(waveforms: [[0.5, -0.5]], peaks: [0.5])
    let resolver = RoutingAudioSignalResolver(
      nodes: sources + [mixer],
      activeEdges: edges,
      snapshotForNode: { nodeID in
        nodeID == firstSourceID ? firstSnapshot : secondSnapshot
      }
    )

    let output = resolver.resolveOutput(
      RoutingWorkspacePortAddress(
        nodeID: mixerID,
        portID: RoutingGraphPortID(direction: .output, channel: .channel(0))
      )
    )

    #expect(output.map(\.waveform) == [[0.75, 0]])
    #expect(output.first?.peak == 0.75)
  }

  @Test
  func systemOutputSnapshotResolvesThroughAggregateAndSeparatePorts() throws {
    let nodeID = UUID()
    let deviceID = try #require(AudioDeviceID(rawValue: "test.output"))
    let node = RoutingWorkspaceNode(
      id: nodeID,
      value: .systemOutput(
        selection: .systemDefault, channelPresentation: .separate(channelCount: 2)),
      frame: .zero
    )
    let snapshot = try makeOutputSnapshot(deviceID: deviceID, waveforms: [[0.1], [0.8]])
    let resolver = RoutingAudioSignalResolver(
      nodes: [node],
      activeEdges: [],
      snapshotForNode: { $0 == nodeID ? snapshot : nil }
    )

    let selected = resolver.resolveOutput(
      RoutingWorkspacePortAddress(
        nodeID: nodeID,
        portID: RoutingGraphPortID(direction: .output, channel: .channel(1))
      )
    )

    #expect(selected.map(\.channelIndex) == [1])
    #expect(selected.map(\.waveform) == [[0.8]])
  }

  private func edge(sourceID: UUID, targetID: UUID) -> RoutingWorkspaceEdge {
    RoutingWorkspaceEdge(
      id: UUID(),
      source: RoutingWorkspacePortAddress(
        nodeID: sourceID,
        portID: RoutingGraphPortID(direction: .output, channel: .all)
      ),
      target: RoutingWorkspacePortAddress(
        nodeID: targetID,
        portID: RoutingGraphPortID(direction: .input, channel: .all)
      )
    )
  }

  private func makeSnapshot(
    waveforms: [[Float]],
    peaks: [Float]
  ) throws -> ProcessOutputMeterSnapshot {
    let processID = try #require(AudioProcessID(rawValue: 42))
    let channelIDs = try waveforms.indices.map { channelIndex in
      AudioChannelID(
        ownerID: .source(.processOutput(processID)),
        index: try #require(AudioChannelIndex(rawValue: channelIndex))
      )
    }
    return ProcessOutputMeterSnapshot(
      format: ProcessOutputCaptureFormat(
        processID: processID,
        sampleRate: 48_000,
        channelIDs: channelIDs
      ),
      sequence: 1,
      frameCount: waveforms.first?.count ?? 0,
      channels: zip(channelIDs, zip(waveforms, peaks)).map { channelID, values in
        AudioChannelMeterSnapshot(
          channelID: channelID,
          rootMeanSquare: 0.5,
          peak: values.1,
          decibels: -6,
          isClipping: values.1 >= 1,
          waveform: values.0
        )
      }
    )
  }

  private func makeOutputSnapshot(
    deviceID: AudioDeviceID,
    waveforms: [[Float]]
  ) throws -> DeviceOutputMeterSnapshot {
    let channelIDs = try waveforms.indices.map { channelIndex in
      AudioChannelID(
        ownerID: .source(.deviceOutput(deviceID)),
        index: try #require(AudioChannelIndex(rawValue: channelIndex))
      )
    }
    return DeviceOutputMeterSnapshot(
      format: DeviceOutputCaptureFormat(
        deviceID: deviceID,
        streamIndex: try #require(AudioStreamIndex(rawValue: 0)),
        sampleRate: 48_000,
        channelIDs: channelIDs
      ),
      sequence: 1,
      frameCount: waveforms.first?.count ?? 0,
      channels: zip(channelIDs, waveforms).map { channelID, waveform in
        AudioChannelMeterSnapshot(
          channelID: channelID,
          rootMeanSquare: 0.5,
          peak: waveform.map(abs).max() ?? 0,
          decibels: -6,
          isClipping: false,
          waveform: waveform
        )
      }
    )
  }
}
