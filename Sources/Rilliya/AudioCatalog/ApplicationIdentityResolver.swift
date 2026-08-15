import AppKit
import RilliyaKit

struct ResolvedApplicationIdentity {
  let displayName: String?
  let icon: NSImage?
}

@MainActor
struct ApplicationIdentityResolver {
  func resolve(_ process: AudioProcess) -> ResolvedApplicationIdentity {
    let runningApplication = NSRunningApplication(processIdentifier: process.id.rawValue)
    let runningName = runningApplication?.localizedName.flatMap { $0.isEmpty ? nil : $0 }
    let runningIcon = runningApplication?.icon
    var applicationURL: URL?
    if runningName == nil || runningIcon == nil, let bundleIdentifier = process.bundleIdentifier {
      applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
    let installedName = applicationURL?.deletingPathExtension().lastPathComponent
    let installedIcon = applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    return ResolvedApplicationIdentity(
      displayName: runningName ?? installedName,
      icon: runningIcon ?? installedIcon
    )
  }
}
