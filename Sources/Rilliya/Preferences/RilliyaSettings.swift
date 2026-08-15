import Foundation
import Observation

enum RoutingConnectionInformationLevel: String, CaseIterable, Hashable, Sendable {
  case hidden
  case channels
  case format
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

  @ObservationIgnored private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    connectionInformationLevel =
      defaults.string(forKey: Keys.connectionInformationLevel)
      .flatMap(RoutingConnectionInformationLevel.init(rawValue:))
      ?? .format
  }

  private enum Keys {
    static let connectionInformationLevel =
      "moe.uwucocoa.rilliya.connection-information-level"
  }
}
