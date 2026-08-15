import Foundation

enum RoutingConnectionLabelFormatter {
  static func label(
    level: RoutingConnectionInformationLevel,
    source: RoutingGraphPortValue,
    target: RoutingGraphPortValue,
    targetNode: RoutingNodeValue,
    format: RoutingAudioCaptureFormat?
  ) -> String? {
    guard level != .hidden else { return nil }

    let route = routeDescription(
      source: source,
      target: target,
      targetNode: targetNode,
      format: format
    )
    guard level == .format else { return route }
    guard source.signalType == .audio, target.signalType == .audio else { return route }
    guard let format else { return route }
    return "\(route) · \(sampleRateDescription(format.sampleRate))"
  }

  private static func routeDescription(
    source: RoutingGraphPortValue,
    target: RoutingGraphPortValue,
    targetNode: RoutingNodeValue,
    format: RoutingAudioCaptureFormat?
  ) -> String {
    let sourceDescription = sourceDescription(source, format: format)
    guard case .visualizer = targetNode else {
      return "\(sourceDescription) → \(target.shortLabel)"
    }

    let destination =
      switch target.audioChannel {
      case .some(.all):
        "Mix Input"
      case .some(.channel(let index)):
        "Lane \(index + 1)"
      case .none:
        target.shortLabel
      }
    if source.audioChannel == .all, target.audioChannel == .all {
      return sourceDescription
    }
    return "\(sourceDescription) → \(destination)"
  }

  private static func sourceDescription(
    _ source: RoutingGraphPortValue,
    format: RoutingAudioCaptureFormat?
  ) -> String {
    guard source.audioChannel == .all else { return source.shortLabel }
    guard let count = format?.channelIDs.count else { return "All ch" }
    return "\(count) ch"
  }

  private static func sampleRateDescription(_ sampleRate: Double) -> String {
    let kilohertz = sampleRate / 1_000
    let rounded = kilohertz.rounded()
    if abs(kilohertz - rounded) < 0.000_1 {
      return "\(Int(rounded)) kHz"
    }
    return String(format: "%.1f kHz", locale: Locale(identifier: "en_US_POSIX"), kilohertz)
  }
}
