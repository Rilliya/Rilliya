import AppKit
import FlowingDayControls
import FlowingDayPreferences
import RilliyaVirtualAudio
import SwiftUI

struct RilliyaVirtualAudioPreferencesPane: View {
  @Bindable var controller: RilliyaVirtualAudioController

  var body: some View {
    PreferencesPaneStack {
      driverSection

      if controller.availability == .available {
        endpointSection
      }
    }
    .task {
      await controller.refresh()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    {
      _ in
      Task {
        await controller.refresh()
      }
    }
  }

  private var driverSection: some View {
    PreferencesSection(
      "Virtual Audio Driver",
      footer: "Install once to add Rilliya virtual devices to macOS. A restart is required."
    ) {
      switch controller.availability {
      case .available:
        PreferencesValueRow(
          symbol: "checkmark.seal",
          title: "Driver",
          value: "Installed"
        )
      case .notInstalled:
        PreferencesRow(
          symbol: "externaldrive.badge.plus",
          title: "Driver not installed",
          caption: installerCaption
        ) {
          Button("Install") {
            controller.openInstaller()
          }
          .buttonStyle(FlowingSoftButtonStyle())
          .disabled(!controller.isInstallerBundled || controller.isWorking)
        }
      case nil:
        PreferencesEmptyRow("Checking the virtual audio driver…", symbol: "waveform")
      }

      if let issue = controller.issue {
        PreferencesRowSeparator(leadingEdge: .iconText)
        PreferencesEmptyRow(issue, symbol: "exclamationmark.triangle")
      }
    }
  }

  private var endpointSection: some View {
    PreferencesSection(
      "Shared Virtual Devices",
      footer: "Devices can be shared across workflows. Pause active workflows before editing one."
    ) {
      RilliyaVirtualAudioEndpointCreator(controller: controller)

      if controller.catalog.endpoints.isEmpty {
        PreferencesRowSeparator(leadingEdge: .iconText)
        PreferencesEmptyRow(
          "No virtual devices yet. Create an input or output to get started.",
          symbol: "waveform.badge.plus"
        )
      } else {
        ForEach(controller.catalog.endpoints) { endpoint in
          PreferencesRowSeparator(leadingEdge: .iconText)
          RilliyaVirtualAudioEndpointEditor(
            endpoint: endpoint,
            controller: controller
          )
          .id(endpoint.configuration)
        }
      }
    }
  }

  private var installerCaption: String {
    if controller.isInstallerBundled {
      return "Open Rilliya's signed installer to make virtual devices available to macOS."
    }
    return "This development build does not include the signed driver installer."
  }
}

private struct RilliyaVirtualAudioEndpointCreator: View {
  let controller: RilliyaVirtualAudioController

  @State private var isExpanded = false
  @State private var name = "Virtual Input"
  @State private var direction = VirtualAudioEndpointDirection.input
  @State private var sampleRate = 48_000.0
  @State private var channelCount = 2

  var body: some View {
    VStack(spacing: 0) {
      PreferencesExpandableRow(
        symbol: "plus.circle",
        title: "Create a virtual device",
        caption: "Add a shared virtual input or output.",
        isExpanded: $isExpanded
      )
      PreferencesDependentRows(isVisible: isExpanded) {
        editorRows
      }
    }
  }

  @ViewBuilder
  private var editorRows: some View {
    RilliyaVirtualAudioNameRow(name: $name, validation: nameValidation)
    PreferencesRowSeparator(leadingEdge: .content)
    RilliyaVirtualAudioDirectionRow(direction: $direction)
    PreferencesRowSeparator(leadingEdge: .content)
    RilliyaVirtualAudioSampleRateRow(sampleRate: $sampleRate)
    PreferencesRowSeparator(leadingEdge: .content)
    RilliyaVirtualAudioChannelCountRow(channelCount: $channelCount)
    PreferencesRowSeparator(leadingEdge: .content)
    PreferencesRow(
      title: "Create device",
      caption: "Available to Core Audio immediately."
    ) {
      Button("Create") {
        guard let configuration else { return }
        Task {
          await controller.create(configuration)
          guard controller.issue == nil else { return }
          reset()
          isExpanded = false
        }
      }
      .buttonStyle(FlowingSoftButtonStyle())
      .disabled(configuration == nil || controller.isWorking)
    }
  }

  private var configuration: VirtualAudioEndpointConfiguration? {
    try? VirtualAudioEndpointConfiguration(
      name: name,
      direction: direction,
      format: VirtualAudioEndpointFormat(
        sampleRate: sampleRate,
        channelCount: channelCount
      )
    )
  }

  private var nameValidation: FlowingFieldValidation {
    RilliyaVirtualAudioFormValidation.name(name)
  }

  private func reset() {
    name = "Virtual Input"
    direction = .input
    sampleRate = 48_000
    channelCount = 2
  }
}

private struct RilliyaVirtualAudioEndpointEditor: View {
  let endpoint: VirtualAudioEndpoint
  let controller: RilliyaVirtualAudioController

  @State private var isExpanded = false
  @State private var isConfirmingRemoval = false
  @State private var name: String
  @State private var direction: VirtualAudioEndpointDirection
  @State private var sampleRate: Double
  @State private var channelCount: Int

  init(endpoint: VirtualAudioEndpoint, controller: RilliyaVirtualAudioController) {
    self.endpoint = endpoint
    self.controller = controller
    _name = State(initialValue: endpoint.configuration.name)
    _direction = State(initialValue: endpoint.configuration.direction)
    _sampleRate = State(initialValue: endpoint.configuration.format.sampleRate)
    _channelCount = State(initialValue: endpoint.configuration.format.channelCount)
  }

  var body: some View {
    VStack(spacing: 0) {
      PreferencesExpandableRow(
        symbol: direction.systemImage,
        title: endpoint.configuration.name,
        caption: endpoint.configuration.summary,
        isExpanded: $isExpanded
      )
      PreferencesDependentRows(isVisible: isExpanded) {
        RilliyaVirtualAudioNameRow(name: $name, validation: nameValidation)
        PreferencesRowSeparator(leadingEdge: .content)
        RilliyaVirtualAudioDirectionRow(direction: $direction)
        PreferencesRowSeparator(leadingEdge: .content)
        RilliyaVirtualAudioSampleRateRow(sampleRate: $sampleRate)
        PreferencesRowSeparator(leadingEdge: .content)
        RilliyaVirtualAudioChannelCountRow(channelCount: $channelCount)
        PreferencesRowSeparator(leadingEdge: .content)
        actionRow
      }
    }
    .flowingConfirmationDialog(
      "Remove “\(endpoint.configuration.name)” ?",
      message:
        "Workflows that reference this virtual device will keep their reference but cannot run until another device is selected.",
      isPresented: $isConfirmingRemoval,
      confirmationTitle: "Remove Device",
      kind: .destructive,
      confirmationIsDefault: false
    ) {
      Task {
        await controller.remove(id: endpoint.id)
      }
    }
  }

  private var actionRow: some View {
    PreferencesRow(
      title: "Device configuration",
      caption: "Active devices reject format changes."
    ) {
      HStack(spacing: 8) {
        Button("Remove", role: .destructive) {
          isConfirmingRemoval = true
        }
        .buttonStyle(FlowingSoftButtonStyle())

        Button("Save") {
          guard let configuration else { return }
          Task {
            await controller.update(id: endpoint.id, configuration: configuration)
          }
        }
        .buttonStyle(FlowingSoftButtonStyle())
        .disabled(!hasChanges || configuration == nil || controller.isWorking)
      }
    }
  }

  private var configuration: VirtualAudioEndpointConfiguration? {
    try? VirtualAudioEndpointConfiguration(
      name: name,
      direction: direction,
      format: VirtualAudioEndpointFormat(
        sampleRate: sampleRate,
        channelCount: channelCount
      )
    )
  }

  private var hasChanges: Bool {
    configuration != endpoint.configuration
  }

  private var nameValidation: FlowingFieldValidation {
    RilliyaVirtualAudioFormValidation.name(name)
  }
}

private struct RilliyaVirtualAudioNameRow: View {
  @Binding var name: String
  let validation: FlowingFieldValidation

  var body: some View {
    PreferencesRow(
      title: "Name",
      caption: "Shown in macOS audio device lists."
    ) {
      FlowingTextField(
        "Device name",
        text: $name,
        placeholder: "Virtual audio device",
        validation: validation
      )
      .frame(width: 230)
    }
  }
}

private struct RilliyaVirtualAudioDirectionRow: View {
  @Binding var direction: VirtualAudioEndpointDirection

  var body: some View {
    PreferencesRow(
      title: "Direction",
      caption: direction.explanation
    ) {
      FlowingSelect(
        label: "Direction",
        selection: $direction,
        options: VirtualAudioEndpointDirection.allCases.map {
          FlowingSelectOption($0, label: $0.title)
        },
        minimumWidth: 130
      )
    }
  }
}

private struct RilliyaVirtualAudioSampleRateRow: View {
  @Binding var sampleRate: Double

  var body: some View {
    PreferencesRow(
      title: "Sample rate",
      caption: "Set the native PCM sample rate."
    ) {
      FlowingSelect(
        label: "Sample rate",
        selection: $sampleRate,
        options: RilliyaVirtualAudioFormValidation.sampleRates.map {
          FlowingSelectOption($0, label: $0.sampleRateLabel)
        },
        minimumWidth: 120
      )
    }
  }
}

private struct RilliyaVirtualAudioChannelCountRow: View {
  @Binding var channelCount: Int

  var body: some View {
    PreferencesRow(
      title: "Channels",
      caption: "Expose 1–256 Float32 channels."
    ) {
      FlowingStepper(
        "Channel count",
        value: $channelCount,
        in: 1...256,
        step: 1
      ) { count in
        "\(count) ch"
      }
    }
  }
}

private enum RilliyaVirtualAudioFormValidation {
  static let sampleRates = [44_100.0, 48_000.0, 88_200.0, 96_000.0, 176_400.0, 192_000.0]

  static func name(_ name: String) -> FlowingFieldValidation {
    do {
      _ = try VirtualAudioEndpointConfiguration(name: name, direction: .input)
      return .none
    } catch {
      let message =
        (error as? any LocalizedError)?.errorDescription
        ?? "Enter a valid device name."
      return .error(message)
    }
  }
}

extension VirtualAudioEndpointDirection {
  fileprivate var title: String {
    switch self {
    case .input: "Virtual Input"
    case .output: "Virtual Output"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .input: "mic"
    case .output: "speaker.wave.2"
    }
  }

  fileprivate var explanation: String {
    switch self {
    case .input:
      "Other applications capture audio supplied by Rilliya."
    case .output:
      "Other applications play audio that Rilliya receives."
    }
  }
}

extension VirtualAudioEndpointConfiguration {
  fileprivate var summary: String {
    "\(direction.title) · \(format.channelCount) ch · \(format.sampleRate.sampleRateLabel)"
  }
}

extension Double {
  fileprivate var sampleRateLabel: String {
    let kilohertz = self / 1_000
    if kilohertz.rounded() == kilohertz {
      return "\(Int(kilohertz)) kHz"
    }
    return String(format: "%.1f kHz", kilohertz)
  }
}
