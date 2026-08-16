import Foundation
import Testing

@testable import Rilliya

@MainActor
struct RilliyaLaunchAtLoginControllerTests {
  @Test
  func successfulTogglePublishesTheServiceStatusInsteadOfAnOptimisticValue() {
    let service = LaunchAtLoginServiceDouble(status: .notRegistered)
    let controller = RilliyaLaunchAtLoginController(service: service)

    controller.setEnabled(true)

    #expect(service.registerCallCount == 1)
    #expect(controller.status == .enabled)
    #expect(controller.isEnabled)
    #expect(controller.issue == nil)

    controller.setEnabled(false)

    #expect(service.unregisterCallCount == 1)
    #expect(controller.status == .notRegistered)
    #expect(!controller.isEnabled)
  }

  @Test
  func registrationFailureRetainsTheRealDisabledStateAndSurfacesTheError() {
    let service = LaunchAtLoginServiceDouble(status: .notRegistered)
    service.registerError = LaunchAtLoginTestError.denied
    let controller = RilliyaLaunchAtLoginController(service: service)

    controller.setEnabled(true)

    #expect(!controller.isEnabled)
    #expect(controller.status == .notRegistered)
    #expect(controller.issue == "Login item registration was denied.")
  }

  @Test
  func approvalStateOpensSystemSettingsWithoutRegisteringAgain() {
    let service = LaunchAtLoginServiceDouble(status: .requiresApproval)
    let controller = RilliyaLaunchAtLoginController(service: service)

    controller.setEnabled(true)

    #expect(service.openSettingsCallCount == 1)
    #expect(service.registerCallCount == 0)
    #expect(controller.status == .requiresApproval)
  }
}

private enum LaunchAtLoginTestError: LocalizedError {
  case denied

  var errorDescription: String? { "Login item registration was denied." }
}

private final class LaunchAtLoginServiceDouble: RilliyaLaunchAtLoginServicing,
  @unchecked Sendable
{
  var status: RilliyaLaunchAtLoginStatus
  var registerError: (any Error)?
  private(set) var registerCallCount = 0
  private(set) var unregisterCallCount = 0
  private(set) var openSettingsCallCount = 0

  init(status: RilliyaLaunchAtLoginStatus) {
    self.status = status
  }

  func register() throws {
    registerCallCount += 1
    if let registerError { throw registerError }
    status = .enabled
  }

  func unregister() throws {
    unregisterCallCount += 1
    status = .notRegistered
  }

  func openSystemSettings() {
    openSettingsCallCount += 1
  }
}
