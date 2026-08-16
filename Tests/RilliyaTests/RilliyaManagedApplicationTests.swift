import Foundation
import RilliyaCore
import Testing

@testable import Rilliya

@Suite("Managed application controls")
struct RilliyaManagedApplicationTests {
  @Test @MainActor
  func controlsPersistAndExposeTheFullZeroToFourTimesRange() throws {
    let suiteName = "moe.uwucocoa.rilliya.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let application = makeApplication(name: "Music")
    let store = RilliyaManagedApplicationStore(defaults: defaults)
    let id = try #require(store.add(application))

    store.setVolume(4, id: id)
    store.setMuted(true, id: id)

    let encoded = try #require(
      defaults.data(forKey: "moe.uwucocoa.rilliya.managed-applications")
    )
    let decoded = try JSONDecoder().decode([RilliyaManagedApplication].self, from: encoded)
    #expect(decoded.count == 1)
    #expect(decoded[0].isValid())

    let restored = RilliyaManagedApplicationStore(defaults: defaults)
    let managed = try #require(restored.applications.first)
    #expect(managed.id == id)
    #expect(managed.volume == 4)
    #expect(managed.volumePercentage == 400)
    #expect(managed.isMuted)
    #expect(abs(managed.gainConfiguration.gainDecibels - 12.041_199_826_559_248) < 0.000_001)
    #expect(managed.gainConfiguration.isMuted)
  }

  @Test @MainActor
  func duplicateApplicationsAreRejectedByCanonicalURL() throws {
    let suiteName = "moe.uwucocoa.rilliya.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = RilliyaManagedApplicationStore(defaults: defaults)
    let application = makeApplication(name: "Music")

    #expect(store.add(application) != nil)
    #expect(store.add(application) == nil)
    #expect(store.applications.count == 1)
  }

  @Test @MainActor
  func mixerBuildsStableSourceGainAndOutputRoutes() throws {
    let application = makeApplication(name: "Music")
    var managed = RilliyaManagedApplication(application: application)
    managed.volume = 2
    let device = AudioDevice(
      id: try #require(AudioDeviceID(rawValue: "test-output")),
      name: "Test Output",
      transportType: 0,
      nominalSampleRate: 48_000,
      isAlive: true,
      isRunning: false,
      input: nil,
      output: AudioDeviceEndpoint(
        direction: .output,
        isDefault: true,
        channels: [],
        streams: []
      )
    )

    let workflow = try #require(
      RilliyaApplicationMixerBuilder.makeWorkflow(
        applications: [managed],
        defaultOutputDevice: device
      )
    )

    #expect(workflow.id == RilliyaApplicationMixerBuilder.workflowID)
    #expect(workflow.isRunning)
    #expect(workflow.workspace.nodes.count == 3)
    #expect(workflow.workspace.edges.count == 2)
    #expect(workflow.workspace.node(id: managed.sourceNodeID)?.value.applicationSelection != nil)
    #expect(
      workflow.workspace.node(id: managed.gainNodeID)?.value.gainConfiguration?.gainDecibels
        == managed.gainConfiguration.gainDecibels
    )
    #expect(
      workflow.workspace.node(id: RilliyaApplicationMixerBuilder.outputNodeID)?.value
        .outputDeviceSelection?.id == device.id
    )
  }

  @Test @MainActor
  func onlyRunningWorkflowsTakePrecedenceOverQuickControls() throws {
    let application = makeApplication(name: "Music")
    let managed = RilliyaManagedApplication(application: application)
    let workflow = try #require(
      RilliyaApplicationMixerBuilder.makeWorkflow(
        applications: [managed],
        defaultOutputDevice: makeOutputDevice()
      )
    )

    workflow.pause()
    #expect(
      RilliyaApplicationMixerBuilder.applicationsReroutedByWorkflows([workflow]).isEmpty
    )

    workflow.run()
    #expect(
      RilliyaApplicationMixerBuilder.applicationsReroutedByWorkflows([workflow])
        == [canonicalApplicationURL(application.bundleURL)]
    )
  }

  private func makeApplication(name: String) -> InstalledApplication {
    let url = URL(fileURLWithPath: "/Applications/\(name).app")
    return InstalledApplication(
      id: InstalledApplicationID(fileResourceIdentifier: nil, canonicalURL: url),
      bundleURL: url,
      bundleIdentifier: "example.\(name.lowercased())",
      displayName: name,
      kind: .regular,
      discoverySources: [.standardApplicationDirectory]
    )
  }

  private func makeOutputDevice() throws -> AudioDevice {
    AudioDevice(
      id: try #require(AudioDeviceID(rawValue: "test-output")),
      name: "Test Output",
      transportType: 0,
      nominalSampleRate: 48_000,
      isAlive: true,
      isRunning: false,
      input: nil,
      output: AudioDeviceEndpoint(
        direction: .output,
        isDefault: true,
        channels: [],
        streams: []
      )
    )
  }
}
