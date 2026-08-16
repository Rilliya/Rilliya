import Foundation
import RilliyaCapture
import Testing

private let runsAudioHardwareSmokeTests =
  ProcessInfo.processInfo.environment["RILLIYA_RUN_AUDIO_HARDWARE_TESTS"] == "1"

struct SystemOutputCaptureHardwareSmokeTests {
  @Test(
    "Starts and stops capture on the current system output",
    .enabled(if: runsAudioHardwareSmokeTests)
  )
  func startsAndStopsCurrentSystemOutputCapture() async throws {
    let capture = try DeviceOutputCapture(
      target: .systemDefault,
      configuration: DeviceOutputCaptureConfiguration(publishesMeterSnapshots: false),
      snapshotHandler: { _ in }
    )

    #expect(capture.format.sampleRate > 0)
    #expect(!capture.format.channelIDs.isEmpty)
    #expect(capture.frameBuffer.format.channelCount == capture.format.channelIDs.count)

    try capture.start()
    #expect(capture.isRunning)
    try await Task.sleep(for: .milliseconds(100))
    try capture.stop()
    #expect(!capture.isRunning)
  }
}
