import AppKit
import FlowingDayControls
import SwiftUI

struct RilliyaOnboardingOverlay: View {
  @Bindable var coordinator: RilliyaOnboardingCoordinator
  let createWorkflows: @MainActor ([RilliyaOnboardingGoal]) async throws -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      Rectangle()
        .fill(.ultraThinMaterial)
        .overlay(Color.black.opacity(0.08))
        .ignoresSafeArea()
        .onTapGesture {}

      FlowingCard(
        spacing: 0,
        contentInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)
      ) {
        ZStack {
          switch coordinator.step {
          case .welcome:
            welcome
              .transition(stepTransition)
          case .capabilityModel:
            capabilityModel
              .transition(stepTransition)
          case nil:
            EmptyView()
          }
        }
        .frame(maxWidth: .infinity, minHeight: cardHeight)
      }
      .frame(maxWidth: 780)
      .shadow(color: .black.opacity(0.12), radius: 34, y: 18)
      .padding(28)
    }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isModal)
  }

  private var welcome: some View {
    VStack(spacing: 0) {
      overlayHeader(step: 0)

      VStack(spacing: 26) {
        VStack(spacing: 16) {
          Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .scaledToFit()
            .frame(width: 68, height: 68)
            .accessibilityHidden(true)

          VStack(spacing: 8) {
            Text("Route audio your way.")
              .font(.system(size: 40, weight: .semibold, design: .rounded))
              .tracking(-1.2)
              .foregroundStyle(FlowingPalette.ink)

            Text(
              "Capture, shape, and route audio wherever you need it."
            )
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(FlowingPalette.muted)
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .frame(maxWidth: 590)
          }
        }

        OnboardingRouteModel()
          .frame(maxWidth: 650)

        VStack(spacing: 10) {
          Button {
            animate { coordinator.begin() }
          } label: {
            Label("Get Started", systemImage: "arrow.right")
              .labelStyle(.titleAndIcon)
              .frame(minWidth: 126)
              .padding(.vertical, 3)
          }
          .buttonStyle(FlowingSoftButtonStyle(isProminent: true))
          .keyboardShortcut(.defaultAction)

          Button("Explore on My Own") {
            coordinator.dismiss()
          }
          .buttonStyle(.plain)
          .font(.callout.weight(.semibold))
          .foregroundStyle(FlowingPalette.muted)

          Text("No driver or permission is required to begin.")
            .font(.caption)
            .foregroundStyle(FlowingPalette.faint)
        }
      }
      .padding(.horizontal, 42)
      .padding(.bottom, 32)
    }
  }

  private var capabilityModel: some View {
    VStack(spacing: 0) {
      overlayHeader(step: 1)

      VStack(alignment: .leading, spacing: 22) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Choose what to explore")
            .font(.system(size: 30, weight: .semibold, design: .rounded))
            .tracking(-0.5)
            .foregroundStyle(FlowingPalette.ink)
          Text("Pick one or more. We'll create a starter workflow for each.")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(FlowingPalette.muted)
        }

        HStack(alignment: .top, spacing: 12) {
          ForEach(RilliyaOnboardingGoal.allCases, id: \.self) { goal in
            OnboardingGoalButton(
              goal: goal,
              isSelected: coordinator.selectedGoals.contains(goal)
            ) {
              animate { coordinator.toggle(goal) }
            }
          }
        }

        HStack(spacing: 12) {
          Button {
            animate { coordinator.goBack() }
          } label: {
            Label("Back", systemImage: "arrow.left")
              .padding(.vertical, 3)
          }
          .buttonStyle(FlowingSoftButtonStyle())

          Spacer()

          if coordinator.isDesignPreview {
            Text("Design preview · workflows won't be saved")
              .font(.caption)
              .foregroundStyle(FlowingPalette.faint)
          }

          Button {
            Task {
              await coordinator.createSelectedWorkflows(using: createWorkflows)
            }
          } label: {
            HStack(spacing: 8) {
              if coordinator.isCreatingWorkflows {
                ProgressView()
                  .controlSize(.small)
              }
              Text(selectionActionTitle)
            }
          }
          .buttonStyle(FlowingSoftButtonStyle(isProminent: true))
          .disabled(coordinator.selectedGoals.isEmpty || coordinator.isCreatingWorkflows)
        }

        if let issue = coordinator.creationIssue {
          Label(issue, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(FlowingAccent.pollen.foreground)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.horizontal, 30)
      .padding(.bottom, 28)
    }
  }

  private func overlayHeader(step: Int) -> some View {
    HStack(spacing: 12) {
      Text("RILLIYA QUICK START")
        .font(.caption2.weight(.bold))
        .tracking(1.1)
        .foregroundStyle(FlowingPalette.faint)

      HStack(spacing: 5) {
        ForEach(0..<2, id: \.self) { index in
          Capsule()
            .fill(index == step ? FlowingAccent.fern.fill : FlowingPalette.hairline)
            .frame(width: index == step ? 22 : 8, height: 5)
        }
      }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: step)
      .accessibilityHidden(true)

      Spacer()

      Button("Close", systemImage: "xmark") {
        coordinator.dismiss()
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.plain)
      .font(.system(size: 12, weight: .bold))
      .foregroundStyle(FlowingPalette.muted)
      .frame(width: 28, height: 28)
      .background(FlowingPalette.control, in: Circle())
      .accessibilityLabel("Close Quick Start")
    }
    .padding(.top, 20)
    .padding(.horizontal, 22)
    .padding(.bottom, 14)
  }

  private var stepTransition: AnyTransition {
    guard !reduceMotion else { return .opacity }
    switch coordinator.navigationDirection {
    case .forward:
      return .asymmetric(
        insertion: .move(edge: .trailing).combined(with: .opacity),
        removal: .move(edge: .leading).combined(with: .opacity)
      )
    case .backward:
      return .asymmetric(
        insertion: .move(edge: .leading).combined(with: .opacity),
        removal: .move(edge: .trailing).combined(with: .opacity)
      )
    }
  }

  private var cardHeight: CGFloat {
    guard coordinator.step == .capabilityModel else { return 510 }
    return coordinator.creationIssue == nil ? 438 : 478
  }

  private var selectionActionTitle: String {
    switch coordinator.selectedGoals.count {
    case 0:
      "Select a Workflow"
    case 1:
      "Create 1 Workflow"
    default:
      "Create \(coordinator.selectedGoals.count) Workflows"
    }
  }

  private func animate(_ action: () -> Void) {
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24), action)
  }
}

private struct OnboardingRouteModel: View {
  var body: some View {
    HStack(spacing: 12) {
      OnboardingRouteStage(
        title: "Source",
        detail: "App or input",
        systemImage: "waveform.badge.plus",
        accent: .fern
      )
      connector
      OnboardingRouteStage(
        title: "Shape or Observe",
        detail: "Mix, adjust, measure",
        systemImage: "slider.horizontal.3",
        accent: .pollen
      )
      connector
      OnboardingRouteStage(
        title: "Destination",
        detail: "Speakers, file, or app",
        systemImage: "speaker.wave.2",
        accent: .brook
      )
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(
      "A route flows from a source, through optional shaping or observation, to a destination"
    )
  }

  private var connector: some View {
    Image(systemName: "arrow.right")
      .font(.system(size: 12, weight: .bold))
      .foregroundStyle(FlowingPalette.faint)
      .accessibilityHidden(true)
  }
}

private struct OnboardingRouteStage: View {
  let title: String
  let detail: String
  let systemImage: String
  let accent: FlowingAccent

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 19, weight: .semibold))
        .foregroundStyle(accent.foreground)
        .frame(width: 38, height: 38)
        .background(accent.veil, in: RoundedRectangle(cornerRadius: 11, style: .continuous))

      VStack(spacing: 2) {
        Text(title)
          .font(.callout.weight(.semibold))
          .foregroundStyle(FlowingPalette.ink)
        Text(detail)
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
          .lineLimit(1)
      }
    }
    .padding(.vertical, 15)
    .padding(.horizontal, 12)
    .frame(maxWidth: .infinity)
    .background(
      accent.wash.opacity(0.56), in: RoundedRectangle(cornerRadius: 16, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(accent.fill.opacity(0.16))
    }
  }
}

private struct OnboardingGoalButton: View {
  let goal: RilliyaOnboardingGoal
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 13) {
        HStack {
          OnboardingGoalRouteGlyph(goal: goal)
          Spacer()
          Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(isSelected ? FlowingAccent.fern.fill : FlowingPalette.hairline)
        }

        VStack(alignment: .leading, spacing: 5) {
          Text(goal.title)
            .font(.headline)
            .foregroundStyle(FlowingPalette.ink)
          Text(goal.summary)
            .font(.callout)
            .foregroundStyle(FlowingPalette.muted)
            .fixedSize(horizontal: false, vertical: true)
        }

        Text(goal.routeLabel)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(FlowingPalette.faint)
          .lineLimit(1)
      }
      .padding(16)
      .frame(maxWidth: .infinity, minHeight: 184, alignment: .topLeading)
      .background(
        isSelected ? FlowingAccent.fern.veil : FlowingPalette.control,
        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(
            isSelected ? FlowingAccent.fern.fill.opacity(0.58) : FlowingPalette.hairline,
            lineWidth: isSelected ? 1.5 : 1
          )
      }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(goal.title)
    .accessibilityValue(isSelected ? "Selected" : "Not selected")
    .accessibilityHint(goal.summary)
  }
}

private struct OnboardingGoalRouteGlyph: View {
  let goal: RilliyaOnboardingGoal

  var body: some View {
    HStack(spacing: 5) {
      glyph(goal.sourceImage, accent: goal.sourceAccent)
      Image(systemName: "arrow.right")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(FlowingPalette.faint)
      glyph(goal.destinationImage, accent: goal.destinationAccent)
    }
    .accessibilityHidden(true)
  }

  private func glyph(_ systemImage: String, accent: FlowingAccent) -> some View {
    Image(systemName: systemImage)
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(accent.foreground)
      .frame(width: 28, height: 28)
      .background(accent.veil, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

extension RilliyaOnboardingGoal {
  fileprivate var title: String {
    switch self {
    case .listenToApplication: "Listen to an App"
    case .routeInput: "Route a Microphone"
    case .recordApplication: "Record an App"
    }
  }

  fileprivate var summary: String {
    switch self {
    case .listenToApplication: "Hear one application's audio through an output you choose."
    case .routeInput: "Monitor a microphone or audio interface through your chosen output."
    case .recordApplication: "Capture one application directly into an audio file."
    }
  }

  fileprivate var routeLabel: String {
    switch self {
    case .listenToApplication: "APPLICATION AUDIO → OUTPUT AUDIO"
    case .routeInput: "INPUT AUDIO → OUTPUT AUDIO"
    case .recordApplication: "APPLICATION AUDIO → FILE OUTPUT"
    }
  }

  fileprivate var sourceImage: String {
    switch self {
    case .listenToApplication, .recordApplication:
      RoutingNodeKind.applicationAudio.systemImage
    case .routeInput:
      RoutingNodeKind.inputAudio.systemImage
    }
  }

  fileprivate var destinationImage: String {
    switch self {
    case .listenToApplication, .routeInput:
      RoutingNodeKind.outputAudio.systemImage
    case .recordApplication:
      RoutingNodeKind.fileOutput.systemImage
    }
  }

  fileprivate var sourceAccent: FlowingAccent {
    switch self {
    case .listenToApplication, .recordApplication:
      RoutingNodeKind.applicationAudio.builtInAccentID.accent
    case .routeInput:
      RoutingNodeKind.inputAudio.builtInAccentID.accent
    }
  }

  fileprivate var destinationAccent: FlowingAccent {
    switch self {
    case .listenToApplication, .routeInput:
      RoutingNodeKind.outputAudio.builtInAccentID.accent
    case .recordApplication:
      RoutingNodeKind.fileOutput.builtInAccentID.accent
    }
  }
}
