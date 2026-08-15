import AppKit
import FlowingDayControls
import RilliyaCore
import SwiftUI

struct AudioCatalogSidebar: View {
  let state: AudioCatalogViewState
  let refresh: () -> Void

  private let identityResolver = ApplicationIdentityResolver()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
        content
      }
      .padding(20)
    }
  }

  private var header: some View {
    HStack(alignment: .center) {
      Text("Rilliya")
        .font(.system(size: 24, weight: .semibold, design: .rounded))

      Spacer(minLength: 12)

      if state.isLoading, state.snapshot != nil {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Refreshing audio catalog")
      }

      Button(action: refresh) {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(.borderless)
      .help("Refresh audio catalog")
      .accessibilityLabel("Refresh audio catalog")
    }
  }

  @ViewBuilder
  private var content: some View {
    if state.isInitialLoad {
      HStack(spacing: 10) {
        ProgressView()
          .controlSize(.small)
        Text("Discovering audio sources…")
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 12)
    } else if let snapshot = state.snapshot {
      catalog(snapshot)
    } else if let errorMessage = state.rootErrorMessage {
      FlowingCallout(
        errorMessage,
        title: "Audio catalog unavailable",
        systemImage: "waveform.badge.exclamationmark",
        tone: .critical
      )

      Button("Try Again", action: refresh)
        .accessibilityHint("Reads the Core Audio catalog again")
    }
  }

  @ViewBuilder
  private func catalog(_ snapshot: AudioCatalogSnapshot) -> some View {
    if let errorMessage = state.rootErrorMessage {
      FlowingCallout(
        errorMessage,
        title: "Refresh failed",
        systemImage: "arrow.clockwise.circle",
        tone: .warning
      )
    }

    if !snapshot.issues.isEmpty {
      FlowingCallout(
        issueSummary(snapshot.issues),
        title: "Some audio items were skipped",
        systemImage: "exclamationmark.triangle",
        tone: .warning
      )
    }

    FlowingSection(
      "Application Outputs",
      footer: "Channel layouts appear after capture begins. Device inputs remain separate sources."
    ) {
      if snapshot.processes.isEmpty {
        emptyRow("No application outputs found", systemImage: "macwindow")
      } else {
        ForEach(Array(snapshot.processes.enumerated()), id: \.element.id) { index, process in
          if index > 0 {
            Divider()
          }
          applicationOutputRow(process)
        }
      }
    }

    FlowingSection("Input Devices", footer: "Inputs are device sources, not private app streams.") {
      let inputs = snapshot.inputDevices.compactMap {
        DeviceEndpointPresentation(device: $0, direction: .input)
      }
      if inputs.isEmpty {
        emptyRow("No input devices found", systemImage: "mic.slash")
      } else {
        endpointRows(inputs)
      }
    }

    FlowingSection("Output Destinations") {
      let outputs = snapshot.outputDevices.compactMap {
        DeviceEndpointPresentation(device: $0, direction: .output)
      }
      if outputs.isEmpty {
        emptyRow("No output devices found", systemImage: "speaker.slash")
      } else {
        endpointRows(outputs)
      }
    }
  }

  @ViewBuilder
  private func endpointRows(_ endpoints: [DeviceEndpointPresentation]) -> some View {
    ForEach(Array(endpoints.enumerated()), id: \.element.id) { index, endpoint in
      if index > 0 {
        Divider()
      }
      DeviceEndpointRow(endpoint: endpoint)
    }
  }

  private func applicationOutputRow(_ process: AudioProcess) -> some View {
    let identity = identityResolver.resolve(process)
    return ApplicationOutputRow(
      presentation: ApplicationOutputPresentation(
        process: process,
        resolvedName: identity.displayName
      ),
      icon: identity.icon
    )
  }

  private func emptyRow(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .font(.callout)
      .foregroundStyle(.secondary)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func issueSummary(_ issues: [AudioCatalogIssue]) -> String {
    let first = issues[0].error.localizedDescription
    guard issues.count > 1 else { return first }
    return "\(first) \(issues.count - 1) more issue(s) were reported."
  }
}

private struct ApplicationOutputRow: View {
  let presentation: ApplicationOutputPresentation
  let icon: NSImage?

  var body: some View {
    HStack(spacing: 10) {
      Group {
        if let icon {
          Image(nsImage: icon)
            .resizable()
        } else {
          Image(systemName: "waveform")
            .resizable()
            .scaledToFit()
            .padding(5)
            .foregroundStyle(.secondary)
        }
      }
      .frame(width: 28, height: 28)
      .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(presentation.title)
          .font(.callout.weight(.medium))
          .lineLimit(1)
        Text(presentation.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Text(presentation.channelDetail)
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
      }

      Spacer(minLength: 6)

      FlowingBadge(
        presentation.isActive ? "Output Active" : "Idle",
        systemImage: presentation.isActive ? "waveform" : nil,
        tone: presentation.isActive ? .success : .neutral
      )
    }
    .padding(12)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "\(presentation.title), application output, "
        + (presentation.isActive ? "active" : "idle")
        + ", \(presentation.channelDetail)"
    )
  }
}

private struct DeviceEndpointRow: View {
  let endpoint: DeviceEndpointPresentation

  @State private var isExpanded = false

  var body: some View {
    FlowingDisclosure(
      isExpanded: $isExpanded,
      contentInsets: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
    ) {
      header
    } content: {
      VStack(spacing: 0) {
        ForEach(Array(endpoint.channels.enumerated()), id: \.element.id) { index, channel in
          if index > 0 {
            Divider()
          }
          DeviceChannelRow(channel: channel)
        }
      }
      .padding(.leading, 50)
      .padding(.trailing, 12)
      .padding(.bottom, 10)
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Image(systemName: endpoint.direction == .input ? "mic" : "speaker.wave.2")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(endpoint.isAlive ? .primary : .tertiary)
        .frame(width: 28, height: 28)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(endpoint.name)
          .font(.callout.weight(.medium))
          .lineLimit(1)
        Text(endpoint.detail)
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 6)

      statusBadges
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }

  @ViewBuilder
  private var statusBadges: some View {
    VStack(alignment: .trailing, spacing: 4) {
      if endpoint.isDefault {
        FlowingBadge("Default", systemImage: "checkmark", tone: .accent)
      }
      if !endpoint.isAlive {
        FlowingBadge("Unavailable", systemImage: "xmark", tone: .critical)
      } else if endpoint.activeStreamCount > 0 {
        FlowingBadge("Stream Active", systemImage: "waveform", tone: .success)
      } else if endpoint.isRunning {
        FlowingBadge("Device Active", systemImage: "waveform", tone: .informational)
      }
    }
  }

  private var accessibilityLabel: String {
    let kind = endpoint.direction == .input ? "input source" : "output destination"
    var values = [endpoint.name, kind, endpoint.detail]
    if endpoint.isDefault { values.append("default") }
    if !endpoint.isAlive {
      values.append("unavailable")
    } else if endpoint.activeStreamCount > 0 {
      values.append("stream active")
    } else if endpoint.isRunning {
      values.append("device active")
    }
    return values.joined(separator: ", ")
  }
}

private struct DeviceChannelRow: View {
  let channel: DeviceChannelPresentation

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "circle.fill")
        .font(.system(size: 5))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)

      Text(channel.title)
        .font(.caption.weight(.medium).monospacedDigit())

      Spacer(minLength: 8)

      if let nativeMapping = channel.nativeMapping {
        Text(nativeMapping)
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(channel.title)
    .accessibilityValue(channel.nativeMapping ?? "No native stream mapping reported")
  }
}
