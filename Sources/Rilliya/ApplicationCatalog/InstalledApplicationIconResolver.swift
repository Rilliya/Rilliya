import AppKit

@MainActor
protocol InstalledApplicationIconResolving: AnyObject {
  func icon(for application: InstalledApplication) -> NSImage

  func cachedIcon(for application: InstalledApplication) -> NSImage?

  func loadIcon(for application: InstalledApplication) async -> NSImage?
}

@MainActor
final class NSWorkspaceInstalledApplicationIconResolver: InstalledApplicationIconResolving {
  private enum Constants {
    static let logicalSize = CGSize(width: 32, height: 32)
    static let pixelDimension = 96
    static let iconCost = pixelDimension * pixelDimension * 4
  }

  private let cachedIcons: NSCache<NSString, NSImage>
  private var pendingLoads: [NSString: Task<NSImage, Never>] = [:]

  init() {
    cachedIcons = NSCache()
    cachedIcons.countLimit = 64
    cachedIcons.totalCostLimit = 4 * 1_024 * 1_024
  }

  func icon(for application: InstalledApplication) -> NSImage {
    if let cachedIcon = cachedIcon(for: application) {
      return cachedIcon
    }

    let icon = Self.rasterizedIcon(at: application.bundleURL)
    store(icon, for: application)
    return icon
  }

  func cachedIcon(for application: InstalledApplication) -> NSImage? {
    cachedIcons.object(forKey: cacheKey(for: application))
  }

  func loadIcon(for application: InstalledApplication) async -> NSImage? {
    if let cachedIcon = cachedIcon(for: application) {
      return cachedIcon
    }
    let applicationURL = application.bundleURL
    let key = cacheKey(for: application)
    let task: Task<NSImage, Never>
    if let pendingLoad = pendingLoads[key] {
      task = pendingLoad
    } else {
      let pendingLoad = Task.detached(priority: .utility) {
        Self.rasterizedIcon(at: applicationURL)
      }
      pendingLoads[key] = pendingLoad
      task = pendingLoad
    }
    let icon = await task.value
    pendingLoads[key] = nil
    store(icon, for: application)
    return icon
  }

  private func store(_ icon: NSImage, for application: InstalledApplication) {
    cachedIcons.setObject(
      icon,
      forKey: cacheKey(for: application),
      cost: Constants.iconCost
    )
  }

  private func cacheKey(for application: InstalledApplication) -> NSString {
    canonicalApplicationURL(application.bundleURL).absoluteString as NSString
  }

  nonisolated private static func rasterizedIcon(at applicationURL: URL) -> NSImage {
    autoreleasepool {
      let source = NSWorkspace.shared.icon(forFile: applicationURL.path)
      guard
        let bitmap = NSBitmapImageRep(
          bitmapDataPlanes: nil,
          pixelsWide: Constants.pixelDimension,
          pixelsHigh: Constants.pixelDimension,
          bitsPerSample: 8,
          samplesPerPixel: 4,
          hasAlpha: true,
          isPlanar: false,
          colorSpaceName: .deviceRGB,
          bytesPerRow: 0,
          bitsPerPixel: 0
        )
      else {
        source.size = Constants.logicalSize
        return source
      }

      bitmap.size = Constants.logicalSize
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
      source.draw(
        in: CGRect(origin: .zero, size: Constants.logicalSize),
        from: .zero,
        operation: .copy,
        fraction: 1,
        respectFlipped: true,
        hints: [.interpolation: NSImageInterpolation.high.rawValue]
      )
      NSGraphicsContext.restoreGraphicsState()
      guard let image = bitmap.cgImage else {
        source.size = Constants.logicalSize
        return source
      }
      return NSImage(cgImage: image, size: Constants.logicalSize)
    }
  }
}
