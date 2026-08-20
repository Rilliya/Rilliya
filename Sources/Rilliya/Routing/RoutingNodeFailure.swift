import FlowingDayControls
import Foundation
import RilliyaCapture
import RilliyaFilePlayback
import RilliyaFileWriting
import RilliyaNetworkAudio
import RilliyaPlayback
import RilliyaRealtime
import SwiftUI

/// Why a routing node stopped, in both the length a canvas node can show and the length the
/// inspector can show.
struct RoutingNodeFailure: Equatable, Hashable, Sendable {
  /// A few words the canvas can draw beside the node, or `nil` when the cause is unrecognized.
  let summary: String?

  /// The full explanation, always present.
  let message: String

  init(summary: String? = nil, message: String) {
    self.summary = summary
    self.message = message
  }

  init(_ error: any Error) {
    self.init(
      summary: RoutingNodeFailureSummary.summary(for: error),
      message: error.localizedDescription
    )
  }

  func title(fallback: String) -> String {
    summary ?? fallback
  }
}

struct RoutingNodeIssueView: View {
  let title: String
  let message: String

  init(_ failure: RoutingNodeFailure, fallbackTitle: String) {
    title = failure.title(fallback: fallbackTitle)
    message = failure.message
  }

  init(title: String, message: String) {
    self.title = title
    self.message = message
  }

  var body: some View {
    FlowingCallout(
      message,
      title: title,
      systemImage: "exclamationmark.circle.fill",
      tone: .critical,
      presentation: .inline
    )
  }
}

/// Maps a recognized error to the short phrase a canvas node shows without being selected.
///
/// An unrecognized error returns `nil` rather than a truncated sentence: a node showing the first
/// few words of an arbitrary message reads as noise, and the inspector already has the full text.
enum RoutingNodeFailureSummary {
  static func summary(for error: any Error) -> String? {
    switch error {
    case let error as RoutingPreparedAudioGraphError: summary(for: error)
    case let error as NetworkAudioSenderError: summary(for: error)
    case let error as NetworkAudioReceiverError: summary(for: error)
    case let error as NetworkAudioFormatDiscoveryError: summary(for: error)
    case let error as DeviceOutputPlaybackError: summary(for: error)
    case let error as DeviceInputCaptureError: summary(for: error)
    case let error as DeviceOutputCaptureError: summary(for: error)
    case let error as ProcessOutputCaptureError: summary(for: error)
    case let error as AudioFileFrameStreamError: summary(for: error)
    case let error as AudioFileWriterError: summary(for: error)
    case is RoutingNetworkAudioKeySourceError, is RoutingNetworkAudioKeychainError:
      "Key unavailable"
    default: nil
    }
  }

  private static func summary(for error: RoutingPreparedAudioGraphError) -> String? {
    switch error {
    case .missingOutputNode: "Output missing"
    case .missingCapture: "Source unavailable"
    case .invalidRoute: "Invalid route"
    case .cycle: "Feedback loop"
    case .resourceBudgetExceeded: "Graph too large"
    }
  }

  private static func summary(for error: NetworkAudioSenderError) -> String? {
    switch error {
    case .invalidHost: "Invalid host"
    case .invalidPort: "Invalid port"
    case .invalidDatagramBound, .invalidBufferCapacity, .invalidPacketFrameCount,
      .invalidRetransmissionDepth:
      "Invalid settings"
    case .alreadyStopped: nil
    case .transport(let failure): summary(for: failure)
    case .packet: "Malformed packet"
    case .codec: "Format not carried"
    }
  }

  private static func summary(for error: NetworkAudioReceiverError) -> String? {
    switch error {
    case .invalidPort: "Invalid port"
    case .invalidDatagramBound, .invalidBufferCapacity, .invalidTakeoverInterval,
      .invalidReorderDepth, .invalidDestinationCount:
      "Invalid settings"
    case .alreadyStopped: nil
    case .transport(let failure): summary(for: failure)
    }
  }

  private static func summary(for error: NetworkAudioFormatDiscoveryError) -> String? {
    switch error {
    case .timedOut: "No sender heard"
    case .invalidPort: "Invalid port"
    case .invalidTimeout: "Invalid settings"
    case .transport(let failure): summary(for: failure)
    }
  }

  private static func summary(for failure: NetworkAudioTransportFailure) -> String? {
    switch failure {
    case .posix(let code) where code == EADDRINUSE: "Port in use"
    case .posix(let code) where code == EADDRNOTAVAIL: "Address unavailable"
    case .posix(let code) where code == EHOSTUNREACH || code == ENETUNREACH: "Peer unreachable"
    case .dns: "Host not found"
    case .posix, .tls, .unknown: "Network error"
    }
  }

  private static func summary(for error: DeviceOutputPlaybackError) -> String? {
    switch error {
    case .deviceNotFound: "Device not found"
    case .deviceUnavailable: "Device unavailable"
    case .noOutputChannels: "No output channels"
    case .unsupportedFormat, .incompatibleRenderer: "Unsupported format"
    case .alreadyStopped: nil
    case .hardware: "Device error"
    case .renderer: "Render error"
    }
  }

  private static func summary(for error: DeviceInputCaptureError) -> String? {
    switch error {
    case .deviceNotFound: "Device not found"
    case .deviceUnavailable: "Device unavailable"
    case .noInputChannels: "No input channels"
    case .unsupportedFormat: "Unsupported format"
    case .permissionDenied: "Permission denied"
    case .alreadyStopped: nil
    case .hardware, .invalidPropertyData: "Device error"
    }
  }

  private static func summary(for error: DeviceOutputCaptureError) -> String? {
    switch error {
    case .noDefaultOutputDevice: "No output device"
    case .processNotFound: "App not running"
    case .deviceNotFound: "Device not found"
    case .deviceUnavailable: "Device unavailable"
    case .noOutputStream: "No output stream"
    case .tapUnavailable: "Capture unavailable"
    case .unsupportedFormat: "Unsupported format"
    case .alreadyStopped: nil
    case .hardware, .invalidPropertyData: "Capture error"
    }
  }

  private static func summary(for error: ProcessOutputCaptureError) -> String? {
    switch error {
    case .processNotFound: "App not running"
    case .noOutputDevice: "No output device"
    case .noOutputStream: "No output stream"
    case .tapUnavailable: "Capture unavailable"
    case .unsupportedFormat: "Unsupported format"
    case .alreadyStopped: nil
    case .hardware, .invalidPropertyData: "Capture error"
    }
  }

  private static func summary(for error: AudioFileFrameStreamError) -> String? {
    switch error {
    case .nonFileURL: "Invalid file"
    case .invalidSampleRate: "Invalid sample rate"
    case .invalidLoopMode, .invalidBufferConfiguration: "Invalid settings"
    case .unsupportedChannelCount: "Unsupported channels"
    case .openFailed: "File unreadable"
    case .formatConfigurationFailed: "Unsupported format"
    case .readFailed: "Read failed"
    case .seekFailed: "Seek failed"
    }
  }

  private static func summary(for error: AudioFileWriterError) -> String? {
    switch error {
    case .nonFileURL, .invalidDestination: "Invalid destination"
    case .invalidSampleRate: "Invalid sample rate"
    case .unsupportedChannelCount: "Unsupported channels"
    case .invalidBufferConfiguration: "Invalid settings"
    case .unsupportedBitDepth, .invalidBitRate, .incompatibleContainerAndEncoding:
      "Unsupported format"
    case .encoderUnavailable: "Encoder unavailable"
    case .destinationExists: "File exists"
    case .createFailed: "Cannot create file"
    case .formatConfigurationFailed: "Unsupported format"
    case .writeFailed: "Write failed"
    case .cancelled: nil
    }
  }
}

/// A destination or capture controller that can report why one node stopped.
@MainActor
protocol RoutingNodeFailureReporting: AnyObject {
  func failure(for nodeID: UUID) -> RoutingNodeFailure?
}

extension RoutingCaptureController: RoutingNodeFailureReporting {
  func failure(for nodeID: UUID) -> RoutingNodeFailure? {
    guard case .failed(let failure) = state(for: nodeID) else { return nil }
    return failure
  }
}

extension RoutingInputCaptureController: RoutingNodeFailureReporting {
  func failure(for nodeID: UUID) -> RoutingNodeFailure? {
    guard case .failed(let failure) = state(for: nodeID) else { return nil }
    return failure
  }
}

extension RoutingOutputCaptureController: RoutingNodeFailureReporting {
  func failure(for nodeID: UUID) -> RoutingNodeFailure? {
    guard case .failed(let failure) = state(for: nodeID) else { return nil }
    return failure
  }
}

extension RoutingAudioOutputController: RoutingNodeFailureReporting {
  func failure(for nodeID: UUID) -> RoutingNodeFailure? {
    guard case .failed(let failure) = state(for: nodeID) else { return nil }
    return failure
  }
}

extension RoutingFilePlaybackController: RoutingNodeFailureReporting {
  func failure(for nodeID: UUID) -> RoutingNodeFailure? {
    guard case .failed(let failure) = state(for: nodeID) else { return nil }
    return failure
  }
}

extension RoutingFileOutputController: RoutingNodeFailureReporting {
  func failure(for nodeID: UUID) -> RoutingNodeFailure? {
    guard case .failed(let failure) = state(for: nodeID) else { return nil }
    return failure
  }
}

extension RoutingNetworkSendController: RoutingNodeFailureReporting {
  func failure(for nodeID: UUID) -> RoutingNodeFailure? {
    guard case .failed(let failure) = state(for: nodeID) else { return nil }
    return failure
  }
}

extension RoutingNetworkReceiveController: RoutingNodeFailureReporting {
  func failure(for nodeID: UUID) -> RoutingNodeFailure? {
    guard case .failed(let failure) = state(for: nodeID) else { return nil }
    return failure
  }
}

/// How a workflow is doing, so a paused workflow, a healthy one, and one running with stopped
/// nodes are distinguishable without opening it.
enum RoutingWorkflowRunState: Equatable {
  case paused
  case running
  case runningWithIssues(count: Int)

  init(isRunning: Bool, failingNodeCount: Int) {
    guard isRunning else {
      self = .paused
      return
    }
    self = failingNodeCount > 0 ? .runningWithIssues(count: failingNodeCount) : .running
  }

  var accessibilityValue: String {
    switch self {
    case .paused: "Paused"
    case .running: "Running"
    case .runningWithIssues(let count):
      "Running, \(count) stopped node\(count == 1 ? "" : "s")"
    }
  }
}

extension RoutingWorkflowRunState {
  var indicatorColor: Color {
    switch self {
    case .paused: FlowingPalette.hairline
    case .running: Color(nsColor: .systemGreen)
    case .runningWithIssues: Color(nsColor: .systemOrange)
    }
  }
}

@MainActor
enum RoutingWorkflowFailures {
  /// The nodes a running workflow could not start, in canvas order so stepping through them
  /// follows the graph rather than a hash.
  static func failingNodeIDs(
    in workflow: RoutingWorkflowModel,
    reporters: [any RoutingNodeFailureReporting]
  ) -> [UUID] {
    guard workflow.isRunning else { return [] }
    return workflow.workspace.nodes
      .filter { node in reporters.contains { $0.failure(for: node.id) != nil } }
      .map(\.id)
  }

  /// The failing node to reveal after `current`, wrapping past the end.
  ///
  /// Advancing from the node last revealed rather than from a remembered position keeps the walk
  /// in step when a node recovers or a new one fails partway through it. A `current` that is no
  /// longer failing restarts the walk rather than stranding it.
  nonisolated static func nodeAfter<ID: Equatable>(_ current: ID?, in failing: [ID]) -> ID? {
    guard !failing.isEmpty else { return nil }
    let position = current.flatMap { id in failing.firstIndex(of: id) }
    return failing[((position ?? -1) + 1) % failing.count]
  }
}
