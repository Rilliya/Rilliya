import Foundation
import Observation

enum RoutingConnectionInformationLevel: String, CaseIterable, Hashable, Sendable {
  case hidden
  case channels
  case format
}

enum RoutingSeparateChannelLayout: String, CaseIterable, Hashable, Sendable {
  case native
  case stereo
  case quadraphonic
  case surround51
  case surround71

  var channelCount: Int? {
    switch self {
    case .native:
      nil
    case .stereo:
      2
    case .quadraphonic:
      4
    case .surround51:
      6
    case .surround71:
      8
    }
  }
}

@MainActor
@Observable
final class RilliyaSettings {
  static let shared = RilliyaSettings()

  var connectionInformationLevel: RoutingConnectionInformationLevel {
    didSet {
      defaults.set(
        connectionInformationLevel.rawValue,
        forKey: Keys.connectionInformationLevel
      )
    }
  }

  var defaultSeparateChannelLayout: RoutingSeparateChannelLayout {
    didSet {
      defaults.set(
        defaultSeparateChannelLayout.rawValue,
        forKey: Keys.defaultSeparateChannelLayout
      )
    }
  }

  var showsMiniMapByDefault: Bool {
    didSet {
      defaults.set(showsMiniMapByDefault, forKey: Keys.showsMiniMapByDefault)
    }
  }

  @ObservationIgnored private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    connectionInformationLevel =
      defaults.string(forKey: Keys.connectionInformationLevel)
      .flatMap(RoutingConnectionInformationLevel.init(rawValue:))
      ?? .format
    defaultSeparateChannelLayout =
      defaults.string(forKey: Keys.defaultSeparateChannelLayout)
      .flatMap(RoutingSeparateChannelLayout.init(rawValue:))
      ?? .stereo
    showsMiniMapByDefault =
      defaults.object(forKey: Keys.showsMiniMapByDefault) as? Bool
      ?? true
  }

  private enum Keys {
    static let connectionInformationLevel =
      "moe.uwucocoa.rilliya.connection-information-level"
    static let defaultSeparateChannelLayout =
      "moe.uwucocoa.rilliya.default-separate-channel-layout"
    static let showsMiniMapByDefault =
      "moe.uwucocoa.rilliya.shows-minimap-by-default"
  }
}
