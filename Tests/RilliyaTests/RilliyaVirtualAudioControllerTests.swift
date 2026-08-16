import Foundation
import RilliyaVirtualAudio
import Testing

@testable import Rilliya

@MainActor
struct RilliyaVirtualAudioControllerTests {
  @Test
  func refreshDistinguishesMissingDriverFromAnEmptyCatalog() async throws {
    let missingStore = FakeRilliyaVirtualAudioEndpointStore(availability: .notInstalled)
    let missingController = RilliyaVirtualAudioController(store: missingStore)

    await missingController.refresh()

    #expect(missingController.availability == .notInstalled)
    #expect(missingController.catalog == .empty)
    #expect(missingController.issue == nil)
    #expect(await missingStore.catalogReadCount == 0)

    let availableStore = FakeRilliyaVirtualAudioEndpointStore(availability: .available)
    let availableController = RilliyaVirtualAudioController(store: availableStore)

    await availableController.refresh()

    #expect(availableController.availability == .available)
    #expect(availableController.catalog == .empty)
    #expect(await availableStore.catalogReadCount == 1)
  }

  @Test
  func mutationsRepublishTheLatestCatalog() async throws {
    let store = FakeRilliyaVirtualAudioEndpointStore(availability: .available)
    let controller = RilliyaVirtualAudioController(store: store)
    await controller.refresh()
    let configuration = try VirtualAudioEndpointConfiguration(
      name: "Remote Microphone",
      direction: .input,
      format: VirtualAudioEndpointFormat(sampleRate: 48_000, channelCount: 1)
    )

    await controller.create(configuration)
    let endpoint = try #require(controller.catalog.endpoints.first)
    #expect(endpoint.configuration == configuration)

    let updatedConfiguration = try VirtualAudioEndpointConfiguration(
      name: "Remote Voice",
      direction: .input,
      format: VirtualAudioEndpointFormat(sampleRate: 96_000, channelCount: 2)
    )
    await controller.update(id: endpoint.id, configuration: updatedConfiguration)
    #expect(controller.catalog.endpoint(id: endpoint.id)?.configuration == updatedConfiguration)

    await controller.remove(id: endpoint.id)
    #expect(controller.catalog.endpoints.isEmpty)
    #expect(controller.issue == nil)
  }

  @Test
  func mutationFailuresRemainVisibleAndLeaveTheLastCatalogIntact() async throws {
    let store = FakeRilliyaVirtualAudioEndpointStore(availability: .available)
    let controller = RilliyaVirtualAudioController(store: store)
    await controller.refresh()
    await store.setFailure(.catalogPropertyUnavailable)

    await controller.create(
      try VirtualAudioEndpointConfiguration(name: "Unavailable", direction: .output)
    )

    #expect(controller.catalog.endpoints.isEmpty)
    #expect(controller.issue?.contains("does not expose endpoint management") == true)
    #expect(!controller.isWorking)
  }

  @Test
  func installerFailuresAreVisibleWithoutChangingDriverAvailability() async {
    let store = FakeRilliyaVirtualAudioEndpointStore(availability: .notInstalled)
    let installer = FakeRilliyaVirtualAudioDriverInstaller(
      isInstallerBundled: true,
      failure: .installerCouldNotBeOpened
    )
    let controller = RilliyaVirtualAudioController(store: store, installer: installer)
    await controller.refresh()

    controller.openInstaller()

    #expect(controller.availability == .notInstalled)
    #expect(controller.issue?.contains("could not open") == true)
    #expect(installer.openCount == 1)
  }
}

@MainActor
private final class FakeRilliyaVirtualAudioDriverInstaller:
  RilliyaVirtualAudioDriverInstalling
{
  let isInstallerBundled: Bool
  let failure: RilliyaVirtualAudioDriverInstallerError?
  private(set) var openCount = 0

  init(
    isInstallerBundled: Bool,
    failure: RilliyaVirtualAudioDriverInstallerError? = nil
  ) {
    self.isInstallerBundled = isInstallerBundled
    self.failure = failure
  }

  func openInstaller() throws {
    openCount += 1
    if let failure {
      throw failure
    }
  }
}

private actor FakeRilliyaVirtualAudioEndpointStore: RilliyaVirtualAudioEndpointStoring {
  let availabilityValue: VirtualAudioDriverAvailability
  var catalogValue = VirtualAudioEndpointCatalog.empty
  var failure: VirtualAudioEndpointStoreError?
  var catalogReadCount = 0

  init(availability: VirtualAudioDriverAvailability) {
    availabilityValue = availability
  }

  func availability() -> VirtualAudioDriverAvailability {
    availabilityValue
  }

  func catalog() throws -> VirtualAudioEndpointCatalog {
    try throwFailureIfNeeded()
    catalogReadCount += 1
    return catalogValue
  }

  func create(
    _ configuration: VirtualAudioEndpointConfiguration,
    id: VirtualAudioEndpointID
  ) throws -> VirtualAudioEndpoint {
    try throwFailureIfNeeded()
    return try catalogValue.create(configuration, id: id)
  }

  func update(
    id: VirtualAudioEndpointID,
    configuration: VirtualAudioEndpointConfiguration
  ) throws -> VirtualAudioEndpoint {
    try throwFailureIfNeeded()
    return try catalogValue.update(id: id, configuration: configuration)
  }

  func remove(id: VirtualAudioEndpointID) throws -> VirtualAudioEndpoint {
    try throwFailureIfNeeded()
    return try catalogValue.remove(id: id)
  }

  func setFailure(_ failure: VirtualAudioEndpointStoreError?) {
    self.failure = failure
  }

  private func throwFailureIfNeeded() throws {
    if let failure {
      throw failure
    }
  }
}
