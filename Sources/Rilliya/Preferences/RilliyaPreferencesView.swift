import AppKit
import FlowingDayControls
import FlowingDayPreferences
import SwiftUI

private enum RilliyaPreferencesPage: Hashable {
  case general
  case canvas
  case customization
  case nodeDefaults(RilliyaNodeDefaultsCategory)
  case virtualAudio
  case networkAudio
  case about
}

private struct RilliyaPreferencesRoot: View {
  let settings: RilliyaSettings
  let virtualAudioController: RilliyaVirtualAudioController

  @State private var selection = RilliyaPreferencesPage.general

  var body: some View {
    PreferencesView(
      selection: $selection,
      configuration: PreferencesViewConfiguration(
        applicationName: "Rilliya",
        applicationIcon: NSApp.applicationIconImage,
        defaultAccent: .fern
      ),
      groups: [
        PreferencesPageGroup(
          id: "workspace",
          title: "Workspace",
          pages: [
            PreferencesPage(
              id: .general,
              title: "General",
              subtitle: "Appearance and startup",
              icon: .system("gearshape")
            ) {
              RilliyaGeneralPreferencesPane(settings: settings)
            },
            PreferencesPage(
              id: .canvas,
              title: "Canvas",
              subtitle: "Interaction and display",
              icon: .system("point.3.connected.trianglepath.dotted")
            ) {
              RilliyaCanvasPreferencesPane(settings: settings)
            },
            PreferencesPage(
              id: .customization,
              title: "Node Colors",
              icon: .system("paintpalette")
            ) {
              RilliyaCustomizationPreferencesPane(settings: settings)
            },
          ]
        ),
        PreferencesPageGroup(
          id: "audio",
          title: "Audio",
          pages: [
            PreferencesPage(
              id: .virtualAudio,
              title: "Virtual Devices",
              subtitle: "Shared Core Audio devices",
              icon: .system("waveform.badge.plus")
            ) {
              RilliyaVirtualAudioPreferencesPane(controller: virtualAudioController)
            },
            PreferencesPage(
              id: .networkAudio,
              title: "Network Audio",
              subtitle: "Key storage",
              icon: .system("network.badge.shield.half.filled")
            ) {
              RilliyaNetworkAudioPreferencesPane(settings: settings)
            },
          ]
        ),
        PreferencesPageGroup(
          id: "node-defaults",
          title: "Node Defaults",
          pages: [
            PreferencesPage(
              id: .nodeDefaults(.sources),
              title: "Sources",
              subtitle: "Inputs and generators",
              icon: .system("waveform.badge.plus")
            ) {
              RilliyaNodeDefaultsPreferencesPane(settings: settings, category: .sources)
            },
            PreferencesPage(
              id: .nodeDefaults(.destinations),
              title: "Destinations",
              subtitle: "Playback, files, and network",
              icon: .system("speaker.wave.2")
            ) {
              RilliyaNodeDefaultsPreferencesPane(settings: settings, category: .destinations)
            },
            PreferencesPage(
              id: .nodeDefaults(.routing),
              title: "Routing & Level",
              subtitle: "Mixing and channel layout",
              icon: .system("point.3.connected.trianglepath.dotted")
            ) {
              RilliyaNodeDefaultsPreferencesPane(settings: settings, category: .routing)
            },
            PreferencesPage(
              id: .nodeDefaults(.measurement),
              title: "Measurement",
              subtitle: "Meters and visualizers",
              icon: .system("waveform")
            ) {
              RilliyaNodeDefaultsPreferencesPane(settings: settings, category: .measurement)
            },
            PreferencesPage(
              id: .nodeDefaults(.processing),
              title: "Dynamics & Effects",
              subtitle: "Delay and dynamics",
              icon: .system("slider.horizontal.3")
            ) {
              RilliyaNodeDefaultsPreferencesPane(settings: settings, category: .processing)
            },
          ]
        ),
        PreferencesPageGroup(
          id: "application",
          pages: [
            PreferencesPage(
              id: .about,
              title: "About",
              subtitle: "Version and credits",
              icon: .system("info.circle"),
              headerIcon: .application
            ) {
              RilliyaAboutPreferencesPane(versionText: Self.versionText)
            }
          ]
        ),
      ]
    )
    .preferredColorScheme(settings.appearance.preferredColorScheme)
  }

  private static var versionText: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "0.3.1"
    return "Version \(version)"
  }
}

private struct RilliyaNodeDefaultsPreferencesPane: View {
  @Bindable var settings: RilliyaSettings
  let category: RilliyaNodeDefaultsCategory
  @State private var expandedKind: RoutingNodeKind?
  @State private var searchText = ""

  var body: some View {
    PreferencesPaneStack {
      PreferencesSection(
        category.title,
        footer: "Enabled values apply to new nodes only."
      ) {
        RilliyaNodeDefaultsRows(
          settings: settings,
          expandedKind: $expandedKind,
          kinds: category.kinds(matching: searchText)
        )
      }
    }
    .overlay(alignment: .topTrailing) {
      FlowingTextField(
        "Search \(category.title.lowercased()) defaults",
        text: $searchText,
        placeholder: "Search \(category.title.lowercased())",
        systemImage: "magnifyingglass"
      )
      .frame(width: 210)
      .id(category)
      .offset(y: -62)
    }
  }
}

struct RilliyaNetworkSendDefaultsRow: View {
  @Bindable var settings: RilliyaSettings
  @Binding var isExpanded: Bool

  var body: some View {
    VStack(spacing: 0) {
      PreferencesExpandableRow(
        symbol: RoutingNodeKind.networkSend.systemImage,
        title: RoutingNodeKind.networkSend.title,
        caption: enabledDescription,
        isExpanded: $isExpanded
      )
      PreferencesDependentRows(isVisible: isExpanded, showsSeparator: false) {
        parameterToggle(
          title: "Wire format",
          caption: "Audio encoding for new send nodes.",
          isOn: wireEncodingEnabled
        )
        PreferencesDependentRows(isVisible: wireEncodingEnabled.wrappedValue, showsSeparator: true)
        {
          PreferencesPopupRow(
            symbol: "waveform",
            title: "Format",
            minimumControlWidth: 170,
            selection: wireEncoding,
            options: RoutingNetworkWireEncoding.allCases.map {
              FlowingSelectOption($0, label: $0.displayName)
            }
          )
        }
        PreferencesRowSeparator(leadingEdge: .iconText)
        parameterToggle(
          title: "Bit rate",
          caption: "The target used by compressed formats.",
          isOn: bitRateEnabled
        )
        PreferencesDependentRows(isVisible: bitRateEnabled.wrappedValue, showsSeparator: true) {
          PreferencesPopupRow(
            symbol: "gauge.with.dots.needle.67percent",
            title: "Rate",
            caption: "Lower rates save payload bytes, but packet framing remains.",
            minimumControlWidth: 150,
            selection: bitRate,
            options: RoutingNetworkWireFormat.bitRates.map {
              FlowingSelectOption($0, label: "\($0 / 1_000) kbit/s")
            }
          )
        }
        PreferencesRowSeparator(leadingEdge: .iconText)
        parameterToggle(
          title: "Sample rate",
          isOn: sampleRateEnabled
        )
        PreferencesDependentRows(isVisible: sampleRateEnabled.wrappedValue, showsSeparator: true) {
          PreferencesPopupRow(
            symbol: "waveform.path.ecg",
            title: "Rate",
            minimumControlWidth: 150,
            selection: sampleRate,
            options: [44_100.0, 48_000.0, 96_000.0].map {
              FlowingSelectOption($0, label: Self.sampleRateLabel($0))
            }
          )
        }
        PreferencesRowSeparator(leadingEdge: .iconText)
        parameterToggle(
          title: "Channels",
          isOn: channelCountEnabled
        )
        PreferencesDependentRows(isVisible: channelCountEnabled.wrappedValue, showsSeparator: true)
        {
          PreferencesPopupRow(
            symbol: "speaker.wave.2",
            title: "Channels",
            minimumControlWidth: 150,
            selection: channelCount,
            options: [1, 2, 4, 6, 8].map {
              FlowingSelectOption($0, label: "\($0) ch")
            }
          )
        }
      }
    }
  }

  private func parameterToggle(
    title: String,
    caption: String? = nil,
    isOn: Binding<Bool>
  ) -> some View {
    PreferencesSwitchRow(
      symbol: "arrow.turn.down.right",
      title: title,
      caption: caption,
      isOn: isOn
    )
  }

  private var enabledDescription: String {
    let values = settings.networkSendParameterDefaults
    let count = [
      values.wireEncoding != nil,
      values.bitRate != nil,
      values.sampleRate != nil,
      values.channelCount != nil,
    ].filter { $0 }.count
    return count == 0 ? "Use Rilliya defaults" : "\(count) custom default\(count == 1 ? "" : "s")"
  }

  private var wireEncodingEnabled: Binding<Bool> {
    enabled(\.wireEncoding, fallback: RoutingNetworkWireFormat.initial.encoding)
  }

  private var bitRateEnabled: Binding<Bool> {
    enabled(\.bitRate, fallback: RoutingNetworkWireFormat.initial.bitRate)
  }

  private var sampleRateEnabled: Binding<Bool> {
    enabled(\.sampleRate, fallback: RoutingNetworkSendConfiguration.initial.sampleRate)
  }

  private var channelCountEnabled: Binding<Bool> {
    enabled(\.channelCount, fallback: RoutingNetworkSendConfiguration.initial.channelCount)
  }

  private var wireEncoding: Binding<RoutingNetworkWireEncoding> {
    value(\.wireEncoding, fallback: RoutingNetworkWireFormat.initial.encoding)
  }

  private var bitRate: Binding<Int> {
    value(\.bitRate, fallback: RoutingNetworkWireFormat.initial.bitRate)
  }

  private var sampleRate: Binding<Double> {
    value(\.sampleRate, fallback: RoutingNetworkSendConfiguration.initial.sampleRate)
  }

  private var channelCount: Binding<Int> {
    value(\.channelCount, fallback: RoutingNetworkSendConfiguration.initial.channelCount)
  }

  private func enabled<Value>(
    _ keyPath: WritableKeyPath<RoutingNetworkSendParameterDefaults, Value?>,
    fallback: Value
  ) -> Binding<Bool> {
    Binding(
      get: { settings.networkSendParameterDefaults[keyPath: keyPath] != nil },
      set: { isEnabled in
        edit { $0[keyPath: keyPath] = isEnabled ? fallback : nil }
      }
    )
  }

  private func value<Value>(
    _ keyPath: WritableKeyPath<RoutingNetworkSendParameterDefaults, Value?>,
    fallback: Value
  ) -> Binding<Value> {
    Binding(
      get: { settings.networkSendParameterDefaults[keyPath: keyPath] ?? fallback },
      set: { value in edit { $0[keyPath: keyPath] = value } }
    )
  }

  private func edit(_ change: (inout RoutingNetworkSendParameterDefaults) -> Void) {
    var updated = settings.networkSendParameterDefaults
    change(&updated)
    settings.setNetworkSendParameterDefaults(updated)
  }

  private static func sampleRateLabel(_ sampleRate: Double) -> String {
    sampleRate.truncatingRemainder(dividingBy: 1_000) == 0
      ? "\(Int(sampleRate / 1_000)) kHz"
      : String(format: "%.1f kHz", sampleRate / 1_000)
  }
}

private struct RilliyaGeneralPreferencesPane: View {
  @Bindable var settings: RilliyaSettings
  @State private var launchAtLoginController = RilliyaLaunchAtLoginController()

  var body: some View {
    PreferencesPaneStack {
      PreferencesSection("Appearance") {
        PreferencesPopupRow(
          symbol: "circle.lefthalf.filled",
          title: "Theme",
          minimumControlWidth: 120,
          selection: Binding(
            get: { settings.appearance },
            set: { appearance in
              settings.appearance = appearance
              appearance.applyToApplication()
            }
          ),
          options: [
            FlowingSelectOption(.system, label: "System"),
            FlowingSelectOption(.light, label: "Light"),
            FlowingSelectOption(.dark, label: "Dark"),
          ]
        )

      }

      PreferencesSection(
        "Availability",
        footer: "Keep either the Dock or menu bar enabled."
      ) {
        PreferencesSwitchRow(
          symbol: "dock.rectangle",
          title: "Show in Dock",
          isOn: Binding(
            get: { settings.showsInDock },
            set: { isVisible in
              settings.setShowsInDock(isVisible)
              RilliyaApplicationPresentation.apply(settings)
            }
          )
        )

        PreferencesRowSeparator(leadingEdge: .iconText)
        PreferencesSwitchRow(
          symbol: "menubar.rectangle",
          title: "Show in menu bar",
          isOn: Binding(
            get: { settings.showsInStatusBar },
            set: { isVisible in
              settings.setShowsInStatusBar(isVisible)
            }
          )
        )

        PreferencesRowSeparator(leadingEdge: .iconText)
        PreferencesSwitchRow(
          symbol: "power",
          title: "Launch at login",
          isOn: Binding(
            get: { launchAtLoginController.isEnabled },
            set: { isEnabled in
              launchAtLoginController.setEnabled(isEnabled)
            }
          )
        )

        if launchAtLoginController.status == .requiresApproval {
          PreferencesRowSeparator(leadingEdge: .iconText)
          PreferencesButtonRow(
            symbol: "gearshape",
            title: "Approval required",
            caption: "Allow Rilliya in Login Items to finish enabling this setting.",
            buttonTitle: "Open Settings",
            action: launchAtLoginController.openSystemSettings
          )
        }

        if let issue = launchAtLoginController.issue {
          PreferencesRowSeparator(leadingEdge: .iconText)
          PreferencesEmptyRow(issue, symbol: "exclamationmark.triangle")
        }
      }

    }
    .onAppear {
      launchAtLoginController.refresh()
    }
  }
}

private struct RilliyaCanvasPreferencesPane: View {
  @Bindable var settings: RilliyaSettings

  var body: some View {
    PreferencesPaneStack {
      PreferencesSection("Interaction") {
        PreferencesSwitchRow(
          symbol: "cursorarrow.click",
          title: "Click to add nodes",
          isOn: $settings.addsNodesOnPaletteClick
        )
      }

      PreferencesSection("Display") {
        PreferencesSwitchRow(
          symbol: "map",
          title: "Show overview by default",
          isOn: $settings.showsMiniMapByDefault
        )

        PreferencesRowSeparator(leadingEdge: .iconText)
        PreferencesSegmentedRow(
          symbol: "cable.connector.horizontal",
          title: "Connection labels",
          controlWidth: 240,
          selection: $settings.connectionInformationLevel,
          options: [
            FlowingSegmentOption(.hidden, label: "Off"),
            FlowingSegmentOption(.channels, label: "Channels"),
            FlowingSegmentOption(.format, label: "Format"),
          ]
        )

        PreferencesRowSeparator(leadingEdge: .iconText)
        PreferencesSwitchRow(
          symbol: "xmark.circle",
          title: "Mark disabled ports",
          isOn: $settings.showsDisabledPortCrosses
        )

        PreferencesRowSeparator(leadingEdge: .iconText)
        RilliyaWaveformRatePreferenceRows(settings: settings)
      }

      PreferencesSection(
        "Routing",
        footer: "Native follows the selected output device."
      ) {
        PreferencesPopupRow(
          symbol: "slider.horizontal.2.square",
          title: "Default separated layout",
          minimumControlWidth: 150,
          selection: $settings.defaultSeparateChannelLayout,
          options: [
            FlowingSelectOption(.native, label: "Native"),
            FlowingSelectOption(.stereo, label: "Stereo · 2 ch"),
            FlowingSelectOption(.quadraphonic, label: "Quad · 4 ch"),
            FlowingSelectOption(.surround51, label: "5.1 · 6 ch"),
            FlowingSelectOption(.surround71, label: "7.1 · 8 ch"),
          ]
        )
      }
    }
  }
}

private struct RilliyaNetworkAudioPreferencesPane: View {
  @Bindable var settings: RilliyaSettings

  var body: some View {
    PreferencesPaneStack {
      PreferencesSection(
        "Keys",
        footer:
          "Keychain keeps keys out of workflow files. Development builds may request access after rebuilding."
      ) {
        PreferencesSegmentedRow(
          symbol: "key",
          title: "Store new keys in",
          controlWidth: 240,
          selection: $settings.networkAudioKeySourceID,
          options: RoutingNetworkAudioKeySourceRegistry.shared.all
            .filter(\.acceptsProvidedKeys)
            .map { FlowingSegmentOption($0.id, label: $0.displayName) }
        )
      }
    }
  }
}

private struct RilliyaCustomizationPreferencesPane: View {
  @Bindable var settings: RilliyaSettings

  var body: some View {
    PreferencesPaneStack {

      PreferencesSection(
        "Defaults",
        footer: "Workflow-specific colors override these defaults."
      ) {
        ForEach(Array(RoutingNodeKind.allCases.enumerated()), id: \.element) { index, kind in
          if index > 0 {
            PreferencesRowSeparator(leadingEdge: .iconText)
          }
          RilliyaNodeColorPreferenceRow(
            kind: kind,
            selection: settings.nodeAccentOverride(for: kind),
            setSelection: { settings.setNodeAccentOverride($0, for: kind) }
          )
        }
      }
    }
  }
}

private struct RilliyaAboutPreferencesPane: View {
  @Environment(\.flowingTypography) private var typography
  let versionText: String

  var body: some View {
    PreferencesPaneStack {
      VStack(alignment: .leading, spacing: 4) {
        Text("Rilliya")
          .font(typography.contentTitle.font)
          .foregroundStyle(FlowingPalette.ink)
        Text(versionText)
          .font(typography.rowCaption.font)
          .foregroundStyle(FlowingPalette.faint)
        Text("A gentle, modular audio routing workspace for macOS.")
          .font(typography.body.font)
          .foregroundStyle(FlowingPalette.muted)
          .padding(.top, 4)
      }

      PreferencesSection("Acknowledgements") {
        RilliyaAcknowledgementLinkRow(
          icon: Self.rilliyaKitIcon,
          title: "RilliyaKit",
          caption: "The open-source capture, DSP, playback, graph, and realtime audio foundation.",
          buttonTitle: "GitHub",
          destination: Self.rilliyaKitURL,
          help: "Open RilliyaKit on GitHub"
        )
        PreferencesRowSeparator(leadingEdge: .iconText)
        RilliyaAcknowledgementLinkRow(
          icon: Self.flowingDayIcon,
          title: "FlowingDayUI",
          caption: "The open-source SwiftUI component library used throughout Rilliya.",
          buttonTitle: "GitHub",
          destination: Self.flowingDayURL,
          help: "Open FlowingDayUI on GitHub"
        )
      }
    }
  }

  private static let rilliyaKitIcon = acknowledgementIcon(named: "RilliyaKitMark")
  private static let flowingDayIcon = acknowledgementIcon(named: "FlowingDayUIMark")

  private static let rilliyaKitURL = githubURL(owner: "Rilliya", repository: "RilliyaKit")
  private static let flowingDayURL = githubURL(
    owner: "cocoa-xu",
    repository: "flowing-day-ui"
  )

  private static func githubURL(owner: String, repository: String) -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "github.com"
    components.path = "/\(owner)/\(repository)"
    guard let url = components.url else {
      preconditionFailure("The static GitHub URL must be valid.")
    }
    return url
  }

  private static func acknowledgementIcon(named name: String) -> NSImage {
    guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
      let image = NSImage(contentsOf: url)
    else {
      return NSImage(size: NSSize(width: 32, height: 32))
    }
    return image
  }
}

private struct RilliyaAcknowledgementLinkRow: View {
  let icon: NSImage
  let title: String
  let caption: String
  let buttonTitle: String
  let destination: URL
  let help: String

  var body: some View {
    PreferencesRow(icon: .image(icon), title: title, caption: caption) {
      Link(buttonTitle, destination: destination)
        .buttonStyle(FlowingSoftButtonStyle())
        .help(help)
    }
  }
}

private struct RilliyaNodeColorPreferenceRow: View {
  let kind: RoutingNodeKind
  let selection: RoutingAccentID?
  let setSelection: (RoutingAccentID?) -> Void

  private let iconTextLeadingOffset: CGFloat = 34
  @State private var isExpanded = false

  var body: some View {
    VStack(spacing: 0) {
      PreferencesExpandableRow(
        symbol: kind.systemImage,
        title: kind.title,
        caption: currentColorDescription,
        isExpanded: $isExpanded
      )
      PreferencesDependentRows(isVisible: isExpanded, showsSeparator: false) {
        RoutingAccentGrid(
          selection: selection,
          inheritedAccentID: kind.builtInAccentID,
          inheritedLabel: "Use Rilliya Default",
          showsAccentNames: true,
          setSelection: setSelection
        )
        .padding(.horizontal, 14)
        .padding(.leading, iconTextLeadingOffset)
        .padding(.vertical, 8)
      }
    }
  }

  private var currentColorDescription: String {
    if let selection {
      return "Custom · \(selection.displayName)"
    }
    return "Rilliya default · \(kind.builtInAccentID.displayName)"
  }
}

@MainActor
final class RilliyaPreferencesWindowController {
  static let shared = RilliyaPreferencesWindowController()

  private lazy var presenter = PreferencesWindowPresenter(
    configuration: PreferencesWindowConfiguration(
      size: CGSize(width: 860, height: 600),
      minimumSize: CGSize(width: 760, height: 520)
    ),
    rootView: RilliyaPreferencesRoot(
      settings: RilliyaSettings.shared,
      virtualAudioController: RilliyaVirtualAudioController.shared
    )
  )

  private init() {}

  func showPreferences() {
    presenter.show()
  }
}

private struct RilliyaWaveformRatePreferenceRows: View {
  @Bindable var settings: RilliyaSettings
  @State private var typed = ""

  var body: some View {
    PreferencesPopupRow(
      symbol: "waveform.path",
      title: "Waveform refresh rate",
      minimumControlWidth: 150,
      selection: presetSelection,
      options: RilliyaSettings.waveformUpdatePresets.map {
        FlowingSelectOption(.preset($0), label: "\($0) per second")
      } + [FlowingSelectOption(.custom, label: "Custom…")]
    )

    PreferencesDependentRows(isVisible: isCustom, showsSeparator: true) {
      PreferencesRow(
        icon: .system("number"),
        title: "Custom rate",
        caption: "Enter a rate of 1 or more per second."
      ) {
        TextField("", text: $typed)
          .textFieldStyle(.roundedBorder)
          .frame(width: 90)
          .multilineTextAlignment(.trailing)
          .onSubmit(applyTyped)
          .onChange(of: typed) { _, _ in applyTyped() }
      }
    }
    .onAppear { typed = String(settings.waveformUpdatesPerSecond) }
  }

  private var isCustom: Bool {
    !RilliyaSettings.waveformUpdatePresets.contains(settings.waveformUpdatesPerSecond)
  }

  private var presetSelection: Binding<WaveformRateChoice> {
    Binding(
      get: { isCustom ? .custom : .preset(settings.waveformUpdatesPerSecond) },
      set: { choice in
        switch choice {
        case .preset(let rate):
          settings.waveformUpdatesPerSecond = rate
          typed = String(rate)
        case .custom:
          // Leaves the current rate in place until one is typed, so choosing "Custom" alone
          // never changes what is happening.
          typed = String(settings.waveformUpdatesPerSecond)
        }
      }
    )
  }

  private func applyTyped() {
    guard let rate = Int(typed.trimmingCharacters(in: .whitespaces)), rate >= 1 else { return }
    settings.waveformUpdatesPerSecond = rate
  }
}

/// Which rate a person picked, and whether they picked it from the list.
private enum WaveformRateChoice: Hashable {
  case preset(Int)
  case custom
}
