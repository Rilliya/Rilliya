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

    first.connectionInformationLevel = .channels
    let restored = RilliyaSettings(defaults: defaults)

    #expect(restored.connectionInformationLevel == .channels)
    #expect(!RoutingConnectionInformationLevel.allCases.map(\.rawValue).contains("debug"))
  }
}
