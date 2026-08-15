import RilliyaCore

struct ApplicationOutputPresentation: Equatable, Identifiable {
  let id: AudioProcessID
  let title: String
  let subtitle: String
  let channelDetail: String
  let isActive: Bool

  init(process: AudioProcess, resolvedName: String?) {
    id = process.id
    title = resolvedName ?? process.bundleIdentifier ?? "Process \(process.id.rawValue)"
    subtitle =
      resolvedName == nil
      ? "PID \(process.id.rawValue)"
      : process.bundleIdentifier ?? "PID \(process.id.rawValue)"
    channelDetail = "Channel layout pending capture"
    isActive = process.isRunningOutput
  }
}

struct DeviceChannelPresentation: Equatable, Identifiable {
  let id: AudioChannelID
  let title: String
  let nativeMapping: String?

  init(channel: AudioChannel) {
    id = channel.id
    title = "Channel \(channel.id.index.rawValue + 1)"

    switch (channel.streamID, channel.streamChannelIndex) {
    case (.some(let streamID), .some(let streamChannelIndex)):
      nativeMapping =
        "Native stream \(streamID.index.rawValue + 1) · "
        + "stream channel \(streamChannelIndex.rawValue + 1)"
    case (.some(let streamID), .none):
      nativeMapping = "Native stream \(streamID.index.rawValue + 1)"
    case (.none, _):
      nativeMapping = nil
    }
  }
}

struct DeviceEndpointPresentation: Equatable, Identifiable {
  let id: AudioDeviceID
  let name: String
  let direction: AudioDirection
  let channelCount: Int
  let sampleRate: Double
  let isDefault: Bool
  let isAlive: Bool
  let isRunning: Bool
  let activeStreamCount: Int
  let channels: [DeviceChannelPresentation]

  init?(device: AudioDevice, direction: AudioDirection) {
    let endpoint =
      switch direction {
      case .input: device.input
      case .output: device.output
      }
    guard let endpoint else { return nil }

    id = device.id
    name = device.name
    self.direction = direction
    channelCount = endpoint.channelCount
    sampleRate = device.nominalSampleRate
    isDefault = endpoint.isDefault
    isAlive = device.isAlive
    isRunning = device.isRunning
    activeStreamCount = endpoint.streams.count(where: \.isActive)
    channels = endpoint.channels.map(DeviceChannelPresentation.init)
  }

  var detail: String {
    let rate = sampleRate.formatted(.number.precision(.fractionLength(0)))
    let channels = channelCount == 1 ? "1 channel" : "\(channelCount) channels"
    return "\(channels) · \(rate) Hz"
  }
}
