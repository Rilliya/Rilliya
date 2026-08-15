import Foundation
import RilliyaCapture
import RilliyaCore

struct RoutingAudioCaptureFormat: Equatable, Sendable {
  let sampleRate: Double
  let channelIDs: [AudioChannelID]

  init(sampleRate: Double, channelIDs: [AudioChannelID]) {
    self.sampleRate = sampleRate
    self.channelIDs = channelIDs
  }

  init(_ format: ProcessOutputCaptureFormat) {
    self.init(sampleRate: format.sampleRate, channelIDs: format.channelIDs)
  }

  init(_ format: DeviceInputCaptureFormat) {
    self.init(sampleRate: format.sampleRate, channelIDs: format.channelIDs)
  }
}

protocol RoutingAudioMeterSnapshot: Sendable {
  var channels: [AudioChannelMeterSnapshot] { get }
}

extension ProcessOutputMeterSnapshot: RoutingAudioMeterSnapshot {}
extension DeviceInputMeterSnapshot: RoutingAudioMeterSnapshot {}
