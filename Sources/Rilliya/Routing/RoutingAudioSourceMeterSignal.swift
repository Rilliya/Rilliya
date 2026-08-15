import Foundation
import RilliyaKit

struct RoutingAudioChannelMeterSignal: Equatable, Identifiable, Sendable {
  static let minimumDisplayedDecibels: Float = -60

  let channelIndex: Int
  let rootMeanSquare: Float
  let peak: Float
  let isClipping: Bool

  var id: Int { channelIndex }

  var rootMeanSquareDecibels: Float {
    Self.decibels(for: rootMeanSquare)
  }

  var peakDecibels: Float {
    Self.decibels(for: peak)
  }

  var normalizedLevel: Float {
    let decibels = max(rootMeanSquareDecibels, Self.minimumDisplayedDecibels)
    return min(
      max((decibels - Self.minimumDisplayedDecibels) / -Self.minimumDisplayedDecibels, 0), 1)
  }

  var decibelsDescription: String {
    guard peak > 0 else { return "−∞" }
    return String(
      format: "%.1f",
      locale: Locale(identifier: "en_US_POSIX"),
      peakDecibels
    )
  }

  private static func decibels(for amplitude: Float) -> Float {
    guard amplitude.isFinite, amplitude > 0 else { return -.infinity }
    return 20 * log10(amplitude)
  }
}

enum RoutingAudioSourceMeterSignalBuilder {
  static func build(
    channelCount: Int,
    snapshot: (any RoutingAudioMeterSnapshot)?,
    controls: [Int: RoutingAudioChannelControl] = [:]
  ) -> [RoutingAudioChannelMeterSignal] {
    let snapshotsByIndex = Dictionary(
      uniqueKeysWithValues: (snapshot?.channels ?? []).map {
        ($0.channelID.index.rawValue, $0)
      }
    )
    return (0..<max(channelCount, 1)).map { channelIndex in
      let channel = snapshotsByIndex[channelIndex]
      let gain = (controls[channelIndex] ?? .unity).linearGain
      let rootMeanSquare = finiteNonnegative(channel?.rootMeanSquare) * gain
      let peak = finiteNonnegative(channel?.peak) * gain
      return RoutingAudioChannelMeterSignal(
        channelIndex: channelIndex,
        rootMeanSquare: rootMeanSquare,
        peak: peak,
        isClipping: channel?.isClipping == true || peak >= 1
      )
    }
  }

  private static func finiteNonnegative(_ value: Float?) -> Float {
    guard let value, value.isFinite else { return 0 }
    return max(value, 0)
  }
}
