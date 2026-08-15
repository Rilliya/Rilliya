import AppKit
import Foundation
import Testing

@testable import Rilliya

@MainActor
struct InstalledApplicationIconResolverTests {
  @Test
  func concurrentRequestsForOneApplicationShareOneLoad() async {
    let probe = BlockingIconLoaderProbe()
    let resolver = NSWorkspaceInstalledApplicationIconResolver(iconLoader: probe.load)
    let application = installedApplication(named: "Music")

    let firstRequest = Task { await resolver.loadIcon(for: application) }
    await probe.waitUntilStarted()
    let secondRequest = Task { await resolver.loadIcon(for: application) }
    await Task.yield()

    #expect(resolver.pendingLoadCount == 1)
    probe.release()

    let firstIcon = await firstRequest.value
    let secondIcon = await secondRequest.value
    #expect(firstIcon === secondIcon)
    #expect(probe.loadCount == 1)
    #expect(resolver.pendingLoadCount == 0)
  }

  @Test
  func pinnedIconsSurviveOrdinaryCacheDiscardAndReleaseWhenUnpinned() async {
    let probe = ImmediateIconLoaderProbe()
    let resolver = NSWorkspaceInstalledApplicationIconResolver(iconLoader: probe.load)
    let application = installedApplication(named: "Music")

    await resolver.updatePinnedApplications([application])
    resolver.discardUnpinnedIcons()

    #expect(resolver.pinnedIconCount == 1)
    #expect(resolver.cachedIcon(for: application) != nil)
    #expect(probe.loadCount == 1)

    await resolver.updatePinnedApplications([])
    resolver.discardUnpinnedIcons()

    #expect(resolver.pinnedIconCount == 0)
    #expect(resolver.cachedIcon(for: application) == nil)
  }

  private func installedApplication(named name: String) -> InstalledApplication {
    let url = URL(fileURLWithPath: "/Applications/\(name).app")
    return InstalledApplication(
      id: InstalledApplicationID(
        fileResourceIdentifier: Data(name.utf8),
        canonicalURL: url
      ),
      bundleURL: url,
      bundleIdentifier: "example.\(name.lowercased())",
      displayName: name,
      kind: .regular,
      discoverySources: [.standardApplicationDirectory]
    )
  }
}

private final class BlockingIconLoaderProbe: @unchecked Sendable {
  private let lock = NSLock()
  private let started = DispatchSemaphore(value: 0)
  private let gate = DispatchSemaphore(value: 0)
  private var mutableLoadCount = 0

  var loadCount: Int {
    lock.withLock { mutableLoadCount }
  }

  func load(_ url: URL) -> NSImage {
    lock.withLock { mutableLoadCount += 1 }
    started.signal()
    gate.wait()
    return NSImage(size: CGSize(width: 32, height: 32))
  }

  func waitUntilStarted() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async { [started] in
        started.wait()
        continuation.resume()
      }
    }
  }

  func release() {
    gate.signal()
  }
}

private final class ImmediateIconLoaderProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var mutableLoadCount = 0

  var loadCount: Int {
    lock.withLock { mutableLoadCount }
  }

  func load(_ url: URL) -> NSImage {
    lock.withLock { mutableLoadCount += 1 }
    return NSImage(size: CGSize(width: 32, height: 32))
  }
}
