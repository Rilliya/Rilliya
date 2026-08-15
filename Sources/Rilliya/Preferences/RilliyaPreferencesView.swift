import FlowingDayControls
import FlowingDayPreferences
import SwiftUI

private enum RilliyaPreferencesPage: Hashable {
  case canvas
}

private struct RilliyaPreferencesRoot: View {
  let settings: RilliyaSettings

  @State private var selection = RilliyaPreferencesPage.canvas

  var body: some View {
    PreferencesView(
      selection: $selection,
      configuration: PreferencesViewConfiguration(
        applicationName: "Rilliya",
        defaultAccent: .fern
      ),
      groups: [
        PreferencesPageGroup(
          id: "routing",
          pages: [
            PreferencesPage(
              id: .canvas,
              title: "Canvas",
              subtitle: "Connection labels and routing details",
              icon: .system("point.3.connected.trianglepath.dotted")
            ) {
              RilliyaCanvasPreferencesPane(settings: settings)
            }
          ]
        )
      ]
    )
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
