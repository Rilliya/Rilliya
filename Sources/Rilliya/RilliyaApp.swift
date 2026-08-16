import FlowingDayControls
import SwiftUI

@main
struct RilliyaApp: App {
  @State private var settings = RilliyaSettings.shared

  var body: some Scene {
    WindowGroup("Rilliya") {
      WorkspaceView(settings: settings)
        .flowingAccent(.fern)
        .preferredColorScheme(settings.appearance.preferredColorScheme)
        .onChange(of: settings.appearance, initial: true) { _, appearance in
          appearance.applyToApplication()
        }
    }
    .defaultSize(width: 1_080, height: 680)
    .windowResizability(.contentMinSize)
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(replacing: .appSettings) {
        Button("Preferences…") {
          RilliyaPreferencesWindowController.shared.showPreferences()
        }
        .keyboardShortcut(",", modifiers: .command)
      }
    }
  }
}
