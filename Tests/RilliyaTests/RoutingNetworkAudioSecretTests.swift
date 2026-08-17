import Foundation
import RilliyaNetworkAudio
import Testing

@testable import Rilliya

/// Where a node's shared key comes from, which is open rather than a choice between two.
///
/// The two built in keep a key the person made. Anything else — a key released after a sign-in,
/// one held by a service — registers itself and works the same way, which is what these check.
@Suite("Routing network audio secret", .serialized)
@MainActor
struct RoutingNetworkAudioSecretTests {
  private static let inline = RoutingInlineKeySource()
  private static let keychain = RoutingKeychainKeySource()

  // MARK: Keeping a key

  @Test("A generated secret resolves to a usable key")
  func generatedSecretResolves() async throws {
    let secret = try RoutingNetworkAudioSecret.generated(in: Self.inline)

    let key = try await secret.provider().sharedKey()
    #expect(key.base64EncodedString.count > 0)
    #expect(secret.isValid)
  }

  @Test("Two generated secrets differ")
  func generatedSecretsDiffer() async throws {
    let first = try RoutingNetworkAudioSecret.generated(in: Self.inline)
    let second = try RoutingNetworkAudioSecret.generated(in: Self.inline)

    #expect(try await first.provider().sharedKey() != second.provider().sharedKey())
  }

  @Test(
    "Text that is not a whole key is refused",
    arguments: ["", "not base64!!", "c2hvcnQ="]
  )
  func invalidTextIsRefused(text: String) {
    #expect(throws: (any Error).self) {
      _ = try RoutingNetworkAudioSecret.stored(
        try NetworkAudioSharedKey(base64Encoded: text),
        in: Self.inline
      )
    }
  }

  // MARK: Where the key ends up

  @Test("The workflow-file source keeps the key in the document")
  func inlineSourceKeepsTheKeyInTheDocument() throws {
    let secret = try RoutingNetworkAudioSecret.generated(in: Self.inline)

    #expect(secret.sourceID == RoutingInlineKeySource.identifier)
    #expect(secret.inlineBase64 != nil)
    // Asked of the decoded document rather than of the encoded text: JSONEncoder escapes a
    // forward slash, which a base64 key carries about half the time, so a substring search over
    // the text fails for half of all keys and passes for the other half.
    let decoded = try JSONDecoder().decode(
      RoutingNetworkAudioSecret.self,
      from: try JSONEncoder().encode(secret)
    )
    #expect(decoded.parameters["base64"] == secret.inlineBase64)
  }

  @Test("The Keychain source keeps the key out of the document")
  func keychainSourceKeepsTheKeyOutOfTheDocument() async throws {
    let secret: RoutingNetworkAudioSecret
    do {
      secret = try RoutingNetworkAudioSecret.generated(in: Self.keychain)
    } catch {
      // A machine without a usable Keychain cannot answer this question either way.
      return
    }
    defer { try? secret.discard() }

    #expect(secret.sourceID == RoutingKeychainKeySource.identifier)
    #expect(secret.inlineBase64 == nil, "the key was in the document after all")
    let key = try await secret.provider().sharedKey()
    let decoded = try JSONDecoder().decode(
      RoutingNetworkAudioSecret.self,
      from: try JSONEncoder().encode(secret)
    )
    #expect(!decoded.parameters.values.contains(key.base64EncodedString))
  }

  @Test("A Keychain secret whose item is gone does not resolve")
  func missingKeychainItemDoesNotResolve() {
    let secret = RoutingNetworkAudioSecret(
      sourceID: RoutingKeychainKeySource.identifier,
      parameters: ["reference": "moe.uwucocoa.rilliya.tests.\(UUID().uuidString)"]
    )

    #expect(!secret.isValid)
  }

  // MARK: Persistence

  @Test("A secret round-trips through a saved workflow")
  func secretSurvivesPersistence() async throws {
    let secret = try RoutingNetworkAudioSecret.generated(in: Self.inline)

    let decoded = try JSONDecoder().decode(
      RoutingNetworkAudioSecret.self,
      from: try JSONEncoder().encode(secret)
    )

    #expect(decoded == secret)
    #expect(try await decoded.provider().sharedKey() == secret.provider().sharedKey())
  }

  @Test("A secret redacts itself when printed")
  func secretRedactsItself() throws {
    let secret = try RoutingNetworkAudioSecret.generated(in: Self.inline)
    let key = try #require(secret.inlineBase64)

    #expect(!"\(secret)".contains(key))
    #expect(!String(reflecting: secret).contains(key))
  }

  // MARK: A source nobody here wrote

  /// The point of the whole shape: something registered from outside works as the built-in two do.
  @Test("A registered source supplies a key like any other")
  func registeredSourceWorks() async throws {
    let key = NetworkAudioSharedKey.random()
    let registry = RoutingNetworkAudioKeySourceRegistry(sources: [FetchingSource(key: key)])
    let source = try registry.require(FetchingSource.identifier)

    let secret = RoutingNetworkAudioSecret(sourceID: source.id, parameters: ["account": "someone"])
    let provider = try source.provider(for: secret.parameters)

    #expect(try await provider.sharedKey() == key)
    #expect(registry.all.map(\.id) == [FetchingSource.identifier])
  }

  /// A source that fetches its key has nothing to be handed and nothing to copy across.
  @Test("A fetching source refuses a key and offers nothing to copy")
  func fetchingSourceHoldsNothing() throws {
    let source = FetchingSource(key: .random())

    #expect(!source.acceptsProvidedKeys)
    #expect(try source.revealBase64(for: ["account": "someone"]) == nil)
    #expect(throws: RoutingNetworkAudioKeySourceError.cannotStoreKeys(sourceID: source.id)) {
      _ = try RoutingNetworkAudioSecret.stored(.random(), in: source)
    }
  }

  /// A document naming a source nothing registered says so rather than losing the reference.
  @Test("A document naming an unregistered source reports it")
  func unregisteredSourceIsReported() {
    let secret = RoutingNetworkAudioSecret(
      sourceID: "com.example.absent",
      parameters: [:]
    )

    #expect(!secret.isValid)
    #expect(throws: RoutingNetworkAudioKeySourceError.unknownSource(id: "com.example.absent")) {
      _ = try secret.provider()
    }
  }

  @Test("Registering under an identifier already taken replaces it")
  func registeringReplaces() throws {
    let registry = RoutingNetworkAudioKeySourceRegistry(sources: [])
    let first = FetchingSource(key: .random())
    let second = FetchingSource(key: .random())

    registry.register(first)
    registry.register(second)

    #expect(registry.all.count == 1)
    let resolved = try registry.require(FetchingSource.identifier)
    #expect(try resolved.provider(for: [:]) is FetchingProvider)
  }

  /// Stands in for anything that goes and gets its key — a sign-in, a service, a token.
  private struct FetchingSource: RoutingNetworkAudioKeySource {
    static let identifier = "com.example.fetching"
    let key: NetworkAudioSharedKey

    var id: String { Self.identifier }
    var displayName: String { "Example Account" }
    var explanation: String { "Fetches the key for the signed-in account." }
    var acceptsProvidedKeys: Bool { false }

    func store(_ key: NetworkAudioSharedKey) throws -> [String: String] {
      throw RoutingNetworkAudioKeySourceError.cannotStoreKeys(sourceID: id)
    }

    func provider(for parameters: [String: String]) throws -> any NetworkAudioKeyProvider {
      FetchingProvider(key: key)
    }

    func revealBase64(for parameters: [String: String]) throws -> String? { nil }

    func discard(for parameters: [String: String]) throws {}
  }

  private struct FetchingProvider: NetworkAudioKeyProvider {
    let key: NetworkAudioSharedKey

    func sharedKey() async throws -> NetworkAudioSharedKey {
      // Whatever a real one would do — sign in, call a service — takes time.
      try await Task.sleep(for: .milliseconds(1))
      return key
    }
  }
}
