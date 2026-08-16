import AppKit
import FlowingDayControls
import FlowingDayPreferences
import SwiftUI

private enum RilliyaPreferencesPage: Hashable {
  case general
  case canvas
  case customization
  case about
}

private struct RilliyaPreferencesRoot: View {
  let settings: RilliyaSettings

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
              subtitle: "Workflow overview and node insertion",
              icon: .system("gearshape")
            ) {
              RilliyaGeneralPreferencesPane(settings: settings)
            },
            PreferencesPage(
              id: .canvas,
              title: "Canvas",
              subtitle: "Connections and channel presentation",
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
          id: "application",
          pages: [
            PreferencesPage(
              id: .about,
              title: "About",
              subtitle: "Version, foundation, and interface credits",
              icon: .system("info.circle"),
              headerIcon: .application
            ) {
              RilliyaAboutPreferencesPane(versionText: Self.versionText)
            }
          ]
        ),
      ]
    )
  }

  private static var versionText: String {
    let info = Bundle.main.infoDictionary
    let version = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    let build = info?["CFBundleVersion"] as? String
    return build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
  }
}

private struct RilliyaGeneralPreferencesPane: View {
  @Bindable var settings: RilliyaSettings
  @State private var launchAtLoginController = RilliyaLaunchAtLoginController()

  var body: some View {
    PreferencesPaneStack {
      PreferencesSection(
        "Application",
        footer: "macOS controls login-item approval in System Settings."
      ) {
        PreferencesSwitchRow(
          symbol: "power",
          title: "Launch at login",
          caption: "Open Rilliya after you sign in so launch-enabled workflows can resume.",
          isOn: Binding(
            get: { launchAtLoginController.isEnabled },
            set: launchAtLoginController.setEnabled
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

        PreferencesSwitchRow(
          symbol: "xmark.circle",
          title: "Mark disabled ports",
          caption: "Show an X inside disabled ports in addition to reduced contrast.",
          isOn: $settings.showsDisabledPortCrosses
        )
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

      PreferencesSection("Foundation") {
        PreferencesLinkRow(
          symbol: "waveform.path.ecg",
          title: "RilliyaKit",
          caption: "The open-source capture, DSP, playback, graph, and realtime audio foundation.",
          buttonTitle: "GitHub",
          destination: Self.rilliyaKitURL,
          help: "Open RilliyaKit on GitHub"
        )
        PreferencesRowSeparator(leadingEdge: .iconText)
        PreferencesLinkRow(
          symbol: "paintpalette",
          title: "FlowingDayUI",
          caption: "The open-source SwiftUI component library used throughout Rilliya.",
          buttonTitle: "GitHub",
          destination: Self.flowingDayURL,
          help: "Open FlowingDayUI on GitHub"
        )
      }

      PreferencesSection("Details") {
        PreferencesValueRow(title: "Requirements", value: "macOS 14.2 or later")
        PreferencesRowSeparator()
        PreferencesValueRow(title: "Audio Engine", value: "Core Audio · Metal · RilliyaKit")
      }
    }
  }

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
    rootView: RilliyaPreferencesRoot(settings: RilliyaSettings.shared)
  )

  private init() {}

  func showPreferences() {
    presenter.show()
  }
}
