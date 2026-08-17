import Foundation
import RilliyaNetworkAudio
import Testing

@testable import Rilliya

@Suite("Routing network audio secret")
struct RoutingNetworkAudioSecretTests {
  @Test("A generated secret resolves to a usable key")
  func generatedSecretResolves() throws {
    let secret = RoutingNetworkAudioSecret.generated()

    #expect(secret.isValid)
    #expect(try secret.resolve().base64EncodedString == secret.base64EncodedString)
  }

  @Test("Two generated secrets differ")
  func generatedSecretsDiffer() {
    #expect(RoutingNetworkAudioSecret.generated() != RoutingNetworkAudioSecret.generated())
  }

  @Test(
    "Text that is not a key is refused rather than silently disabling encryption",
    arguments: ["", "hunter2", "c2hvcnQ="]
  )
  func invalidTextIsRefused(text: String) {
    let secret = RoutingNetworkAudioSecret.inline(base64: text)

    #expect(!secret.isValid)
    #expect(throws: (any Error).self) { _ = try secret.resolve() }
  }

  /// The case is tagged so a later store can be added without rewriting saved workflows.
  @Test("A secret round-trips through a saved workflow")
  func secretSurvivesPersistence() throws {
    let secret = RoutingNetworkAudioSecret.generated()
    let configuration = RoutingNetworkSendConfiguration(
      host: "10.0.0.2",
      port: 48_620,
      sampleRate: 48_000,
      channelCount: 2,
      secret: secret
    )

    let encoded = try JSONEncoder().encode(configuration)
    let decoded = try JSONDecoder().decode(RoutingNetworkSendConfiguration.self, from: encoded)

    #expect(decoded == configuration)
    #expect(decoded.secret == secret)
    #expect(String(data: encoded, encoding: .utf8)?.contains("inline") == true)
  }

  @Test("A configuration without a secret still decodes")
  func absentSecretDecodes() throws {
    let json = """
      {"host":"10.0.0.2","port":48620,"sampleRate":48000,"channelCount":2}
      """
    let decoded = try JSONDecoder().decode(
      RoutingNetworkSendConfiguration.self,
      from: Data(json.utf8)
    )

    #expect(decoded.secret == nil)
  }

  /// A configuration reaching a log must not carry the key with it.
  @Test("A secret redacts itself when printed")
  func secretRedactsItself() {
    let secret = RoutingNetworkAudioSecret.generated()

    #expect(!"\(secret)".contains(secret.base64EncodedString))
    #expect("\(secret)".contains("redacted"))
  }
}
