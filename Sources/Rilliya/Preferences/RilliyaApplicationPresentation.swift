import AppKit

@MainActor
enum RilliyaApplicationPresentation {
  static func apply(_ settings: RilliyaSettings) {
    let policy: NSApplication.ActivationPolicy = settings.showsInDock ? .regular : .accessory
    _ = NSApp.setActivationPolicy(policy)
  }
}
