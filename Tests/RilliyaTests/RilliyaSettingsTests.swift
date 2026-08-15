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
    #expect(first.connectionInformationLevel == .format)
    #expect(first.defaultSeparateChannelLayout == .stereo)
    #expect(first.showsMiniMapByDefault)

    first.connectionInformationLevel = .channels
    first.defaultSeparateChannelLayout = .surround71
    first.showsMiniMapByDefault = false
    let restored = RilliyaSettings(defaults: defaults)

    #expect(restored.connectionInformationLevel == .channels)
    #expect(restored.defaultSeparateChannelLayout == .surround71)
    #expect(!restored.showsMiniMapByDefault)
    #expect(!RoutingConnectionInformationLevel.allCases.map(\.rawValue).contains("debug"))
  }
}
