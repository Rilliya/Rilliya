import Foundation
import RilliyaNetworkAudio

/// Where a network audio node's shared key lives.
///
/// The case is tagged in the saved workflow so a later store can be added without rewriting the
/// documents users already have. `inline` keeps the key in the workflow file itself, which is
/// convenient but leaves it readable by anything that can read the file.
enum RoutingNetworkAudioSecret: Codable, Equatable, Hashable, Sendable {
  case inline(base64: String)

  /// Generates a key to show the user for pairing.
  static func generated() -> RoutingNetworkAudioSecret {
    .inline(base64: NetworkAudioSharedKey.random().base64EncodedString)
  }

  /// The text the user copies to the other machine.
  var base64EncodedString: String {
    switch self {
    case .inline(let base64): base64
    }
  }

  /// Reads the key, or throws when the stored text is not one.
  func resolve() throws -> NetworkAudioSharedKey {
    switch self {
    case .inline(let base64): try NetworkAudioSharedKey(base64Encoded: base64)
    }
  }

  /// Whether the stored text is a usable key.
  var isValid: Bool {
    (try? resolve()) != nil
  }
}

extension RoutingNetworkAudioSecret: CustomStringConvertible, CustomDebugStringConvertible {
  /// Redacted, so a configuration that reaches a log does not carry the key with it.
  var description: String { "RoutingNetworkAudioSecret(redacted)" }

  var debugDescription: String { description }
}
