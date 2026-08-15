import AppKit
import Observation

private actor InstalledApplicationIconLoadLimiter {
  private let limit: Int
  private var activeCount = 0
  private var waiters: [CheckedContinuation<Void, Never>] = []

  init(limit: Int) {
    precondition(limit > 0)
    self.limit = limit
  }

  func acquire() async {
    if activeCount < limit {
      activeCount += 1
      return
    }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func release() {
    guard !waiters.isEmpty else {
      activeCount -= 1
      return
    }
    waiters.removeFirst().resume()
  }
}

@MainActor
protocol InstalledApplicationIconResolving: AnyObject {
  func icon(for application: InstalledApplication) -> NSImage

  func cachedIcon(for application: InstalledApplication) -> NSImage?

  func loadIcon(for application: InstalledApplication) async -> NSImage?
}

@MainActor
@Observable
final class NSWorkspaceInstalledApplicationIconResolver: InstalledApplicationIconResolving {
  private enum Constants {
    static let logicalSize = CGSize(width: 32, height: 32)
    static let pixelDimension = 96
    static let iconCost = pixelDimension * pixelDimension * 4
    static let maximumPendingLoadCount = 16
    static let maximumPinnedIconCount = 128
    static let maximumConcurrentLoadCount = 4
  }

  private(set) var revision: UInt64 = 0

  @ObservationIgnored private let cachedIcons: NSCache<NSString, NSImage>
  @ObservationIgnored private let limiter: InstalledApplicationIconLoadLimiter
  @ObservationIgnored private let iconLoader: @Sendable (URL) -> NSImage
  @ObservationIgnored private var pendingLoads: [NSString: Task<NSImage, Never>] = [:]
  @ObservationIgnored private var pinnedIcons: [NSString: NSImage] = [:]
  @ObservationIgnored private var pinGeneration: UInt64 = 0

  init(
    iconLoader: @escaping @Sendable (URL) -> NSImage = NSWorkspaceInstalledApplicationIconResolver
      .rasterizedIcon
  ) {
    cachedIcons = NSCache()
    cachedIcons.countLimit = 64
    cachedIcons.totalCostLimit = 4 * 1_024 * 1_024
    limiter = InstalledApplicationIconLoadLimiter(limit: Constants.maximumConcurrentLoadCount)
    self.iconLoader = iconLoader
  }

  func icon(for application: InstalledApplication) -> NSImage {
    if let cachedIcon = cachedIcon(for: application) {
      return cachedIcon
    }

    let icon = iconLoader(application.bundleURL)
    store(icon, for: application)
    return icon
  }

  func cachedIcon(for application: InstalledApplication) -> NSImage? {
    let key = cacheKey(for: application)
    return pinnedIcons[key] ?? cachedIcons.object(forKey: key)
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
      guard pendingLoads.count < Constants.maximumPendingLoadCount else { return nil }
      let iconLoader = iconLoader
      let limiter = limiter
      let pendingLoad = Task.detached(priority: .utility) {
        await limiter.acquire()
        let icon = iconLoader(applicationURL)
        await limiter.release()
        return icon
      }
      pendingLoads[key] = pendingLoad
      task = pendingLoad
    }
    let icon = await task.value
    pendingLoads[key] = nil
    store(icon, for: application)
    return icon
  }

  func updatePinnedApplications(_ applications: [InstalledApplication]) async {
    pinGeneration &+= 1
    let generation = pinGeneration
    let retainedApplications = Array(
      applications
        .sorted { $0.bundleURL.absoluteString < $1.bundleURL.absoluteString }
        .prefix(Constants.maximumPinnedIconCount)
    )
    let retainedKeys = Set(retainedApplications.map(cacheKey))
    pinnedIcons = pinnedIcons.filter { retainedKeys.contains($0.key) }

    for application in retainedApplications {
      guard generation == pinGeneration else { return }
      let icon: NSImage?
      if let cachedIcon = cachedIcon(for: application) {
        icon = cachedIcon
      } else {
        icon = await loadIcon(for: application)
      }
      if let icon {
        guard generation == pinGeneration else { return }
        pinnedIcons[cacheKey(for: application)] = icon
      }
    }
    revision &+= 1
  }

  func discardUnpinnedIcons() {
    cachedIcons.removeAllObjects()
    revision &+= 1
  }

  var pendingLoadCount: Int { pendingLoads.count }
  var pinnedIconCount: Int { pinnedIcons.count }

  private func store(_ icon: NSImage, for application: InstalledApplication) {
    cachedIcons.setObject(
      icon,
      forKey: cacheKey(for: application),
      cost: Constants.iconCost
    )
    revision &+= 1
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
