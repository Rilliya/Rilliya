import Foundation
import RilliyaCapture
import RilliyaCore
import RilliyaRealtime
import Testing
@testable import Rilliya

struct RoutingVisualizerSignalTests {
  @Test
  func mixedVisualizerUsesOnlyTheChannelNamedByTheIncomingEdge() throws {
    let sourceID = UUID()
    let targetID = UUID()
    let snapshot = try makeSnapshot(
      processIdentifier: 41,
      waveforms: [
        [1, 0.5, 0],
        [-0.25, -0.5, -0.75],
      ]
    )
    let edge = RoutingWorkspaceEdge(
      id: UUID(),
      source: RoutingWorkspacePortAddress(
        nodeID: sourceID,
        portID: RoutingGraphPortID(direction: .output, channel: .channel(1))
      ),
      target: RoutingWorkspacePortAddress(
        nodeID: targetID,
        portID: RoutingGraphPortID(direction: .input, channel: .all)
      )
    )

    let signal = RoutingVisualizerSignalBuilder.build(
      configuration: .initial,
      incomingEdges: [edge],
      snapshotForNode: { $0 == sourceID ? snapshot : nil }
    )

    #expect(signal?.waveforms == [[-0.25, -0.5, -0.75]])
  }

  @Test
  func mixedVisualizerCombinesEveryConnectedSourceDeterministically() throws {
    let firstSourceID = UUID()
    let secondSourceID = UUID()
    let targetID = UUID()
    let snapshots = [
      firstSourceID: try makeSnapshot(processIdentifier: 41, waveforms: [[1, 0.5]]),
      secondSourceID: try makeSnapshot(processIdentifier: 42, waveforms: [[-0.5, 0.5]]),
    ]
    let edges = [firstSourceID, secondSourceID].map { sourceID in
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

    let signal = RoutingVisualizerSignalBuilder.build(
      configuration: .initial,
      incomingEdges: edges,
      snapshotForNode: { snapshots[$0] }
    )

    #expect(signal?.waveforms == [[0.25, 0.5]])
  }

  @Test
  func separateVisualizerGroupsWaveformsByTheirTargetPorts() throws {
    let sourceID = UUID()
    let targetID = UUID()
    let snapshot = try makeSnapshot(
      processIdentifier: 41,
      waveforms: [
        [0.1, 0.2],
        [0.8, 0.6],
        [-0.3, -0.4],
      ]
    )
    let edges = [0, 2].map { channel in
      RoutingWorkspaceEdge(
        id: UUID(),
        source: RoutingWorkspacePortAddress(
          nodeID: sourceID,
          portID: RoutingGraphPortID(direction: .output, channel: .channel(channel))
        ),
        target: RoutingWorkspacePortAddress(
          nodeID: targetID,
          portID: RoutingGraphPortID(direction: .input, channel: .channel(channel))
        )
      )
    }
    let configuration = RoutingVisualizerConfiguration(
      mode: .separate,
      availableChannelCount: 3,
      selectedChannels: [0, 2]
    )

    let signal = RoutingVisualizerSignalBuilder.build(
      configuration: configuration,
      incomingEdges: edges,
      snapshotForNode: { $0 == sourceID ? snapshot : nil }
    )

    #expect(signal?.waveforms == [[0.1, 0.2], [-0.3, -0.4]])
  }

  @Test
  func visualizerUsesTheSourceNodesIndependentChannelControls() throws {
    let sourceID = UUID()
    let targetID = UUID()
    let snapshot = try makeSnapshot(processIdentifier: 41, waveforms: [[0.25, -0.5]])
    let edge = RoutingWorkspaceEdge(
      id: UUID(),
      source: RoutingWorkspacePortAddress(
        nodeID: sourceID,
        portID: RoutingGraphPortID(direction: .output, channel: .channel(0))
      ),
      target: RoutingWorkspacePortAddress(
        nodeID: targetID,
        portID: RoutingGraphPortID(direction: .input, channel: .all)
      )
    )

    let signal = RoutingVisualizerSignalBuilder.build(
      configuration: .initial,
      incomingEdges: [edge],
      snapshotForNode: { $0 == sourceID ? snapshot : nil },
      channelControl: { nodeID, channelIndex in
        #expect(nodeID == sourceID)
        #expect(channelIndex == 0)
        return RoutingAudioChannelControl(gainDecibels: 0, isMuted: true)
      }
    )

    #expect(signal?.waveforms == [[0, 0]])
  }

  private func makeSnapshot(
    processIdentifier: Int32,
    waveforms: [[Float]]
  ) throws -> ProcessOutputMeterSnapshot {
    let processID = try #require(AudioProcessID(rawValue: processIdentifier))
    let channelIDs = try waveforms.indices.map { index in
      AudioChannelID(
        ownerID: .source(.processOutput(processID)),
        index: try #require(AudioChannelIndex(rawValue: index))
      )
    }
    let format = ProcessOutputCaptureFormat(
      processID: processID,
      sampleRate: 48_000,
      channelIDs: channelIDs
    )
    return ProcessOutputMeterSnapshot(
      format: format,
      sequence: 1,
      frameCount: waveforms.map(\.count).max() ?? 0,
      channels: zip(channelIDs, waveforms).map { channelID, waveform in
        AudioChannelMeterSnapshot(
          channelID: channelID,
          rootMeanSquare: 0,
          peak: 0,
          decibels: -120,
          isClipping: false,
          waveform: waveform
        )
      }
    )
  }
}
