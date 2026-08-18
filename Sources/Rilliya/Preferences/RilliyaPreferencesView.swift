import AppKit
import FlowingDayControls
import FlowingDayPreferences
import SwiftUI

private enum RilliyaPreferencesPage: Hashable {
  case general
  case canvas
  case customization
  case nodeDefaults
  case virtualAudio
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
              id: .nodeDefaults,
              title: "Node Defaults",
              subtitle: "Starting values for new audio nodes",
              icon: .system("slider.horizontal.3")
            ) {
              RilliyaNodeDefaultsPreferencesPane(settings: settings)
            },
            PreferencesPage(
              id: .general,
              title: "General",
              subtitle: "Appearance and application behavior",
              icon: .system("gearshape")
            ) {
              RilliyaGeneralPreferencesPane(settings: settings)
            },
            PreferencesPage(
              id: .canvas,
              title: "Canvas",
              subtitle: "Overview, insertion, and connections",
              icon: .system("point.3.connected.trianglepath.dotted")
            ) {
              RilliyaCanvasPreferencesPane(settings: settings)
            },
            PreferencesPage(
              id: .customization,
              title: "Customization",
              subtitle: "Default colors for every audio node",
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
              subtitle: "Install the driver and manage shared endpoints",
              icon: .system("waveform.badge.plus")
            ) {
              RilliyaVirtualAudioPreferencesPane(controller: virtualAudioController)
            }
          ]
        ),
        PreferencesPageGroup(
          id: "application",
          pages: [
            PreferencesPage(
              id: .about,
              title: "About",
              subtitle: "Version, requirements, and acknowledgements",
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
    let version = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    return "Version \(version)"
  }
}

private struct RilliyaNodeDefaultsPreferencesPane: View {
  @Bindable var settings: RilliyaSettings
  @State private var expandedKind: RoutingNodeKind?

  var body: some View {
    PreferencesPaneStack {
      PreferencesSection(
        "Node Parameters",
        footer:
          "Only enabled values replace Rilliya's starting values. Existing nodes are never changed."
      ) {
        RilliyaNetworkSendDefaultsRow(
          settings: settings,
          isExpanded: Binding(
            get: { expandedKind == .networkSend },
            set: { expandedKind = $0 ? .networkSend : nil }
          )
        )
        RilliyaAdditionalNodeDefaultsRows(
          settings: settings,
          expandedKind: $expandedKind
        )
      }
    }
  }
}

private struct RilliyaNetworkSendDefaultsRow: View {
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
          caption: "Choose how new send nodes encode audio.",
          isOn: wireEncodingEnabled
        )
        PreferencesDependentRows(isVisible: wireEncodingEnabled.wrappedValue, showsSeparator: true)
        {
          PreferencesPopupRow(
            symbol: "waveform",
            title: "Format",
            caption: "The representation placed on the network.",
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
          caption: "The rate requested by a new send node.",
          isOn: sampleRateEnabled
        )
        PreferencesDependentRows(isVisible: sampleRateEnabled.wrappedValue, showsSeparator: true) {
          PreferencesPopupRow(
            symbol: "waveform.path.ecg",
            title: "Rate",
            caption: "Choose a common audio sample rate.",
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
          caption: "The channel count requested by a new send node.",
          isOn: channelCountEnabled
        )
        PreferencesDependentRows(isVisible: channelCountEnabled.wrappedValue, showsSeparator: true)
        {
          PreferencesPopupRow(
            symbol: "speaker.wave.2",
            title: "Channels",
            caption: "Choose the number of channels to send.",
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
    caption: String,
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
      PreferencesSection(
        "Application",
        footer:
          "Keep at least one of Dock or menu bar visibility enabled. macOS controls login-item approval in System Settings."
      ) {
        PreferencesPopupRow(
          symbol: "circle.lefthalf.filled",
          title: "Appearance",
          caption: "Follow macOS or keep Rilliya in a light or dark appearance.",
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

        PreferencesRowSeparator(leadingEdge: .iconText)
        PreferencesSwitchRow(
          symbol: "dock.rectangle",
          title: "Show in Dock",
          caption: "Keep Rilliya in the Dock and application switcher.",
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
          caption: "Keep quick workflow and application controls in the menu bar.",
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
          caption: "Open Rilliya after you sign in so launch-enabled workflows can resume.",
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
      PreferencesSection(
        "Canvas Overview",
        footer:
          "Workflows inherit this setting until the overview button on that canvas creates a workflow-specific override."
      ) {
        PreferencesSwitchRow(
          symbol: "map",
          title: "Show overview by default",
          caption: "Display the minimap when a workflow has nodes.",
          isOn: $settings.showsMiniMapByDefault
        )
      }

      PreferencesSection(
        "Network Audio Keys",
        footer:
          "The Keychain keeps the key out of the workflow file. It grants access per signed "
          + "build, so a development build asks once each time it is rebuilt."
      ) {
        PreferencesSegmentedRow(
          symbol: "key",
          title: "Store new keys in",
          caption: "Choose where a generated or pasted shared key is kept.",
          controlWidth: 240,
          selection: $settings.networkAudioKeySourceID,
          // Built from what is registered rather than written down, so a source added by someone
          // else appears here without this view knowing anything about it.
          options: RoutingNetworkAudioKeySourceRegistry.shared.all
            .filter(\.acceptsProvidedKeys)
            .map { FlowingSegmentOption($0.id, label: $0.displayName) }
        )
      }

      PreferencesSection(
        "Node Palette",
        footer: "Dragging a node onto the canvas always remains available."
      ) {
        PreferencesSwitchRow(
          symbol: "cursorarrow.click",
          title: "Click to add nodes",
          caption: "Let a single click add a node near the visible workspace center.",
          isOn: $settings.addsNodesOnPaletteClick
        )
      }

      PreferencesSection(
        "Connection Information",
        footer:
          "Format details appear only after Rilliya has learned the source's live audio format."
      ) {
        PreferencesSegmentedRow(
          symbol: "cable.connector.horizontal",
          title: "Connection labels",
          caption: "Choose how much information appears directly on the canvas.",
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
          caption: "Show an X inside disabled ports in addition to reduced contrast.",
          isOn: $settings.showsDisabledPortCrosses
        )
      }

      PreferencesSection(
        "Waveform",
        footer:
          "How often a visualizer redraws what it is hearing. Anything past the display's refresh rate is drawn over before it is seen, and a rate a machine cannot keep up with will simply fall behind."
      ) {
        RilliyaWaveformRatePreferenceRows(settings: settings)
      }

      PreferencesSection(
        "Channel Splitting",
        footer:
          "Native follows the selected output device stream. A preset exposes that many leading channels without claiming they were the application's original source layout."
      ) {
        PreferencesPopupRow(
          symbol: "slider.horizontal.2.square",
          title: "Default separated layout",
          caption: "Choose the channel count used when a connected route is split automatically.",
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

private struct RilliyaCustomizationPreferencesPane: View {
  @Bindable var settings: RilliyaSettings

  var body: some View {
    PreferencesPaneStack {

      PreferencesSection(
        "Node Colors",
        footer:
          "These colors are the default for each node type. A node-specific color chosen in a workflow takes priority."
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
          setSelection: setSelection
        )
        .padding(.horizontal, 14)
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

/// Chooses how often a waveform reports what it has heard.
///
/// Three rates are offered because they are the ones displays run at. Anything else is typed,
/// because a rate this cannot foresee is still the person's to choose: the only value refused is
/// one below a single update a second, which would report nothing at all.
private struct RilliyaWaveformRatePreferenceRows: View {
  @Bindable var settings: RilliyaSettings
  @State private var typed = ""

  var body: some View {
    PreferencesPopupRow(
      symbol: "waveform.path",
      title: "Updates per second",
      caption: "Thirty matches what an audio device meters itself at.",
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
        caption: "Updates per second."
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
