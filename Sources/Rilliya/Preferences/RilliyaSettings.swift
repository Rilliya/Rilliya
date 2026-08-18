import Foundation
import Observation
import RilliyaRealtime

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

struct RoutingNetworkSendParameterDefaults: Codable, Equatable, Sendable {
  var wireEncoding: RoutingNetworkWireEncoding?
  var bitRate: Int?
  var sampleRate: Double?
  var channelCount: Int?

  static let empty = RoutingNetworkSendParameterDefaults()

  var enabledCount: Int {
    [
      wireEncoding != nil,
      bitRate != nil,
      sampleRate != nil,
      channelCount != nil,
    ].filter { $0 }.count
  }

  var isEmpty: Bool {
    enabledCount == 0
  }

  func applying(to configuration: RoutingNetworkSendConfiguration)
    -> RoutingNetworkSendConfiguration
  {
    var updated = configuration
    if let wireEncoding { updated.wire.encoding = wireEncoding }
    if let bitRate { updated.wire.bitRate = bitRate }
    if let sampleRate { updated.sampleRate = sampleRate }
    if let channelCount { updated.channelCount = channelCount }
    return updated
  }
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

  var showsWorkflowsInStatusMenu: Bool {
    didSet {
      defaults.set(showsWorkflowsInStatusMenu, forKey: Keys.showsWorkflowsInStatusMenu)
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

  /// How many times a second a waveform reports what it has heard.
  ///
  /// Thirty is what a capture device meters itself at and what a canvas can draw without waking
  /// for nothing. Sixty and a hundred and twenty are there for a display that can show them; past
  /// its refresh rate the extra reports are drawn over before anyone sees them.
  ///
  /// Only values below one are refused, because a rate of zero is not a preference. A number a
  /// machine cannot keep up with is a choice, and one this is not entitled to overrule.
  var waveformUpdatesPerSecond: Int {
    didSet {
      let bounded = max(waveformUpdatesPerSecond, Self.minimumWaveformUpdatesPerSecond)
      if bounded != waveformUpdatesPerSecond {
        waveformUpdatesPerSecond = bounded
        return
      }
      defaults.set(waveformUpdatesPerSecond, forKey: Keys.waveformUpdatesPerSecond)
    }
  }

  /// The rates offered without typing one.
  static let waveformUpdatePresets = [30, 60, 120]

  /// The slowest rate that still reports; below this nothing would ever be drawn.
  static let minimumWaveformUpdatesPerSecond = 1

  /// Where a newly entered network audio key is put.
  ///
  /// The Keychain keeps the key out of the workflow file, at the cost of one access prompt per
  /// build whose code signature the Keychain has not seen before. A development build is signed
  /// afresh every time, which is why the workflow file remains an option.
  var networkAudioKeySourceID: String {
    didSet {
      defaults.set(networkAudioKeySourceID, forKey: Keys.networkAudioSecretStore)
    }
  }

  private(set) var nodeAccentOverrides: [RoutingNodeKind: RoutingAccentID]
  private(set) var nodeParameterDefaults: [RoutingNodeKind: RoutingNodeParameterDefaults]

  var networkSendParameterDefaults: RoutingNetworkSendParameterDefaults {
    guard case .networkSend(let defaults) = nodeParameterDefaults[.networkSend] else {
      return .empty
    }
    return defaults
  }

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
    showsWorkflowsInStatusMenu =
      defaults.object(forKey: Keys.showsWorkflowsInStatusMenu) as? Bool
      ?? true
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
    waveformUpdatesPerSecond = max(
      defaults.object(forKey: Keys.waveformUpdatesPerSecond) as? Int
        ?? AudioWaveformMeter.defaultUpdatesPerSecond,
      Self.minimumWaveformUpdatesPerSecond
    )
    networkAudioKeySourceID =
      defaults.string(forKey: Keys.networkAudioSecretStore)
      ?? RoutingKeychainKeySource.identifier
    nodeAccentOverrides = Self.decodeNodeAccentOverrides(
      defaults.dictionary(forKey: Keys.nodeAccentOverrides) ?? [:]
    )
    nodeParameterDefaults = Self.decodeNodeParameterDefaults(
      defaults.dictionary(forKey: Keys.nodeParameterDefaults) ?? [:]
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

  func setNetworkSendParameterDefaults(_ parameterDefaults: RoutingNetworkSendParameterDefaults) {
    setNodeParameterDefaults(.networkSend(parameterDefaults))
  }

  func parameterDefaults(for kind: RoutingNodeKind) -> RoutingNodeParameterDefaults? {
    nodeParameterDefaults[kind]
  }

  func setNodeParameterDefaults(_ parameterDefaults: RoutingNodeParameterDefaults) {
    let kind = parameterDefaults.kind
    let storedValue = parameterDefaults.isEmpty ? nil : parameterDefaults
    guard nodeParameterDefaults[kind] != storedValue else { return }
    var updated = nodeParameterDefaults
    updated[kind] = storedValue
    nodeParameterDefaults = updated

    var stored = defaults.dictionary(forKey: Keys.nodeParameterDefaults) ?? [:]
    if parameterDefaults.isEmpty {
      stored[kind.rawValue] = nil
    } else if let storedValue, let encoded = try? JSONEncoder().encode(storedValue) {
      stored[kind.rawValue] = encoded
    } else {
      stored[kind.rawValue] = nil
    }
    defaults.set(stored, forKey: Keys.nodeParameterDefaults)
  }

  func applyingParameterDefaults(to value: RoutingNodeValue) -> RoutingNodeValue {
    nodeParameterDefaults[value.kind]?.applying(to: value) ?? value
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

  nonisolated private static func decodeNodeParameterDefaults(
    _ dictionary: [String: Any]
  ) -> [RoutingNodeKind: RoutingNodeParameterDefaults] {
    dictionary.reduce(into: [:]) { result, entry in
      guard let kind = RoutingNodeKind(rawValue: entry.key), let data = entry.value as? Data else {
        return
      }
      if let decoded = try? JSONDecoder().decode(RoutingNodeParameterDefaults.self, from: data),
        decoded.kind == kind, !decoded.isEmpty
      {
        result[kind] = decoded
      } else if kind == .networkSend,
        let legacy = try? JSONDecoder().decode(
          RoutingNetworkSendParameterDefaults.self, from: data),
        !legacy.isEmpty
      {
        result[kind] = .networkSend(legacy)
      }
    }
  }

  private enum Keys {
    static let appearance = "moe.uwucocoa.rilliya.appearance"
    static let showsInDock = "moe.uwucocoa.rilliya.shows-in-dock"
    static let showsInStatusBar = "moe.uwucocoa.rilliya.shows-in-status-bar"
    static let showsWorkflowsInStatusMenu =
      "moe.uwucocoa.rilliya.shows-workflows-in-status-menu"
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
    static let nodeParameterDefaults =
      "moe.uwucocoa.rilliya.node-parameter-defaults"
    static let networkAudioSecretStore =
      "moe.uwucocoa.rilliya.network-audio-secret-store"
    static let waveformUpdatesPerSecond =
      "moe.uwucocoa.rilliya.waveform-updates-per-second"
  }
}
