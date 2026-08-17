import Foundation
import RilliyaNetworkAudio
import Security

enum RoutingNetworkAudioKeychainError: Error, Equatable {
  case notFound
  case accessDenied
  case unexpectedStatus(OSStatus)

  init(status: OSStatus) {
    switch status {
    case errSecItemNotFound: self = .notFound
    case errSecAuthFailed, errSecInteractionNotAllowed, errSecInteractionRequired:
      self = .accessDenied
    default: self = .unexpectedStatus(status)
    }
  }
}

extension RoutingNetworkAudioKeychainError: LocalizedError {
  var errorDescription: String? {
    switch self {
    case .notFound:
      "The key is no longer in the Keychain."
    case .accessDenied:
      "The Keychain refused this build access to the key."
    case .unexpectedStatus(let status):
      SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)."
    }
  }
}

/// Stores network audio shared keys as generic passwords in the login Keychain.
///
/// The data protection Keychain needs a `keychain-access-groups` entitlement, which a
/// Developer ID application without a provisioning profile cannot carry, so these are ordinary
/// Keychain items scoped by the application's code signature. That scoping is why an unsigned
/// development build — whose signature changes on every rebuild — is prompted for access, and
/// why the inline store stays available for development.
///
/// The service and label are spelled out so the user can find and delete these in Keychain
/// Access without the application's help.
enum RoutingNetworkAudioKeychain {
  static let service = "moe.uwucocoa.rilliya.network-audio-key"
  static let label = "Rilliya network audio key"

  /// A fresh identifier for one node's key.
  static func makeReference() -> String {
    UUID().uuidString
  }

  static func store(_ key: NetworkAudioSharedKey, reference: String) throws {
    let secret = Data(key.base64EncodedString.utf8)
    let status = SecItemAdd(
      addQuery(reference: reference, secret: secret) as CFDictionary,
      nil
    )
    switch status {
    case errSecSuccess:
      return
    case errSecDuplicateItem:
      let update = SecItemUpdate(
        query(reference: reference) as CFDictionary,
        [kSecValueData as String: secret] as CFDictionary
      )
      guard update == errSecSuccess else {
        throw RoutingNetworkAudioKeychainError(status: update)
      }
    default:
      throw RoutingNetworkAudioKeychainError(status: status)
    }
  }

  static func read(reference: String) throws -> NetworkAudioSharedKey {
    var request = query(reference: reference)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne

    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    guard status == errSecSuccess else {
      throw RoutingNetworkAudioKeychainError(status: status)
    }
    guard let data = result as? Data,
      let text = String(data: data, encoding: .utf8)
    else {
      throw RoutingNetworkAudioKeychainError.notFound
    }
    return try NetworkAudioSharedKey(base64Encoded: text)
  }

  /// Removes the item, treating an already-absent one as success.
  static func remove(reference: String) throws {
    let status = SecItemDelete(query(reference: reference) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw RoutingNetworkAudioKeychainError(status: status)
    }
  }

  private static func query(reference: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: reference,
    ]
  }

  private static func addQuery(reference: String, secret: Data) -> [String: Any] {
    var item = query(reference: reference)
    item[kSecValueData as String] = secret
    item[kSecAttrLabel as String] = label
    item[kSecAttrDescription as String] = "Shared key for one network audio node"
    item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
    return item
  }
}
