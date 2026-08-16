import AppKit
import Foundation
import Observation
import RilliyaVirtualAudio

@MainActor
protocol RilliyaVirtualAudioDriverInstalling {
  var isInstallerBundled: Bool { get }

  func openInstaller() throws
}

enum RilliyaVirtualAudioDriverInstallerError: Error, LocalizedError {
  case installerNotBundled
  case installerCouldNotBeOpened

  var errorDescription: String? {
    switch self {
    case .installerNotBundled:
      "This build does not include the signed Rilliya virtual audio driver installer."
    case .installerCouldNotBeOpened:
      "macOS could not open the Rilliya virtual audio driver installer."
    }
  }
}

@MainActor
struct SystemRilliyaVirtualAudioDriverInstaller: RilliyaVirtualAudioDriverInstalling {
  private static let resourceName = "RilliyaVirtualAudioDriver"
  private static let resourceExtension = "pkg"
  private static let resourceSubdirectory = "Installers"

  var isInstallerBundled: Bool {
    installerURL != nil
  }

  func openInstaller() throws {
    guard let installerURL else {
      throw RilliyaVirtualAudioDriverInstallerError.installerNotBundled
    }
    guard NSWorkspace.shared.open(installerURL) else {
      throw RilliyaVirtualAudioDriverInstallerError.installerCouldNotBeOpened
    }
  }

  private var installerURL: URL? {
    Bundle.main.url(
      forResource: Self.resourceName,
      withExtension: Self.resourceExtension,
      subdirectory: Self.resourceSubdirectory
    )
  }
}

protocol RilliyaVirtualAudioEndpointStoring: Sendable {
  func availability() async throws -> VirtualAudioDriverAvailability
  func catalog() async throws -> VirtualAudioEndpointCatalog
  func create(
    _ configuration: VirtualAudioEndpointConfiguration,
    id: VirtualAudioEndpointID
  ) async throws -> VirtualAudioEndpoint
  func update(
    id: VirtualAudioEndpointID,
    configuration: VirtualAudioEndpointConfiguration
  ) async throws -> VirtualAudioEndpoint
  func remove(id: VirtualAudioEndpointID) async throws -> VirtualAudioEndpoint
}

private struct SystemRilliyaVirtualAudioEndpointStore: RilliyaVirtualAudioEndpointStoring {
  let store = VirtualAudioEndpointStore()

  func availability() async throws -> VirtualAudioDriverAvailability {
    try await store.availability()
  }

  func catalog() async throws -> VirtualAudioEndpointCatalog {
    try await store.catalog()
  }

  func create(
    _ configuration: VirtualAudioEndpointConfiguration,
    id: VirtualAudioEndpointID
  ) async throws -> VirtualAudioEndpoint {
    try await store.create(configuration, id: id)
  }

  func update(
    id: VirtualAudioEndpointID,
    configuration: VirtualAudioEndpointConfiguration
  ) async throws -> VirtualAudioEndpoint {
    try await store.update(id: id, configuration: configuration)
  }

  func remove(id: VirtualAudioEndpointID) async throws -> VirtualAudioEndpoint {
    try await store.remove(id: id)
  }
}

@MainActor
@Observable
final class RilliyaVirtualAudioController {
  static let shared = RilliyaVirtualAudioController()

  private(set) var availability: VirtualAudioDriverAvailability?
  private(set) var catalog = VirtualAudioEndpointCatalog.empty
  private(set) var isWorking = false
  private(set) var issue: String?

  @ObservationIgnored private let store: any RilliyaVirtualAudioEndpointStoring
  @ObservationIgnored private let installer: any RilliyaVirtualAudioDriverInstalling

  init(
    store: any RilliyaVirtualAudioEndpointStoring = SystemRilliyaVirtualAudioEndpointStore(),
    installer: any RilliyaVirtualAudioDriverInstalling =
      SystemRilliyaVirtualAudioDriverInstaller()
  ) {
    self.store = store
    self.installer = installer
  }

  var isInstallerBundled: Bool {
    installer.isInstallerBundled
  }

  func refresh() async {
    guard beginOperation() else { return }
    defer { isWorking = false }
    do {
      let latestAvailability = try await store.availability()
      availability = latestAvailability
      catalog = latestAvailability == .available ? try await store.catalog() : .empty
      issue = nil
    } catch {
      issue = Self.message(for: error)
    }
  }

  func create(_ configuration: VirtualAudioEndpointConfiguration) async {
    guard beginOperation() else { return }
    defer { isWorking = false }
    do {
      _ = try await store.create(configuration, id: VirtualAudioEndpointID())
      catalog = try await store.catalog()
      availability = .available
      issue = nil
    } catch {
      issue = Self.message(for: error)
    }
  }

  func update(
    id: VirtualAudioEndpointID,
    configuration: VirtualAudioEndpointConfiguration
  ) async {
    guard beginOperation() else { return }
    defer { isWorking = false }
    do {
      _ = try await store.update(id: id, configuration: configuration)
      catalog = try await store.catalog()
      availability = .available
      issue = nil
    } catch {
      issue = Self.message(for: error)
    }
  }

  func remove(id: VirtualAudioEndpointID) async {
    guard beginOperation() else { return }
    defer { isWorking = false }
    do {
      _ = try await store.remove(id: id)
      catalog = try await store.catalog()
      availability = .available
      issue = nil
    } catch {
      issue = Self.message(for: error)
    }
  }

  func openInstaller() {
    do {
      try installer.openInstaller()
      issue = nil
    } catch {
      issue = Self.message(for: error)
    }
  }

  private func beginOperation() -> Bool {
    guard !isWorking else { return false }
    isWorking = true
    return true
  }

  private static func message(for error: any Error) -> String {
    if let localized = error as? any LocalizedError,
      let description = localized.errorDescription
    {
      return description
    }
    return String(describing: error)
  }
}
