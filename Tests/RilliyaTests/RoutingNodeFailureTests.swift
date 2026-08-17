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

  @Test
  func inputCapturePermissionDenialIsPhrasedByCause() {
    #expect(
      RoutingNodeFailure(DeviceInputCaptureError.permissionDenied).summary
        == "Permission denied")
  }

  @Test
  func inputCaptureDeviceLossIsPhrasedByCause() throws {
    let deviceID = try #require(AudioDeviceID(rawValue: "fixture-device"))

    #expect(
      RoutingNodeFailure(DeviceInputCaptureError.deviceUnavailable(deviceID)).summary
        == "Device unavailable")
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

@Suite("Walking a workflow's failing nodes")
struct RoutingFailureWalkTests {
  private let nodes = ["a", "b", "c"]

  @Test("The walk starts at the first node and wraps past the end")
  func walkWrapsAround() {
    var current: String?
    var visited: [String] = []
    for _ in 0..<4 {
      current = RoutingWorkflowFailures.nodeAfter(current, in: nodes)
      visited.append(current ?? "")
    }

    #expect(visited == ["a", "b", "c", "a"])
  }

  @Test("Nothing to reveal when nothing is failing")
  func emptyListRevealsNothing() {
    #expect(RoutingWorkflowFailures.nodeAfter(nil, in: [String]()) == nil)
    #expect(RoutingWorkflowFailures.nodeAfter("a", in: [String]()) == nil)
  }

  /// A node that recovers while the user is stepping through must not strand the walk.
  @Test("A node that stops failing restarts the walk rather than stranding it")
  func recoveredNodeRestartsTheWalk() {
    #expect(RoutingWorkflowFailures.nodeAfter("gone", in: nodes) == "a")
  }

  /// A node failing partway through the walk joins the list without resetting it.
  @Test("A newly failing node joins the walk in canvas order")
  func newFailureJoinsInOrder() {
    #expect(RoutingWorkflowFailures.nodeAfter("a", in: ["a", "new", "b", "c"]) == "new")
  }

  @Test("A single failing node is revealed again on every press")
  func singleNodeRepeats() {
    #expect(RoutingWorkflowFailures.nodeAfter(nil, in: ["only"]) == "only")
    #expect(RoutingWorkflowFailures.nodeAfter("only", in: ["only"]) == "only")
  }
}
