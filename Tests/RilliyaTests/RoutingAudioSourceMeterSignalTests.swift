import Foundation
import RilliyaKit
import Testing

@testable import Rilliya

struct RoutingAudioSourceMeterSignalTests {
  @Test
  func buildsStableRowsForMissingAndPresentChannels() throws {
    let deviceID = try #require(AudioDeviceID(rawValue: "meter-device"))
    let channels = try [0, 2].map { index in
      AudioChannelMeterSnapshot(
        channelID: AudioChannelID(
          ownerID: .source(.deviceInput(deviceID)),
          index: try #require(AudioChannelIndex(rawValue: index))
        ),
        rootMeanSquare: index == 0 ? 0.1 : 0.5,
        peak: index == 0 ? 0.25 : 1.05,
        decibels: -20,
        isClipping: index == 2,
        waveform: []
      )
    }
    let snapshot = DeviceInputMeterSnapshot(
      format: DeviceInputCaptureFormat(
        deviceID: deviceID,
        sampleRate: 48_000,
        channelIDs: channels.map(\.channelID)
      ),
      sequence: 1,
      frameCount: 128,
      channels: channels
    )

    let meters = RoutingAudioSourceMeterSignalBuilder.build(
      channelCount: 3,
      snapshot: snapshot
    )

    #expect(meters.map(\.channelIndex) == [0, 1, 2])
    #expect(meters[0].rootMeanSquareDecibels.isApproximatelyEqual(to: -20))
    #expect(meters[1].normalizedLevel == 0)
    #expect(meters[1].decibelsDescription == "−∞")
    #expect(meters[2].isClipping)
    #expect(meters[2].peak > 1)
  }

  @Test
  func channelControlsScaleMetersAndMuteOnlyTheirOwnLane() throws {
    let deviceID = try #require(AudioDeviceID(rawValue: "controlled-device"))
    let channels = try [0, 1].map { index in
      AudioChannelMeterSnapshot(
        channelID: AudioChannelID(
          ownerID: .source(.deviceInput(deviceID)),
          index: try #require(AudioChannelIndex(rawValue: index))
        ),
        rootMeanSquare: 0.25,
        peak: 0.5,
        decibels: -12,
        isClipping: false,
        waveform: []
      )
    }
    let snapshot = DeviceInputMeterSnapshot(
      format: DeviceInputCaptureFormat(
        deviceID: deviceID,
        sampleRate: 48_000,
        channelIDs: channels.map(\.channelID)
      ),
      sequence: 1,
      frameCount: 128,
      channels: channels
    )

    let meters = RoutingAudioSourceMeterSignalBuilder.build(
      channelCount: 2,
      snapshot: snapshot,
      controls: [
        0: RoutingAudioChannelControl(gainDecibels: 6, isMuted: false),
        1: RoutingAudioChannelControl(gainDecibels: 0, isMuted: true),
      ]
    )

    #expect(meters[0].peak.isApproximatelyEqual(to: 0.997_631))
    #expect(meters[1].rootMeanSquare == 0)
    #expect(meters[1].peak == 0)
  }
}

extension Float {
  fileprivate func isApproximatelyEqual(to other: Float, tolerance: Float = 0.001) -> Bool {
    abs(self - other) <= tolerance
  }
}
