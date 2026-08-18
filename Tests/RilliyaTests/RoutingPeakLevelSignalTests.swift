import Foundation
import RilliyaCapture
import RilliyaCore
import RilliyaRealtime
import Testing

@testable import Rilliya

struct RoutingPeakLevelSignalTests {
  @Test
  func aggregateInputUsesTheLargestChannelPeak() throws {
    let sourceID = UUID()
    let signal = RoutingPeakLevelSignalBuilder.build(
      incomingEdges: [edge(sourceID: sourceID, sourceChannel: .all)],
      snapshotForNode: { nodeID in
        nodeID == sourceID ? try? self.snapshot(peaks: [0.2, 0.84, 0.5]) : nil
      }
    )

    #expect(signal?.linearPeak == 0.84)
    #expect(signal?.isClipping == false)
  }

  @Test
  func channelInputMatchesItsStableChannelIdentity() throws {
    let sourceID = UUID()
    let signal = RoutingPeakLevelSignalBuilder.build(
      incomingEdges: [edge(sourceID: sourceID, sourceChannel: .channel(7))],
      snapshotForNode: { nodeID in
        nodeID == sourceID
          ? try? self.snapshot(indices: [7, 2], peaks: [0.71, 0.15])
          : nil
      }
    )

    #expect(signal?.linearPeak == 0.71)
  }

  @Test
  func silenceIsALiveZeroValue() throws {
    let sourceID = UUID()
    let signal = RoutingPeakLevelSignalBuilder.build(
      incomingEdges: [edge(sourceID: sourceID, sourceChannel: .all)],
      snapshotForNode: { nodeID in
        nodeID == sourceID ? try? self.snapshot(peaks: [0, 0]) : nil
      }
    )

    #expect(signal?.linearPeak == 0)
    #expect(signal?.decibelsFullScale == -.infinity)
  }

  @Test
  func overRangePeakRemainsUnclampedAndReportsClipping() throws {
    let sourceID = UUID()
    let signal = RoutingPeakLevelSignalBuilder.build(
      incomingEdges: [edge(sourceID: sourceID, sourceChannel: .all)],
      snapshotForNode: { nodeID in
        nodeID == sourceID ? try? self.snapshot(peaks: [1.2], clipping: [true]) : nil
      }
    )

    #expect(signal?.linearPeak == 1.2)
    #expect(signal?.isClipping == true)
  }

  @Test
  func missingSnapshotChannelAndMultipleInputsHaveNoValue() throws {
    let sourceID = UUID()
    let missingSnapshot = RoutingPeakLevelSignalBuilder.build(
      incomingEdges: [edge(sourceID: sourceID, sourceChannel: .all)],
      snapshotForNode: { _ in nil }
    )
    let missingChannel = RoutingPeakLevelSignalBuilder.build(
      incomingEdges: [edge(sourceID: sourceID, sourceChannel: .channel(9))],
      snapshotForNode: { _ in try? self.snapshot(peaks: [0.4]) }
    )
    let multipleInputs = RoutingPeakLevelSignalBuilder.build(
      incomingEdges: [
        edge(sourceID: sourceID, sourceChannel: .all),
        edge(sourceID: UUID(), sourceChannel: .all),
      ],
      snapshotForNode: { _ in try? self.snapshot(peaks: [0.4]) }
    )

    #expect(missingSnapshot == nil)
    #expect(missingChannel == nil)
    #expect(multipleInputs == nil)
  }

  @Test
  func disabledInputDoesNotContribute() throws {
    let sourceID = UUID()
    let signal = RoutingPeakLevelSignalBuilder.build(
      incomingEdges: [edge(sourceID: sourceID, sourceChannel: .all, isEnabled: false)],
      snapshotForNode: { _ in try? self.snapshot(peaks: [0.9]) }
    )

    #expect(signal == nil)
  }

  @Test
  func peakLevelUsesPerSourceChannelGainAndMute() throws {
    let sourceID = UUID()
    let signal = RoutingPeakLevelSignalBuilder.build(
      incomingEdges: [edge(sourceID: sourceID, sourceChannel: .all)],
      snapshotForNode: { _ in try? self.snapshot(peaks: [0.25, 0.9]) },
      channelControl: { _, channelIndex in
        channelIndex == 0
          ? RoutingAudioChannelControl(gainDecibels: 6, isMuted: false)
          : RoutingAudioChannelControl(gainDecibels: 0, isMuted: true)
      }
    )

    #expect(signal?.linearPeak.isApproximatelyEqual(to: 0.498_816) == true)
  }

  private func edge(
    sourceID: UUID,
    sourceChannel: RoutingAudioPortChannel,
    isEnabled: Bool = true
  ) -> RoutingWorkspaceEdge {
    RoutingWorkspaceEdge(
      id: UUID(),
      source: RoutingWorkspacePortAddress(
        nodeID: sourceID,
        portID: RoutingGraphPortID(direction: .output, channel: sourceChannel)
      ),
      target: RoutingWorkspacePortAddress(
        nodeID: UUID(),
        portID: RoutingGraphPortID(direction: .input, channel: .all)
      ),
      isEnabled: isEnabled
    )
  }

  private func snapshot(
    indices: [Int]? = nil,
    peaks: [Float],
    clipping: [Bool]? = nil
  ) throws -> ProcessOutputMeterSnapshot {
    let processID = try #require(AudioProcessID(rawValue: 77))
    let channelIndices = indices ?? Array(peaks.indices)
    let channelIDs = try channelIndices.map { index in
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
      frameCount: 128,
      channels: zip(channelIDs, peaks).enumerated().map { offset, pair in
        AudioChannelMeterSnapshot(
          channelID: pair.0,
          rootMeanSquare: 0,
          peak: pair.1,
          decibels: -120,
          isClipping: clipping?[safe: offset] ?? (pair.1 >= 1),
          waveform: []
        )
      }
    )
  }
}

extension Float {
  fileprivate func isApproximatelyEqual(to other: Float, tolerance: Float = 0.001) -> Bool {
    abs(self - other) <= tolerance
  }
}

extension Array {
  fileprivate subscript(safe index: Index) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
