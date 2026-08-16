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

enum RilliyaAppearance: String, CaseIterable, Hashable, Sendable {
  case system
  case light
  case dark
}

@MainActor
@Observable
final class RilliyaSettings {
  static let shared = RilliyaSettings()

  var appearance: RilliyaAppearance {
    didSet {
      defaults.set(appearance.rawValue, forKey: Keys.appearance)
    }
  }

  private(set) var showsInDock: Bool {
    didSet {
      defaults.set(showsInDock, forKey: Keys.showsInDock)
    }
  }

  private(set) var showsInStatusBar: Bool {
    didSet {
      defaults.set(showsInStatusBar, forKey: Keys.showsInStatusBar)
    }
  }

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

  var showsDisabledPortCrosses: Bool {
    didSet {
      defaults.set(showsDisabledPortCrosses, forKey: Keys.showsDisabledPortCrosses)
    }
  }

  var addsNodesOnPaletteClick: Bool {
    didSet {
      defaults.set(addsNodesOnPaletteClick, forKey: Keys.addsNodesOnPaletteClick)
    }
  }

  private(set) var nodeAccentOverrides: [RoutingNodeKind: RoutingAccentID]

  @ObservationIgnored private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    appearance =
      defaults.string(forKey: Keys.appearance)
      .flatMap(RilliyaAppearance.init(rawValue:))
      ?? .system
    let storedShowsInDock = defaults.object(forKey: Keys.showsInDock) as? Bool ?? true
    let storedShowsInStatusBar =
      defaults.object(forKey: Keys.showsInStatusBar) as? Bool ?? false
    if storedShowsInDock || storedShowsInStatusBar {
      showsInDock = storedShowsInDock
      showsInStatusBar = storedShowsInStatusBar
    } else {
      showsInDock = true
      showsInStatusBar = false
    }
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
    showsDisabledPortCrosses =
      defaults.object(forKey: Keys.showsDisabledPortCrosses) as? Bool
      ?? true
    addsNodesOnPaletteClick =
      defaults.object(forKey: Keys.addsNodesOnPaletteClick) as? Bool
      ?? false
    nodeAccentOverrides = Self.decodeNodeAccentOverrides(
      defaults.dictionary(forKey: Keys.nodeAccentOverrides) ?? [:]
    )
  }

  func setShowsInDock(_ isVisible: Bool) {
    guard showsInDock != isVisible else { return }
    if !isVisible, !showsInStatusBar {
      showsInStatusBar = true
    }
    showsInDock = isVisible
  }

  func setShowsInStatusBar(_ isVisible: Bool) {
    guard showsInStatusBar != isVisible else { return }
    if !isVisible, !showsInDock {
      showsInDock = true
    }
    showsInStatusBar = isVisible
  }

  func nodeAccentOverride(for kind: RoutingNodeKind) -> RoutingAccentID? {
    nodeAccentOverrides[kind]
  }

  func setNodeAccentOverride(_ accentID: RoutingAccentID?, for kind: RoutingNodeKind) {
    guard nodeAccentOverrides[kind] != accentID else { return }
    var updated = nodeAccentOverrides
    updated[kind] = accentID
    nodeAccentOverrides = updated
    defaults.set(
      Dictionary(uniqueKeysWithValues: updated.map { ($0.key.rawValue, $0.value.rawValue) }),
      forKey: Keys.nodeAccentOverrides
    )
  }

  func resolvedAccentID(for kind: RoutingNodeKind) -> RoutingAccentID {
    RoutingNodeAccentResolver.resolve(
      nodeOverride: nil,
      typeOverride: nodeAccentOverrides[kind],
      kind: kind
    )
  }

  nonisolated private static func decodeNodeAccentOverrides(
    _ dictionary: [String: Any]
  ) -> [RoutingNodeKind: RoutingAccentID] {
    dictionary.reduce(into: [:]) { result, entry in
      guard let kind = RoutingNodeKind(rawValue: entry.key),
        let rawAccent = entry.value as? String,
        let accent = RoutingAccentID(rawValue: rawAccent)
      else { return }
      result[kind] = accent
    }
  }

  private enum Keys {
    static let appearance = "moe.uwucocoa.rilliya.appearance"
    static let showsInDock = "moe.uwucocoa.rilliya.shows-in-dock"
    static let showsInStatusBar = "moe.uwucocoa.rilliya.shows-in-status-bar"
    static let connectionInformationLevel =
      "moe.uwucocoa.rilliya.connection-information-level"
    static let defaultSeparateChannelLayout =
      "moe.uwucocoa.rilliya.default-separate-channel-layout"
    static let showsMiniMapByDefault =
      "moe.uwucocoa.rilliya.shows-minimap-by-default"
    static let showsDisabledPortCrosses =
      "moe.uwucocoa.rilliya.shows-disabled-port-crosses"
    static let addsNodesOnPaletteClick =
      "moe.uwucocoa.rilliya.adds-nodes-on-palette-click"
    static let nodeAccentOverrides =
      "moe.uwucocoa.rilliya.node-accent-overrides"
  }
}
