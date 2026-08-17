import Foundation
import RilliyaNetworkAudio
import Testing

@testable import Rilliya

@Suite("Routing network audio secret")
struct RoutingNetworkAudioSecretTests {
  @Test("A generated inline secret resolves to a usable key")
  func generatedSecretResolves() throws {
    let secret = try RoutingNetworkAudioSecret.generated(in: .inline)

    #expect(secret.isValid)
    #expect(try secret.resolve().base64EncodedString == secret.revealBase64())
  }

  @Test("Two generated secrets differ")
  func generatedSecretsDiffer() throws {
    #expect(
      try RoutingNetworkAudioSecret.generated(in: .inline)
        != RoutingNetworkAudioSecret.generated(in: .inline)
    )
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

  /// The case is tagged so a store can be added without rewriting saved workflows.
  @Test("An inline secret round-trips through a saved workflow")
  func secretSurvivesPersistence() throws {
    let secret = try RoutingNetworkAudioSecret.generated(in: .inline)
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

  /// A configuration reaching a log must not carry the key with it.
  @Test("A secret redacts itself when printed")
  func secretRedactsItself() throws {
    let secret = try RoutingNetworkAudioSecret.generated(in: .inline)

    #expect(!"\(secret)".contains(try secret.revealBase64()))
    #expect("\(secret)".contains("redacted"))
  }

  /// The point of the Keychain store is that the document stops carrying the key.
  @Test("A Keychain secret keeps the key out of the workflow file")
  func keychainSecretIsNotInTheDocument() throws {
    let secret = RoutingNetworkAudioSecret.keychain(reference: "9F0A-not-a-real-item")

    #expect(secret.inlineBase64 == nil)

    let encoded = try JSONEncoder().encode(secret)
    let json = try #require(String(data: encoded, encoding: .utf8))

    #expect(json.contains("keychain"))
    #expect(json.contains("9F0A-not-a-real-item"))
    #expect(try JSONDecoder().decode(RoutingNetworkAudioSecret.self, from: encoded) == secret)
  }

  /// A document naming an item that is gone must report it, not decode into a silent plaintext
  /// stream.
  @Test("A Keychain secret whose item is missing does not resolve")
  func missingKeychainItemDoesNotResolve() {
    let secret = RoutingNetworkAudioSecret.keychain(
      reference: "absent-\(UUID().uuidString)"
    )

    #expect(!secret.isValid)
    #expect(throws: RoutingNetworkAudioKeychainError.notFound) { _ = try secret.resolve() }
  }

  @Test("Discarding an inline secret leaves nothing to clean up")
  func discardingInlineSecretSucceeds() throws {
    #expect(throws: Never.self) {
      try RoutingNetworkAudioSecret.generated(in: .inline).discard()
    }
  }

  @Test("The inline store puts a pasted key in the document")
  func inlineStoreKeepsTheKeyInTheDocument() throws {
    let key = NetworkAudioSharedKey.random()

    #expect(
      try RoutingNetworkAudioSecretStore.inline.save(key)
        == .inline(base64: key.base64EncodedString))
  }

  @Test(
    "The Keychain store puts a pasted key outside the document",
    .enabled(if: KeychainAvailability.isUsable)
  )
  func keychainStoreKeepsTheKeyOutOfTheDocument() throws {
    let key = NetworkAudioSharedKey.random()
    let stored = try RoutingNetworkAudioSecretStore.keychain.save(key)
    defer { try? stored.discard() }

    guard case .keychain(let reference) = stored else {
      Issue.record("the Keychain store produced \(stored)")
      return
    }
    #expect(!reference.isEmpty)
    #expect(stored.inlineBase64 == nil)
    #expect(try stored.revealBase64() == key.base64EncodedString)
  }

  @Test(
    "A key stored in the Keychain round-trips and can be removed again",
    .enabled(if: KeychainAvailability.isUsable)
  )
  func keychainRoundTrip() throws {
    let key = NetworkAudioSharedKey.random()
    let reference = RoutingNetworkAudioKeychain.makeReference()

    try RoutingNetworkAudioKeychain.store(key, reference: reference)
    #expect(
      try RoutingNetworkAudioKeychain.read(reference: reference).base64EncodedString
        == key.base64EncodedString
    )

    try RoutingNetworkAudioKeychain.remove(reference: reference)
    #expect(throws: RoutingNetworkAudioKeychainError.notFound) {
      _ = try RoutingNetworkAudioKeychain.read(reference: reference)
    }
  }

  @Test(
    "Storing twice under one reference replaces rather than duplicating",
    .enabled(if: KeychainAvailability.isUsable)
  )
  func keychainStoreReplaces() throws {
    let reference = RoutingNetworkAudioKeychain.makeReference()
    defer { try? RoutingNetworkAudioKeychain.remove(reference: reference) }

    try RoutingNetworkAudioKeychain.store(.random(), reference: reference)
    let replacement = NetworkAudioSharedKey.random()
    try RoutingNetworkAudioKeychain.store(replacement, reference: reference)

    #expect(
      try RoutingNetworkAudioKeychain.read(reference: reference).base64EncodedString
        == replacement.base64EncodedString
    )
  }

  @Test(
    "Removing an item that is already gone is not an error",
    .enabled(if: KeychainAvailability.isUsable)
  )
  func keychainRemoveIsIdempotent() throws {
    #expect(throws: Never.self) {
      try RoutingNetworkAudioKeychain.remove(reference: "absent-\(UUID().uuidString)")
    }
  }

}

/// Whether this machine can exercise the Keychain store.
///
/// A locked or absent login Keychain cannot, and leaving those tests unrun there is more honest
/// than a red build. Probed once, because the probe itself writes.
enum KeychainAvailability {
  static let isUsable: Bool = {
    let probe = RoutingNetworkAudioKeychain.makeReference()
    do {
      try RoutingNetworkAudioKeychain.store(.random(), reference: probe)
      try RoutingNetworkAudioKeychain.remove(reference: probe)
      return true
    } catch {
      return false
    }
  }()
}
