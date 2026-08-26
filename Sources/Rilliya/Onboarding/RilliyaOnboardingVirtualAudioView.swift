import AppKit
import FlowingDayControls
import RilliyaVirtualAudio
import SwiftUI

struct RilliyaOnboardingVirtualAudioStep: View {
  @Bindable var coordinator: RilliyaOnboardingCoordinator
  @Bindable var virtualAudioController: RilliyaVirtualAudioController
  let createWorkflows: @MainActor ([RilliyaOnboardingGoal]) async throws -> Void
  let onBack: () -> Void

  @State private var installerHandoffStarted = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Route audio between apps")
          .font(.system(size: 30, weight: .semibold, design: .rounded))
          .tracking(-0.5)
          .foregroundStyle(FlowingPalette.ink)
        Text("Virtual Audio is optional. Your starter workflows work without it.")
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(FlowingPalette.muted)
      }

      HStack(alignment: .top, spacing: 12) {
        OnboardingVirtualAudioRoute(
          title: "Bring audio into Rilliya",
          detail:
            "Play the other app to Virtual Output, then receive it with a Virtual Output node.",
          direction: .intoRilliya
        )
        OnboardingVirtualAudioRoute(
          title: "Send audio to another app",
          detail:
            "Route to a Virtual Input node, then choose that device as the other app's microphone.",
          direction: .outOfRilliya
        )
      }

      OnboardingVirtualAudioImpact()
      virtualAudioStatus

      if let issue = coordinator.creationIssue {
        Label(issue, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(FlowingAccent.pollen.foreground)
          .fixedSize(horizontal: false, vertical: true)
      }

      footer
    }
    .padding(.horizontal, 30)
    .padding(.bottom, 26)
    .task(id: coordinator.step) {
      await monitorVirtualAudioDriver()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      guard coordinator.step == .virtualAudio else { return }
      Task {
        await virtualAudioController.refresh()
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Button(action: onBack) {
        Label("Back", systemImage: "arrow.left")
          .padding(.vertical, 3)
      }
      .buttonStyle(FlowingSoftButtonStyle())

      Spacer()

      Text(workflowCompletionSummary)
        .font(.caption)
        .foregroundStyle(FlowingPalette.faint)

      if virtualAudioController.availability == .available {
        Button {
          Task {
            await coordinator.completeOnboarding(using: createWorkflows)
          }
        } label: {
          completionLabel("Continue")
        }
        .buttonStyle(FlowingSoftButtonStyle(isProminent: true))
        .disabled(coordinator.isCreatingWorkflows)
      } else {
        Button {
          Task {
            await coordinator.completeOnboarding(using: createWorkflows)
          }
        } label: {
          completionLabel("Not Now")
        }
        .buttonStyle(FlowingSoftButtonStyle())
        .disabled(coordinator.isCreatingWorkflows)

        if !coordinator.isDesignPreview && virtualAudioController.isInstallerBundled {
          Button {
            openInstaller()
          } label: {
            Label(
              installerHandoffStarted ? "Reopen Installer" : "Open Installer",
              systemImage: "arrow.up.forward.app"
            )
            .padding(.vertical, 3)
          }
          .buttonStyle(FlowingSoftButtonStyle(isProminent: true))
          .disabled(virtualAudioController.isWorking)
        } else {
          Label("Installer unavailable in this build", systemImage: "shippingbox")
            .font(.caption.weight(.medium))
            .foregroundStyle(FlowingPalette.faint)
        }
      }
    }
  }

  private var virtualAudioStatus: some View {
    HStack(spacing: 12) {
      Image(systemName: virtualAudioStatusImage)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(virtualAudioStatusAccent.foreground)
        .frame(width: 34, height: 34)
        .background(
          virtualAudioStatusAccent.veil,
          in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )

      VStack(alignment: .leading, spacing: 2) {
        Text(virtualAudioStatusTitle)
          .font(.callout.weight(.semibold))
          .foregroundStyle(FlowingPalette.ink)
        Text(virtualAudioStatusDetail)
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
          .lineLimit(2)
      }

      Spacer()

      if virtualAudioController.isWorking {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Checking Virtual Audio")
      } else {
        Button("Check Again", systemImage: "arrow.clockwise") {
          Task {
            await virtualAudioController.refresh()
          }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(virtualAudioStatusAccent.foreground)
        .frame(width: 28, height: 28)
        .background(FlowingPalette.control, in: Circle())
        .accessibilityLabel("Check Virtual Audio Again")
      }
    }
    .padding(.vertical, 10)
    .padding(.horizontal, 12)
    .background(
      virtualAudioStatusAccent.wash.opacity(0.42),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(virtualAudioStatusAccent.fill.opacity(0.14))
    }
  }

  private var virtualAudioStatusTitle: String {
    if virtualAudioController.issue != nil {
      return "Virtual Audio could not be checked"
    }
    switch virtualAudioController.availability {
    case .available:
      return "Virtual Audio is ready"
    case .notInstalled where installerHandoffStarted:
      return "Waiting for Virtual Audio"
    case .notInstalled:
      return "Driver not installed"
    case nil:
      return "Checking Virtual Audio"
    }
  }

  private var virtualAudioStatusDetail: String {
    if let issue = virtualAudioController.issue {
      return issue
    }
    switch virtualAudioController.availability {
    case .available:
      return "Core Audio can see the driver. You can continue when you're ready."
    case .notInstalled where installerHandoffStarted:
      return "Installer opened · driver not detected yet. Rilliya will keep checking."
    case .notInstalled:
      return "Install it now, or continue without it and return later."
    case nil:
      return "Looking for the driver in Core Audio."
    }
  }

  private var virtualAudioStatusImage: String {
    if virtualAudioController.issue != nil {
      return "exclamationmark.triangle"
    }
    switch virtualAudioController.availability {
    case .available:
      return "checkmark.seal"
    case .notInstalled where installerHandoffStarted:
      return "clock"
    case .notInstalled:
      return "externaldrive.badge.plus"
    case nil:
      return "waveform"
    }
  }

  private var virtualAudioStatusAccent: FlowingAccent {
    if virtualAudioController.issue != nil {
      return .pollen
    }
    return virtualAudioController.availability == .available ? .fern : .brook
  }

  private var workflowCompletionSummary: String {
    switch coordinator.selectedGoals.count {
    case 0:
      "Empty canvas"
    case 1:
      "1 workflow selected"
    default:
      "\(coordinator.selectedGoals.count) workflows selected"
    }
  }

  private func completionLabel(_ title: String) -> some View {
    HStack(spacing: 8) {
      if coordinator.isCreatingWorkflows {
        ProgressView()
          .controlSize(.small)
      }
      Text(title)
    }
    .padding(.vertical, 3)
  }

  private func openInstaller() {
    virtualAudioController.openInstaller()
    if virtualAudioController.issue == nil {
      installerHandoffStarted = true
    }
  }

  private func monitorVirtualAudioDriver() async {
    guard coordinator.step == .virtualAudio else { return }
    await virtualAudioController.refresh()
    while !Task.isCancelled, coordinator.step == .virtualAudio,
      virtualAudioController.availability != .available
    {
      do {
        try await Task.sleep(nanoseconds: 5_000_000_000)
      } catch {
        return
      }
      guard coordinator.step == .virtualAudio else { return }
      await virtualAudioController.refresh()
    }
  }
}

private enum OnboardingVirtualAudioDirection {
  case intoRilliya
  case outOfRilliya
}

private struct OnboardingVirtualAudioRoute: View {
  let title: String
  let detail: String
  let direction: OnboardingVirtualAudioDirection

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.headline)
          .foregroundStyle(FlowingPalette.ink)
        Text(detail)
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: 7) {
        routeStage(firstTitle, systemImage: firstImage, accent: firstAccent)
        routeArrow
        routeStage(deviceTitle, systemImage: deviceImage, accent: .brook)
        routeArrow
        routeStage(lastTitle, systemImage: lastImage, accent: lastAccent)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, minHeight: 164, alignment: .topLeading)
    .background(
      FlowingPalette.control,
      in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(FlowingPalette.hairline)
    }
    .accessibilityElement(children: .combine)
  }

  private var firstTitle: String {
    direction == .intoRilliya ? "Other App" : "Rilliya"
  }

  private var firstImage: String {
    direction == .intoRilliya ? "app.dashed" : "waveform.path"
  }

  private var firstAccent: FlowingAccent {
    direction == .intoRilliya ? .pollen : .fern
  }

  private var deviceTitle: String {
    direction == .intoRilliya ? "Virtual Output" : "Virtual Input"
  }

  private var deviceImage: String {
    direction == .intoRilliya ? "speaker.wave.2" : "mic"
  }

  private var lastTitle: String {
    direction == .intoRilliya ? "Rilliya" : "Other App"
  }

  private var lastImage: String {
    direction == .intoRilliya ? "waveform.path" : "app.dashed"
  }

  private var lastAccent: FlowingAccent {
    direction == .intoRilliya ? .fern : .pollen
  }

  private var routeArrow: some View {
    Image(systemName: "arrow.right")
      .font(.system(size: 9, weight: .bold))
      .foregroundStyle(FlowingPalette.faint)
      .accessibilityHidden(true)
  }

  private func routeStage(
    _ title: String,
    systemImage: String,
    accent: FlowingAccent
  ) -> some View {
    VStack(spacing: 5) {
      Image(systemName: systemImage)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(accent.foreground)
        .frame(width: 30, height: 30)
        .background(
          accent.veil,
          in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
      Text(title)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(FlowingPalette.muted)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity)
  }
}

private struct OnboardingVirtualAudioImpact: View {
  var body: some View {
    HStack(spacing: 18) {
      fact("Optional install", systemImage: "shippingbox")
      fact("Admin approval", systemImage: "person.badge.key")
      fact("Audio may pause", systemImage: "speaker.slash")

      Spacer(minLength: 4)

      Text("Remove it later in Preferences")
        .font(.caption.weight(.medium))
        .foregroundStyle(FlowingPalette.faint)
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 14)
    .background(
      FlowingAccent.pollen.wash.opacity(0.42),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .strokeBorder(FlowingAccent.pollen.fill.opacity(0.14))
    }
  }

  private func fact(_ title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .font(.caption.weight(.semibold))
      .foregroundStyle(FlowingPalette.muted)
      .lineLimit(1)
  }
}
