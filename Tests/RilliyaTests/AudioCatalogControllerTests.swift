import Foundation
import RilliyaKit
import Testing

@testable import Rilliya

struct AudioCatalogControllerTests {
  @Test @MainActor
  func injectedLoaderPopulatesCatalogWithoutHardwareAccess() async throws {
    let snapshot = AudioCatalogSnapshot(
      processes: [try makeProcess()],
      devices: [],
      issues: []
    )
    let controller = AudioCatalogController(
      loader: StubAudioCatalogLoader(result: .success(snapshot)))

    await controller.loadOnce()

    #expect(controller.state.snapshot == snapshot)
    #expect(controller.state.rootErrorMessage == nil)
    #expect(!controller.state.isLoading)
  }

  @Test @MainActor
  func injectedFailureIsSurfacedWithoutDiscardingPreviousSnapshot() async throws {
    let snapshot = AudioCatalogSnapshot(processes: [try makeProcess()], devices: [], issues: [])
    let loader = SequenceAudioCatalogLoader(
      results: [.success(snapshot), .failure(.unavailable)]
    )
    let controller = AudioCatalogController(loader: loader)

    await controller.loadOnce()
    await controller.loadOnce()

    #expect(controller.state.snapshot == snapshot)
    #expect(controller.state.rootErrorMessage == "The test audio catalog is unavailable.")
    #expect(!controller.state.isLoading)
  }

  @Test @MainActor
  func cancellationDoesNotBecomeACatalogError() async {
    let controller = AudioCatalogController(loader: CancellingAudioCatalogLoader())

    await controller.loadOnce()

    #expect(controller.state.snapshot == nil)
    #expect(controller.state.rootErrorMessage == nil)
    #expect(!controller.state.isLoading)
  }

  @Test @MainActor
  func startConsumesCatalogUpdateStream() async throws {
    let snapshot = AudioCatalogSnapshot(
      processes: [try makeProcess()],
      devices: [],
      issues: []
    )
    let controller = AudioCatalogController(
      loader: StubAudioCatalogLoader(result: .success(snapshot)))

    controller.start()
    for _ in 0..<100 where controller.state.snapshot == nil {
      await Task.yield()
    }

    #expect(controller.state.snapshot == snapshot)
    #expect(controller.state.rootErrorMessage == nil)
    #expect(!controller.state.isLoading)
  }

  @Test
  func processPresentationUsesFallbacksWithoutInventingChannels() throws {
    let process = try makeProcess(bundleIdentifier: "com.example.Player")

    let named = ApplicationOutputPresentation(process: process, resolvedName: "Player")
    let fallback = ApplicationOutputPresentation(process: process, resolvedName: nil)

    #expect(named.title == "Player")
    #expect(named.subtitle == "com.example.Player")
    #expect(named.isActive)
    #expect(named.channelDetail == "Channel layout pending capture")
    #expect(fallback.title == "com.example.Player")
    #expect(fallback.subtitle == "PID 42")
  }

  @Test
  func endpointPresentationUsesTheSelectedNativeDirection() throws {
    let deviceID = try #require(AudioDeviceID(rawValue: "test-device"))
    let input = try makeEndpoint(
      deviceID: deviceID,
      direction: .input,
      count: 1,
      isDefault: true
    )
    let output = try makeEndpoint(
      deviceID: deviceID,
      direction: .output,
      count: 2,
      isDefault: false
    )
    let device = AudioDevice(
      id: deviceID,
      name: "Test Device",
      transportType: 0,
      nominalSampleRate: 48_000,
      isAlive: true,
      isRunning: true,
      input: input,
      output: output
    )

    let inputPresentation = DeviceEndpointPresentation(device: device, direction: .input)
    let outputPresentation = DeviceEndpointPresentation(device: device, direction: .output)

    #expect(inputPresentation?.channelCount == 1)
    #expect(inputPresentation?.detail == "1 channel · 48,000 Hz")
    #expect(inputPresentation?.isDefault == true)
    #expect(outputPresentation?.channelCount == 2)
    #expect(outputPresentation?.isDefault == false)
    #expect(outputPresentation?.detail == "2 channels · 48,000 Hz")
  }

  @Test
  func channelPresentationUsesHumanNumberingAndNativeMapping() throws {
    let deviceID = try #require(AudioDeviceID(rawValue: "mapped-device"))
    let streamIndex = try #require(AudioStreamIndex(rawValue: 1))
    let channelIndex = try #require(AudioChannelIndex(rawValue: 0))
    let streamChannelIndex = try #require(AudioChannelIndex(rawValue: 1))
    let channel = AudioChannel(
      id: AudioChannelID(
        ownerID: .source(.deviceInput(deviceID)),
        index: channelIndex
      ),
      streamID: AudioStreamID(
        deviceID: deviceID,
        direction: .input,
        index: streamIndex
      ),
      streamChannelIndex: streamChannelIndex
    )

    let presentation = DeviceChannelPresentation(channel: channel)

    #expect(presentation.title == "Channel 1")
    #expect(presentation.nativeMapping == "Native stream 2 · stream channel 2")
  }

  private func makeProcess(
    bundleIdentifier: String? = nil
  ) throws -> AudioProcess {
    AudioProcess(
      id: try #require(AudioProcessID(rawValue: 42)),
      bundleIdentifier: bundleIdentifier,
      isRunning: true,
      isRunningInput: false,
      isRunningOutput: true,
      inputDeviceIDs: [],
      outputDeviceIDs: []
    )
  }

  private func makeEndpoint(
    deviceID: AudioDeviceID,
    direction: AudioDirection,
    count: Int,
    isDefault: Bool
  ) throws -> AudioDeviceEndpoint {
    let channels = try (0..<count).map { index in
      AudioChannel(
        id: AudioChannelID(
          ownerID: direction == .input
            ? .source(.deviceInput(deviceID))
            : .destination(.deviceOutput(deviceID)),
          index: try #require(AudioChannelIndex(rawValue: index))
        )
      )
    }
    return AudioDeviceEndpoint(
      direction: direction,
      isDefault: isDefault,
      channels: channels,
      streams: []
    )
  }
}

private struct StubAudioCatalogLoader: AudioCatalogLoading {
  let result: Result<AudioCatalogSnapshot, StubCatalogError>

  func snapshot() async throws -> AudioCatalogSnapshot {
    try result.get()
  }
}

private actor SequenceAudioCatalogLoader: AudioCatalogLoading {
  private var results: [Result<AudioCatalogSnapshot, StubCatalogError>]

  init(results: [Result<AudioCatalogSnapshot, StubCatalogError>]) {
    self.results = results
  }

  func snapshot() async throws -> AudioCatalogSnapshot {
    guard !results.isEmpty else { throw StubCatalogError.unavailable }
    return try results.removeFirst().get()
  }
}

private struct CancellingAudioCatalogLoader: AudioCatalogLoading {
  func snapshot() async throws -> AudioCatalogSnapshot {
    throw CancellationError()
  }
}

private enum StubCatalogError: Error, LocalizedError {
  case unavailable

  var errorDescription: String? {
    "The test audio catalog is unavailable."
  }
}
