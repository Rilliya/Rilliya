import Foundation
import RilliyaNetworkAudio

/// Somewhere a network audio node's shared key can come from.
///
/// The two built in keep a key the person made: one in the workflow file, one in the Keychain.
/// Neither is special. Anything that can produce the same 32 bytes on both machines belongs here
/// — a key released after a sign-in, one held by a key management service, one derived per
/// account — and a source added by someone else works exactly as the built-in two do.
///
/// A saved workflow records ``id`` and whatever ``store(_:)`` returned, so a document opened later
/// finds its key through the same source that put it there. Anything a source needs to find a key
/// again goes in those parameters; the key itself does not, unless the source is the workflow file.
protocol RoutingNetworkAudioKeySource: Sendable {
  /// Names this source in a saved workflow, so it must stay the same across releases.
  ///
  /// Reverse-DNS for anything not built in, so two sources from different people cannot collide.
  var id: String { get }

  /// What the person choosing between sources reads.
  var displayName: String { get }

  /// What choosing this means, in a sentence.
  var explanation: String { get }

  /// Whether a key made or pasted here can be handed to this source to keep.
  ///
  /// A source that fetches its key from somewhere else has nothing to be handed, and offers no
  /// way to create one. Generating and pasting are hidden for those.
  var acceptsProvidedKeys: Bool { get }

  /// Keeps a key, returning what a document needs in order to find it again.
  ///
  /// - Throws: ``RoutingNetworkAudioKeySourceError/cannotStoreKeys`` when this source fetches its
  ///   key rather than keeping one.
  func store(_ key: NetworkAudioSharedKey) throws -> [String: String]

  /// Builds what a run asks for its key, which may sign in or call a service when asked.
  func provider(for parameters: [String: String]) throws -> any NetworkAudioKeyProvider

  /// The text a person copies to the other machine, or `nil` when there is nothing to copy.
  ///
  /// A source both machines reach on their own — an account, a service — has nothing to carry
  /// across, which is the point of it.
  func revealBase64(for parameters: [String: String]) throws -> String?

  /// Releases anything this source kept outside the document.
  func discard(for parameters: [String: String]) throws
}

/// What a source could not do.
enum RoutingNetworkAudioKeySourceError: Error, Equatable, LocalizedError {
  /// This source fetches its key rather than keeping one it was given.
  case cannotStoreKeys(sourceID: String)

  /// The document names a source nothing has registered.
  case unknownSource(id: String)

  /// The document's parameters are not what the source expects.
  case malformedParameters(sourceID: String)

  var errorDescription: String? {
    switch self {
    case .cannotStoreKeys(let sourceID):
      "\(sourceID) fetches its key rather than keeping one, so it cannot be given a key to hold."
    case .unknownSource(let id):
      "This workflow keeps its key in \"\(id)\", which nothing here provides."
    case .malformedParameters(let sourceID):
      "This workflow's \(sourceID) key details are not in the form it expects."
    }
  }
}

/// The key sources this application knows about.
///
/// The two built in are registered at launch. Anything else registers itself before a workflow
/// that names it is opened; a document naming a source nothing registered reports that plainly
/// rather than losing the reference to it.
@MainActor
final class RoutingNetworkAudioKeySourceRegistry {
  static let shared = RoutingNetworkAudioKeySourceRegistry()

  private var sources: [String: any RoutingNetworkAudioKeySource] = [:]
  private var order: [String] = []

  init(
    sources: [any RoutingNetworkAudioKeySource] = [
      RoutingKeychainKeySource(),
      RoutingInlineKeySource(),
    ]
  ) {
    for source in sources { register(source) }
  }

  /// Adds a source, replacing one already registered under the same identifier.
  func register(_ source: any RoutingNetworkAudioKeySource) {
    if sources[source.id] == nil { order.append(source.id) }
    sources[source.id] = source
  }

  /// Every registered source, in the order they were registered.
  var all: [any RoutingNetworkAudioKeySource] {
    order.compactMap { sources[$0] }
  }

  func source(for id: String) -> (any RoutingNetworkAudioKeySource)? {
    sources[id]
  }

  /// The source a document names, or a typed failure saying which one is missing.
  func require(_ id: String) throws -> any RoutingNetworkAudioKeySource {
    guard let source = sources[id] else {
      throw RoutingNetworkAudioKeySourceError.unknownSource(id: id)
    }
    return source
  }
}

/// Keeps the key in the workflow file itself.
///
/// Convenient, and readable by anything that can read the file — which is why it is not the
/// default and why the file should not be shared while it carries one.
struct RoutingInlineKeySource: RoutingNetworkAudioKeySource {
  static let identifier = "inline"

  var id: String { Self.identifier }
  var displayName: String { "Workflow File" }
  var explanation: String {
    "Keeps the key in the workflow file, where anything that can read the file can read it."
  }
  var acceptsProvidedKeys: Bool { true }

  func store(_ key: NetworkAudioSharedKey) throws -> [String: String] {
    ["base64": key.base64EncodedString]
  }

  func provider(for parameters: [String: String]) throws -> any NetworkAudioKeyProvider {
    NetworkAudioStaticKeyProvider(try key(from: parameters))
  }

  func revealBase64(for parameters: [String: String]) throws -> String? {
    try key(from: parameters).base64EncodedString
  }

  func discard(for parameters: [String: String]) throws {}

  private func key(from parameters: [String: String]) throws -> NetworkAudioSharedKey {
    guard let base64 = parameters["base64"] else {
      throw RoutingNetworkAudioKeySourceError.malformedParameters(sourceID: id)
    }
    return try NetworkAudioSharedKey(base64Encoded: base64)
  }
}

/// Keeps the key in the Keychain, so the workflow file carries only a reference.
struct RoutingKeychainKeySource: RoutingNetworkAudioKeySource {
  static let identifier = "keychain"

  var id: String { Self.identifier }
  var displayName: String { "Keychain" }
  var explanation: String {
    "Keeps the key in the Keychain, so the workflow file carries only a reference to it."
  }
  var acceptsProvidedKeys: Bool { true }

  func store(_ key: NetworkAudioSharedKey) throws -> [String: String] {
    let reference = RoutingNetworkAudioKeychain.makeReference()
    try RoutingNetworkAudioKeychain.store(key, reference: reference)
    return ["reference": reference]
  }

  func provider(for parameters: [String: String]) throws -> any NetworkAudioKeyProvider {
    NetworkAudioStaticKeyProvider(try key(from: parameters))
  }

  func revealBase64(for parameters: [String: String]) throws -> String? {
    try key(from: parameters).base64EncodedString
  }

  func discard(for parameters: [String: String]) throws {
    guard let reference = parameters["reference"] else { return }
    try RoutingNetworkAudioKeychain.remove(reference: reference)
  }

  private func key(from parameters: [String: String]) throws -> NetworkAudioSharedKey {
    guard let reference = parameters["reference"] else {
      throw RoutingNetworkAudioKeySourceError.malformedParameters(sourceID: id)
    }
    return try RoutingNetworkAudioKeychain.read(reference: reference)
  }
}
