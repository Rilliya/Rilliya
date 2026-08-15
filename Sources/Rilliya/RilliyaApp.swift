import FlowingDayControls
import SwiftUI

@main
struct RilliyaApp: App {
  var body: some Scene {
    WindowGroup("Rilliya") {
      WorkspaceView(settings: RilliyaSettings.shared)
        .flowingAccent(.fern)
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
