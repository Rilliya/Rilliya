import Foundation
import RilliyaCapture
import RilliyaCore
import RilliyaFilePlayback
import RilliyaNetworkAudio
import RilliyaPlayback
import Testing

@testable import Rilliya

struct RoutingNodeFailureTests {
  @Test
  func aRecognizedErrorCarriesBothAPhraseAndTheFullMessage() {
    let failure = RoutingNodeFailure(
      RoutingPreparedAudioGraphError.incompatibleSampleRate(UUID())
    )

    #expect(failure.summary == "Sample rate mismatch")
    #expect(failure.message.contains("sample-rate conversion"))
  }

  /// A node showing the first few words of an arbitrary message reads as noise, so an
  /// unrecognized cause shows the badge alone and leaves the text to the inspector.
  @Test
  func anUnrecognizedErrorHasNoPhrase() {
    let failure = RoutingNodeFailure(UnrecognizedTestError.somethingElse)

    #expect(failure.summary == nil)
    #expect(failure.message == UnrecognizedTestError.somethingElse.localizedDescription)
  }

  @Test
  func anAuthoredFailureKeepsItsPhrase() {
    let failure = RoutingNodeFailure(summary: "Clock conflict", message: "The long explanation.")

    #expect(failure.summary == "Clock conflict")
    #expect(failure.message == "The long explanation.")
  }

  @Test(arguments: [
    (NetworkAudioSenderError.invalidHost, "Invalid host"),
    (NetworkAudioSenderError.invalidPort, "Invalid port"),
    (NetworkAudioSenderError.transport(.dns(-1)), "Host not found"),
    (NetworkAudioSenderError.transport(.posix(EADDRINUSE)), "Port in use"),
    (NetworkAudioSenderError.transport(.posix(EHOSTUNREACH)), "Peer unreachable"),
    (NetworkAudioSenderError.transport(.posix(EPERM)), "Network error"),
  ])
  func networkSendFailuresArePhrasedByCause(error: NetworkAudioSenderError, expected: String) {
    #expect(RoutingNodeFailure(error).summary == expected)
  }

  @Test(arguments: [
    (DeviceInputCaptureError.permissionDenied, "Permission denied"),
    (DeviceInputCaptureError.deviceUnavailable(AudioDeviceIDFixture.value), "Device unavailable"),
  ])
  func inputCaptureFailuresArePhrasedByCause(error: DeviceInputCaptureError, expected: String) {
    #expect(RoutingNodeFailure(error).summary == expected)
  }

  @Test
  func fileFailuresArePhrasedByCause() {
    #expect(
      RoutingNodeFailure(AudioFileFrameStreamError.openFailed(status: -43)).summary
        == "File unreadable")
    #expect(RoutingNodeFailure(AudioFileFrameStreamError.nonFileURL).summary == "Invalid file")
  }

  /// A stopped session is an expected teardown rather than something to label on the canvas.
  @Test
  func anExpectedStopHasNoPhrase() {
    #expect(RoutingNodeFailure(NetworkAudioSenderError.alreadyStopped).summary == nil)
    #expect(RoutingNodeFailure(DeviceOutputPlaybackError.alreadyStopped).summary == nil)
  }
}

private enum UnrecognizedTestError: Error, LocalizedError {
  case somethingElse

  var errorDescription: String? { "Something outside the recognized causes went wrong." }
}

private enum AudioDeviceIDFixture {
  static let value = AudioDeviceID(rawValue: "fixture-device")!
}
