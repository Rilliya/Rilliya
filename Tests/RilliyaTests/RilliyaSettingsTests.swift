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

    first.connectionInformationLevel = .channels
    first.defaultSeparateChannelLayout = .surround71
    let restored = RilliyaSettings(defaults: defaults)

    #expect(restored.connectionInformationLevel == .channels)
    #expect(restored.defaultSeparateChannelLayout == .surround71)
    #expect(!RoutingConnectionInformationLevel.allCases.map(\.rawValue).contains("debug"))
  }
}
