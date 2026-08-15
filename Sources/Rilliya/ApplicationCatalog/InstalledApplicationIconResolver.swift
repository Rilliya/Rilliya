import AppKit

@MainActor
protocol InstalledApplicationIconResolving: AnyObject {
  func icon(for application: InstalledApplication) -> NSImage
}

@MainActor
final class NSWorkspaceInstalledApplicationIconResolver: InstalledApplicationIconResolving {
  private var cachedIcons: [InstalledApplicationID: NSImage] = [:]

  func icon(for application: InstalledApplication) -> NSImage {
    if let cachedIcon = cachedIcons[application.id] {
      return cachedIcon
    }

    let icon = NSWorkspace.shared.icon(forFile: application.bundleURL.path)
    cachedIcons[application.id] = icon
    return icon
  }
}
