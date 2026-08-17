import Foundation
import Testing

@testable import Rilliya

@Suite("Rilliya settings")
struct RilliyaSettingsTests {
  @Test @MainActor
  func connectionInformationPersistsWithoutUsingDebugTerminology() throws {
    let suiteName = "moe.uwucocoa.rilliya.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let first = RilliyaSettings(defaults: defaults)
    #expect(first.appearance == .system)
    #expect(first.showsInDock)
    #expect(!first.showsInStatusBar)
    #expect(first.showsWorkflowsInStatusMenu)
    #expect(first.connectionInformationLevel == .format)
    #expect(first.defaultSeparateChannelLayout == .stereo)
    #expect(first.showsMiniMapByDefault)
    #expect(first.showsDisabledPortCrosses)
    #expect(!first.addsNodesOnPaletteClick)
    #expect(first.nodeAccentOverrides.isEmpty)
    #expect(first.networkSendParameterDefaults == .empty)

    first.appearance = .dark
    first.setShowsInStatusBar(true)
    first.setShowsInDock(false)
    first.showsWorkflowsInStatusMenu = false
    first.connectionInformationLevel = .channels
    first.defaultSeparateChannelLayout = .surround71
    first.showsMiniMapByDefault = false
    first.showsDisabledPortCrosses = false
    first.addsNodesOnPaletteClick = true
    first.setNodeAccentOverride(.iris, for: .visualizer)
    first.setNodeAccentOverride(.mint, for: .inputAudio)
    let restored = RilliyaSettings(defaults: defaults)

    #expect(restored.appearance == .dark)
    #expect(!restored.showsInDock)
    #expect(restored.showsInStatusBar)
    #expect(!restored.showsWorkflowsInStatusMenu)
    #expect(restored.connectionInformationLevel == .channels)
    #expect(restored.defaultSeparateChannelLayout == .surround71)
    #expect(!restored.showsMiniMapByDefault)
    #expect(!restored.showsDisabledPortCrosses)
    #expect(restored.addsNodesOnPaletteClick)
    #expect(restored.nodeAccentOverride(for: .visualizer) == .iris)
    #expect(restored.nodeAccentOverride(for: .inputAudio) == .mint)
    #expect(restored.nodeAccentOverride(for: .delay) == nil)
    #expect(restored.resolvedAccentID(for: .delay) == .wisteria)
    #expect(!RoutingConnectionInformationLevel.allCases.map(\.rawValue).contains("debug"))
  }

  @Test @MainActor
  func networkSendParameterDefaultsPersistAndIgnoreUnreadableEntries() throws {
    let suiteName = "moe.uwucocoa.rilliya.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let first = RilliyaSettings(defaults: defaults)
    var parameterDefaults = RoutingNetworkSendParameterDefaults.empty
    parameterDefaults.wireEncoding = .opus
    parameterDefaults.bitRate = 96_000
    parameterDefaults.sampleRate = 48_000
    parameterDefaults.channelCount = 4
    first.setNetworkSendParameterDefaults(parameterDefaults)

    let restored = RilliyaSettings(defaults: defaults)
    #expect(restored.networkSendParameterDefaults == parameterDefaults)

    defaults.set(
      [RoutingNodeKind.networkSend.rawValue: "not encoded defaults"],
      forKey: "moe.uwucocoa.rilliya.node-parameter-defaults"
    )
    #expect(RilliyaSettings(defaults: defaults).networkSendParameterDefaults == .empty)
  }

  @Test @MainActor
  func networkSendNodesUseAndClearParameterDefaults() throws {
    let suiteName = "moe.uwucocoa.rilliya.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = RilliyaSettings(defaults: defaults)
    var parameterDefaults = RoutingNetworkSendParameterDefaults.empty
    parameterDefaults.wireEncoding = .opus
    parameterDefaults.bitRate = 96_000
    parameterDefaults.channelCount = 4
    settings.setNetworkSendParameterDefaults(parameterDefaults)
    let customizedWorkspace = RoutingWorkspaceModel(settings: settings)

    let customizedID = customizedWorkspace.addNetworkSendNode(centeredAt: .zero)
    let customized = try #require(customizedWorkspace.node(id: customizedID))
    guard case .networkSend(let customizedConfiguration) = customized.value else {
      Issue.record("Expected a network send node")
      return
    }
    #expect(customizedConfiguration.wire.encoding == .opus)
    #expect(customizedConfiguration.wire.bitRate == 96_000)
    #expect(customizedConfiguration.channelCount == 4)
    #expect(
      customizedConfiguration.sampleRate == RoutingNetworkSendConfiguration.initial.sampleRate)
    #expect(customizedConfiguration.host == RoutingNetworkSendConfiguration.initial.host)

    settings.setNetworkSendParameterDefaults(.empty)
    let resetWorkspace = RoutingWorkspaceModel(settings: settings)
    let resetID = resetWorkspace.addNetworkSendNode(centeredAt: .zero)
    #expect(
      resetWorkspace.node(id: resetID)?.value
        == .networkSend(configuration: RoutingNetworkSendConfiguration.initial)
    )
  }

  @Test @MainActor
  func applicationAlwaysKeepsOnePresentationSurfaceReachable() throws {
    let suiteName = "moe.uwucocoa.rilliya.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = RilliyaSettings(defaults: defaults)

    settings.setShowsInDock(false)
    #expect(!settings.showsInDock)
    #expect(settings.showsInStatusBar)

    settings.setShowsInStatusBar(false)
    #expect(settings.showsInDock)
    #expect(!settings.showsInStatusBar)
  }

  @Test @MainActor
  func resettingAnAccentReturnsToTheBuiltInDefault() throws {
    let suiteName = "moe.uwucocoa.rilliya.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let settings = RilliyaSettings(defaults: defaults)

    settings.setNodeAccentOverride(.fuchsia, for: .signalGenerator)
    #expect(settings.resolvedAccentID(for: .signalGenerator) == .fuchsia)

    settings.setNodeAccentOverride(nil, for: .signalGenerator)
    #expect(settings.nodeAccentOverride(for: .signalGenerator) == nil)
    #expect(settings.resolvedAccentID(for: .signalGenerator) == .poppy)
  }
}
