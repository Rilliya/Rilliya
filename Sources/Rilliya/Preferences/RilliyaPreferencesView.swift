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
