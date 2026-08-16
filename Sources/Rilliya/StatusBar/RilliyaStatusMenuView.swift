import AppKit
import FlowingDayControls
import SwiftUI

enum RilliyaStatusMenuLayout {
  static let width: CGFloat = 340
  static let maximumInlineApplicationCount = 3
  static let maximumApplicationListHeight: CGFloat = 276

  static func usesScrollableApplicationList(for count: Int) -> Bool {
    count > maximumInlineApplicationCount
  }
}

struct RilliyaStatusMenuView: View {
  @Environment(\.openWindow) private var openWindow
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  @Bindable var runtime: RilliyaRuntime
  @Bindable var settings: RilliyaSettings

  @State private var isApplicationsExpanded = true
  @State private var isApplicationPickerPresented = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header

      workflowsSection

      applicationsSection

      Divider()
        .overlay(FlowingPalette.hairline)

      HStack(spacing: 8) {
        Button("Preferences…") {
          RilliyaPreferencesWindowController.shared.showPreferences()
        }
        .buttonStyle(FlowingSoftButtonStyle())

        Spacer(minLength: 8)

        Button("Quit Rilliya") {
          NSApp.terminate(nil)
        }
        .buttonStyle(FlowingSoftButtonStyle())
      }
    }
    .padding(14)
    .frame(width: RilliyaStatusMenuLayout.width)
    .flowingAccent(.fern)
    .flowingSurfaces(statusMenuSurfaces)
    .preferredColorScheme(settings.appearance.preferredColorScheme)
  }

  private var workflowsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Button {
        settings.showsWorkflowsInStatusMenu.toggle()
      } label: {
        HStack(spacing: 8) {
          Text("Workflows")
            .font(.caption.weight(.semibold))
            .foregroundStyle(FlowingPalette.muted)
            .textCase(.uppercase)

          Spacer(minLength: 8)

          Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(FlowingPalette.faint)
            .rotationEffect(.degrees(settings.showsWorkflowsInStatusMenu ? 180 : 0))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Workflow controls")
      .accessibilityValue(settings.showsWorkflowsInStatusMenu ? "Expanded" : "Collapsed")

      FlowingDisclosureContent(isExpanded: settings.showsWorkflowsInStatusMenu) {
        FlowingCard(
          spacing: 0,
          contentInsets: .init(top: 4, leading: 8, bottom: 4, trailing: 8)
        ) {
          ForEach(Array(runtime.workflowLibrary.workflows.enumerated()), id: \.element.id) {
            index, workflow in
            if index > 0 {
              Divider()
                .overlay(FlowingPalette.hairline)
            }
            workflowRow(workflow)
          }
        }
      }
    }
    .animation(
      reduceMotion ? nil : .easeOut(duration: FlowingMotion.expand),
      value: settings.showsWorkflowsInStatusMenu
    )
  }

  private var applicationsSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text("Applications")
          .font(.caption.weight(.semibold))
          .foregroundStyle(FlowingPalette.muted)
          .textCase(.uppercase)

        Spacer(minLength: 8)

        FlowingPopover(
          isPresented: $isApplicationPickerPresented,
          accessibilityLabel: "Add application control",
          arrowEdge: .top,
          minimumWidth: 300,
          maximumWidth: 340,
          contentInsets: EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        ) {
          Image(systemName: "plus")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(FlowingPalette.muted)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        } content: {
          InstalledApplicationSearchPicker(
            items: availableCatalogItems,
            selection: applicationPickerSelection,
            iconResolver: runtime.iconResolver
          )
        }
        .buttonStyle(.plain)
      }

      FlowingCard(contentInsets: EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)) {
        FlowingDisclosure(
          isExpanded: $isApplicationsExpanded,
          contentInsets: EdgeInsets(top: 7, leading: 4, bottom: 7, trailing: 4)
        ) {
          HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2")
              .foregroundStyle(FlowingPalette.muted)
            Text(applicationSectionTitle)
          }
        } content: {
          if runtime.managedApplicationStore.applications.isEmpty {
            Text(
              "Add an application to control its mute state and volume without building a workflow."
            )
            .font(.caption)
            .foregroundStyle(FlowingPalette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
          } else {
            if RilliyaStatusMenuLayout.usesScrollableApplicationList(
              for: runtime.managedApplicationStore.applications.count
            ) {
              ScrollView {
                managedApplicationRows
              }
              .scrollIndicators(.automatic)
              .frame(height: RilliyaStatusMenuLayout.maximumApplicationListHeight)
            } else {
              managedApplicationRows
            }
          }
        }
      }
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text("Rilliya")
          .font(.headline)
          .foregroundStyle(FlowingPalette.ink)
        Text(runningWorkflowDescription)
          .font(.caption)
          .foregroundStyle(FlowingPalette.muted)
      }

      Spacer(minLength: 8)

      FlowingIconButton("Open Rilliya", systemImage: "arrow.up.forward.app") {
        openWindow(id: "workspace")
        NSApp.activate(ignoringOtherApps: true)
      }
    }
  }

  private func workflowRow(_ workflow: RoutingWorkflowModel) -> some View {
    HStack(spacing: 9) {
      Circle()
        .fill(workflow.isRunning ? Color(nsColor: .systemGreen) : FlowingPalette.hairline)
        .frame(width: 7, height: 7)
        .accessibilityHidden(true)

      Text(workflow.name)
        .font(.callout.weight(.medium))
        .foregroundStyle(FlowingPalette.ink)
        .lineLimit(1)

      Spacer(minLength: 8)

      FlowingIconButton(
        workflow.isRunning ? "Pause \(workflow.name)" : "Run \(workflow.name)",
        systemImage: workflow.isRunning ? "pause.fill" : "play.fill",
        emphasis: .quiet,
        isSelected: workflow.isRunning
      ) {
        runtime.setWorkflowRunning(!workflow.isRunning, id: workflow.id)
      }
    }
    .frame(minHeight: 38)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(workflow.name)
    .accessibilityValue(workflow.isRunning ? "Running" : "Paused")
  }

  private func managedApplicationRow(_ application: RilliyaManagedApplication) -> some View {
    let item = runtime.installedItem(for: application)
    let isManagedByWorkflow = runtime.isManagedByWorkflow(application)
    return VStack(spacing: 7) {
      HStack(spacing: 9) {
        applicationIcon(item)

        VStack(alignment: .leading, spacing: 1) {
          Text(application.displayName)
            .font(.callout.weight(.medium))
            .foregroundStyle(FlowingPalette.ink)
            .lineLimit(1)
          Text(applicationStatus(application, isManagedByWorkflow: isManagedByWorkflow))
            .font(.caption)
            .foregroundStyle(FlowingPalette.muted)
            .lineLimit(1)
        }

        Spacer(minLength: 6)

        FlowingIconButton(
          application.isMuted
            ? "Unmute \(application.displayName)" : "Mute \(application.displayName)",
          systemImage: application.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
          emphasis: .quiet,
          isSelected: application.isMuted
        ) {
          runtime.managedApplicationStore.setMuted(!application.isMuted, id: application.id)
        }
        .disabled(isManagedByWorkflow)

        FlowingIconButton(
          "Remove \(application.displayName)",
          systemImage: "xmark",
          emphasis: .quiet
        ) {
          runtime.managedApplicationStore.remove(id: application.id)
        }
      }

      HStack(spacing: 9) {
        FlowingSlider(
          "\(application.displayName) volume",
          value: Binding(
            get: { application.volume },
            set: { runtime.managedApplicationStore.setVolume($0, id: application.id) }
          ),
          in: 0...RilliyaManagedApplication.maximumVolume,
          step: 0.01,
          formatValue: { "\(Int(($0 * 100).rounded()))%" }
        )
        .disabled(isManagedByWorkflow)

        Text("\(application.volumePercentage)%")
          .font(.system(.caption, design: .monospaced).weight(.medium))
          .foregroundStyle(FlowingPalette.muted)
          .frame(width: 42, alignment: .trailing)
      }
    }
    .padding(.vertical, 5)
  }

  private var managedApplicationRows: some View {
    VStack(spacing: 0) {
      ForEach(
        Array(runtime.managedApplicationStore.applications.enumerated()),
        id: \.element.id
      ) { index, application in
        if index > 0 {
          Divider()
            .overlay(FlowingPalette.hairline)
        }
        managedApplicationRow(application)
      }
    }
  }

  @ViewBuilder
  private func applicationIcon(_ item: InstalledApplicationCatalogItem?) -> some View {
    if let item {
      DeferredInstalledApplicationIcon(
        application: item.application,
        iconResolver: runtime.iconResolver,
        size: 28,
        cornerRadius: 7
      )
    } else {
      Image(systemName: "app.dashed")
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(FlowingPalette.faint)
        .frame(width: 28, height: 28)
        .background(FlowingPalette.field, in: RoundedRectangle(cornerRadius: 7))
    }
  }

  private func applicationStatus(
    _ application: RilliyaManagedApplication,
    isManagedByWorkflow: Bool
  ) -> String {
    if isManagedByWorkflow { return "Controlled by a workflow" }
    guard runtime.installedItem(for: application)?.isRunning == true else { return "Not running" }
    return runtime.isProducingAudio(application) ? "Playing audio" : "Ready"
  }

  private var applicationPickerSelection: Binding<String> {
    Binding(
      get: { "" },
      set: { selection in
        guard !selection.isEmpty,
          let item = availableCatalogItems.first(where: {
            $0.application.bundleURL.absoluteString == selection
          })
        else { return }
        _ = runtime.managedApplicationStore.add(item.application)
        isApplicationPickerPresented = false
      }
    )
  }

  private var availableCatalogItems: [InstalledApplicationCatalogItem] {
    let managedURLs = Set(
      runtime.managedApplicationStore.applications.map {
        canonicalApplicationURL($0.applicationURL)
      }
    )
    return (runtime.applicationCatalog.state.snapshot?.items ?? []).filter {
      !managedURLs.contains(canonicalApplicationURL($0.application.bundleURL))
    }
  }

  private var applicationSectionTitle: String {
    let count = runtime.managedApplicationStore.applications.count
    return count == 1 ? "1 managed application" : "\(count) managed applications"
  }

  private var statusMenuSurfaces: FlowingSurfaces {
    FlowingSurfaces(
      canvas: FlowingPalette.canvas,
      card: FlowingPalette.control.opacity(0.78),
      control: FlowingPalette.control.opacity(0.78),
      field: FlowingPalette.field.opacity(0.72)
    )
  }

  private var runningWorkflowDescription: String {
    let count = runtime.workflowLibrary.workflows.count(where: \.isRunning)
    return switch count {
    case 0: "All workflows paused"
    case 1: "1 workflow running"
    default: "\(count) workflows running"
    }
  }
}
