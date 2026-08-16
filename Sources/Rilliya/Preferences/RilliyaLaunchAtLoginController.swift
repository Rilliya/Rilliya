import Foundation
import Observation
import ServiceManagement

enum RilliyaLaunchAtLoginStatus: Equatable, Sendable {
  case notRegistered
  case enabled
  case requiresApproval
  case unavailable
}

protocol RilliyaLaunchAtLoginServicing: Sendable {
  var status: RilliyaLaunchAtLoginStatus { get }

  func register() throws
  func unregister() throws
  func openSystemSettings()
}

struct SystemRilliyaLaunchAtLoginService: RilliyaLaunchAtLoginServicing {
  var status: RilliyaLaunchAtLoginStatus {
    switch SMAppService.mainApp.status {
    case .notRegistered: .notRegistered
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    case .notFound: .unavailable
    @unknown default: .unavailable
    }
  }

  func register() throws {
    try SMAppService.mainApp.register()
  }

  func unregister() throws {
    try SMAppService.mainApp.unregister()
  }

  func openSystemSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}

@MainActor
@Observable
final class RilliyaLaunchAtLoginController {
  private(set) var status: RilliyaLaunchAtLoginStatus
  private(set) var issue: String?

  @ObservationIgnored private let service: any RilliyaLaunchAtLoginServicing

  init(service: any RilliyaLaunchAtLoginServicing = SystemRilliyaLaunchAtLoginService()) {
    self.service = service
    status = service.status
  }

  var isEnabled: Bool { status == .enabled }

  func setEnabled(_ enabled: Bool) {
    issue = nil
    do {
      if enabled {
        switch service.status {
        case .enabled:
          break
        case .requiresApproval:
          service.openSystemSettings()
        case .notRegistered, .unavailable:
          try service.register()
        }
      } else {
        switch service.status {
        case .enabled, .requiresApproval:
          try service.unregister()
        case .notRegistered, .unavailable:
          break
        }
      }
    } catch {
      issue = error.localizedDescription
    }
    refresh()
  }

  func refresh() {
    status = service.status
  }

  func openSystemSettings() {
    service.openSystemSettings()
  }
}
