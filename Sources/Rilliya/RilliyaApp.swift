import RilliyaKit
import SwiftUI

@main
struct RilliyaApp: App {
  var body: some Scene {
    WindowGroup {
      WorkspaceView()
    }
    .defaultSize(width: 1_080, height: 680)
    .windowResizability(.contentMinSize)
  }
}
