import Foundation
import RilliyaNetworkAudio

/// Which source holds a network audio node's shared key, and what that source needs to find it.
///
/// Open on purpose. The source is named rather than enumerated, so one nobody here wrote works
/// exactly as the two built in do: a key released after a sign-in, one held by a key management
/// service, one derived per account. See ``RoutingNetworkAudioKeySource``.
///
/// The parameters mean nothing to anything but the source that wrote them. A key itself only
/// appears in them when the source is the workflow file, which is the one that keeps it there.
struct RoutingNetworkAudioSecret: Codable, Equatable, Hashable, Sendable {
  /// Which source this key came from, matching ``RoutingNetworkAudioKeySource/id``.
  let sourceID: String

  /// What that source needs in order to find the key again.
  let parameters: [String: String]

  init(sourceID: String, parameters: [String: String]) {
    self.sourceID = sourceID
    self.parameters = parameters
  }

  /// Generates a key and asks `source` to keep it.
  static func generated(
    in source: any RoutingNetworkAudioKeySource
  ) throws -> RoutingNetworkAudioSecret {
    try stored(NetworkAudioSharedKey.random(), in: source)
  }

  /// Asks `source` to keep a key the person already has.
  static func stored(
    _ key: NetworkAudioSharedKey,
    in source: any RoutingNetworkAudioKeySource
  ) throws -> RoutingNetworkAudioSecret {
    guard source.acceptsProvidedKeys else {
      throw RoutingNetworkAudioKeySourceError.cannotStoreKeys(sourceID: source.id)
    }
    return RoutingNetworkAudioSecret(
      sourceID: source.id,
      parameters: try source.store(key)
    )
  }

  /// The key text the document itself carries, which only the workflow-file source has.
  var inlineBase64: String? {
    sourceID == RoutingInlineKeySource.identifier ? parameters["base64"] : nil
  }

  /// What a run asks for its key, built by whichever source this names.
  @MainActor
  func provider() throws -> any NetworkAudioKeyProvider {
    try RoutingNetworkAudioKeySourceRegistry.shared
      .require(sourceID)
      .provider(for: parameters)
  }

  /// The text the person copies to the other machine, or `nil` when there is nothing to copy.
  @MainActor
  func revealBase64() throws -> String? {
    try RoutingNetworkAudioKeySourceRegistry.shared
      .require(sourceID)
      .revealBase64(for: parameters)
  }

  /// Whether the key can be reached right now.
  @MainActor
  var isValid: Bool {
    (try? provider()) != nil
  }

  /// Releases whatever this secret owns outside the document.
  @MainActor
  func discard() throws {
    try RoutingNetworkAudioKeySourceRegistry.shared
      .require(sourceID)
      .discard(for: parameters)
  }
}

extension RoutingNetworkAudioSecret: CustomStringConvertible, CustomDebugStringConvertible {
  /// Redacted, so a configuration that reaches a log does not carry the key with it.
  var description: String { "RoutingNetworkAudioSecret(redacted)" }

  var debugDescription: String { description }
}
