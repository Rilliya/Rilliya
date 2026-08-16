import FlowingDayControls
import SwiftUI

@main
struct RilliyaApp: App {
  @State private var settings = RilliyaSettings.shared
  @State private var runtime = RilliyaRuntime()

  var body: some Scene {
    WindowGroup("Rilliya", id: "workspace") {
      WorkspaceView(runtime: runtime, settings: settings)
        .flowingAccent(.fern)
        .preferredColorScheme(settings.appearance.preferredColorScheme)
        .onChange(of: settings.appearance, initial: true) { _, appearance in
          appearance.applyToApplication()
        }
        .onChange(of: settings.showsInDock, initial: true) {
          RilliyaApplicationPresentation.apply(settings)
        }
        .task {
          runtime.start(settings: settings)
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

    MenuBarExtra(
      "Rilliya",
      image: "RilliyaStatusIcon",
      isInserted: Binding(
        get: { settings.showsInStatusBar },
        set: { isVisible in
          settings.setShowsInStatusBar(isVisible)
          RilliyaApplicationPresentation.apply(settings)
        }
      )
    ) {
      RilliyaStatusMenuView(runtime: runtime, settings: settings)
    }
    .menuBarExtraStyle(.window)
  }
}
