import AppKit
import Foundation
import Observation
import RilliyaVirtualAudio

@MainActor
protocol RilliyaVirtualAudioDriverInstalling {
  var isInstallerBundled: Bool { get }

  func openInstaller() throws
}

@MainActor
protocol RilliyaVirtualAudioDriverUninstalling {
  func uninstall() async throws
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
  private static let resourceName = "RilliyaVADriver"
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

enum RilliyaVirtualAudioDriverUninstallerError: Error, LocalizedError {
  case canceled
  case couldNotStart
  case failed

  var errorDescription: String? {
    switch self {
    case .canceled:
      "Virtual audio driver removal was canceled."
    case .couldNotStart:
      "macOS could not start the virtual audio driver uninstaller."
    case .failed:
      "macOS could not remove the virtual audio driver."
    }
  }
}

@MainActor
struct SystemRilliyaVirtualAudioDriverUninstaller: RilliyaVirtualAudioDriverUninstalling {
  func uninstall() async throws {
    let script = Self.script
    let result = try await Task.detached(priority: .userInitiated) {
      let process = Process()
      let errorPipe = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
      process.arguments = ["-e", script]
      process.standardError = errorPipe

      do {
        try process.run()
      } catch {
        throw RilliyaVirtualAudioDriverUninstallerError.couldNotStart
      }

      process.waitUntilExit()
      let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
      let errorText = String(decoding: errorData, as: UTF8.self)
      return (process.terminationStatus, errorText)
    }.value

    guard result.0 == 0 else {
      if result.1.contains("(-128)") {
        throw RilliyaVirtualAudioDriverUninstallerError.canceled
      }
      throw RilliyaVirtualAudioDriverUninstallerError.failed
    }
  }

  private static let script = """
    do shell script "/bin/rm -rf '/Library/Audio/Plug-Ins/HAL/RilliyaVADriver.driver' && (/usr/bin/killall coreaudiod 2>/dev/null || /usr/bin/true)" with administrator privileges
    """
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
  @ObservationIgnored private let uninstaller: any RilliyaVirtualAudioDriverUninstalling

  init(
    store: any RilliyaVirtualAudioEndpointStoring = SystemRilliyaVirtualAudioEndpointStore(),
    installer: any RilliyaVirtualAudioDriverInstalling =
      SystemRilliyaVirtualAudioDriverInstaller(),
    uninstaller: any RilliyaVirtualAudioDriverUninstalling =
      SystemRilliyaVirtualAudioDriverUninstaller()
  ) {
    self.store = store
    self.installer = installer
    self.uninstaller = uninstaller
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

  func uninstallDriver() async {
    guard beginOperation() else { return }
    defer { isWorking = false }
    do {
      try await uninstaller.uninstall()
      availability = .notInstalled
      catalog = .empty
      issue = nil
    } catch RilliyaVirtualAudioDriverUninstallerError.canceled {
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
