import Foundation
import RilliyaNetworkAudio

/// Where a network audio node's shared key lives.
///
/// The case is tagged in the saved workflow so a store can be added without rewriting the
/// documents users already have. `inline` keeps the key in the workflow file itself, which is
/// convenient but leaves it readable by anything that can read the file; `keychain` keeps only a
/// reference, so the file can be copied or shared without carrying the key with it.
enum RoutingNetworkAudioSecret: Codable, Equatable, Hashable, Sendable {
  case inline(base64: String)
  case keychain(reference: String)

  /// Generates a key and puts it where `store` asks for.
  static func generated(in store: RoutingNetworkAudioSecretStore) throws
    -> RoutingNetworkAudioSecret
  {
    try store.save(NetworkAudioSharedKey.random())
  }

  /// The key text the document itself carries, which a Keychain-backed secret does not.
  var inlineBase64: String? {
    switch self {
    case .inline(let base64): base64
    case .keychain: nil
    }
  }

  /// Reads the key, or throws when it is not where the document says it is.
  func resolve() throws -> NetworkAudioSharedKey {
    switch self {
    case .inline(let base64): try NetworkAudioSharedKey(base64Encoded: base64)
    case .keychain(let reference): try RoutingNetworkAudioKeychain.read(reference: reference)
    }
  }

  /// The text the user copies to the other machine, read from wherever the key lives.
  func revealBase64() throws -> String {
    try resolve().base64EncodedString
  }

  /// Whether the key can be read right now.
  var isValid: Bool {
    (try? resolve()) != nil
  }

  /// Releases whatever this secret owns outside the document.
  func discard() throws {
    switch self {
    case .inline: return
    case .keychain(let reference): try RoutingNetworkAudioKeychain.remove(reference: reference)
    }
  }
}

extension RoutingNetworkAudioSecret: CustomStringConvertible, CustomDebugStringConvertible {
  /// Redacted, so a configuration that reaches a log does not carry the key with it.
  var description: String { "RoutingNetworkAudioSecret(redacted)" }

  var debugDescription: String { description }
}

/// Where newly entered keys are put.
enum RoutingNetworkAudioSecretStore: String, CaseIterable, Codable, Sendable {
  /// The Keychain, so the workflow file carries only a reference.
  case keychain

  /// The workflow file, which is readable by anything that can read the file.
  case inline

  var displayName: String {
    switch self {
    case .keychain: "Keychain"
    case .inline: "Workflow File"
    }
  }

  /// Saves a key the user pasted, so a view need not know the library's key type.
  func save(base64Encoded text: String) throws -> RoutingNetworkAudioSecret {
    try save(NetworkAudioSharedKey(base64Encoded: text))
  }

  func save(_ key: NetworkAudioSharedKey) throws -> RoutingNetworkAudioSecret {
    switch self {
    case .inline:
      return .inline(base64: key.base64EncodedString)
    case .keychain:
      let reference = RoutingNetworkAudioKeychain.makeReference()
      try RoutingNetworkAudioKeychain.store(key, reference: reference)
      return .keychain(reference: reference)
    }
  }
}
