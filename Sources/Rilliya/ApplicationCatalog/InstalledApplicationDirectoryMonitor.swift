import CoreServices
import Foundation

protocol InstalledApplicationDirectoryMonitoring: Sendable {
  func changes() -> AsyncStream<Void>
}

struct SystemInstalledApplicationDirectoryMonitor: InstalledApplicationDirectoryMonitoring {
  private let latency: CFTimeInterval
  private let paths: [String]

  init(
    paths: [URL] = standardApplicationDirectoryURLs(),
    latency: CFTimeInterval = 0.5
  ) {
    self.paths = paths.map(\.path)
    self.latency = latency
  }

  func changes() -> AsyncStream<Void> {
    let latency = latency
    let paths = paths
    return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      guard !paths.isEmpty else {
        continuation.finish()
        return
      }

      let subscription = ApplicationDirectoryEventSubscription(
        paths: paths,
        latency: latency
      ) {
        continuation.yield()
      }
      continuation.onTermination = { _ in
        subscription.cancel()
      }
      guard subscription.start() else {
        continuation.finish()
        return
      }
    }
  }
}

private final class ApplicationDirectoryEventCallback: @unchecked Sendable {
  private let handler: @Sendable () -> Void

  init(handler: @escaping @Sendable () -> Void) {
    self.handler = handler
  }

  func receiveEvents() {
    handler()
  }
}

private final class ApplicationDirectoryEventSubscription: @unchecked Sendable {
  private let callback: ApplicationDirectoryEventCallback
  private let latency: CFTimeInterval
  private let lock = NSLock()
  private let paths: [String]
  private let queue = DispatchQueue(
    label: "moe.uwucocoa.rilliya.application-directory-events",
    qos: .utility
  )
  private var stream: FSEventStreamRef?

  init(
    paths: [String],
    latency: CFTimeInterval,
    handler: @escaping @Sendable () -> Void
  ) {
    self.callback = ApplicationDirectoryEventCallback(handler: handler)
    self.latency = latency
    self.paths = paths
  }

  func start() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard stream == nil else { return true }

    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(callback).toOpaque(),
      retain: retainApplicationDirectoryEventCallback,
      release: releaseApplicationDirectoryEventCallback,
      copyDescription: nil
    )
    guard
      let newStream = FSEventStreamCreate(
        nil,
        receiveApplicationDirectoryEvents,
        &context,
        paths as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
        latency,
        FSEventStreamCreateFlags(
          kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagIgnoreSelf
            | kFSEventStreamCreateFlagFileEvents
        )
      )
    else {
      return false
    }

    FSEventStreamSetDispatchQueue(newStream, queue)
    guard FSEventStreamStart(newStream) else {
      FSEventStreamInvalidate(newStream)
      FSEventStreamRelease(newStream)
      return false
    }
    stream = newStream
    return true
  }

  func cancel() {
    lock.lock()
    let currentStream = stream
    stream = nil
    lock.unlock()
    guard let currentStream else { return }

    FSEventStreamStop(currentStream)
    FSEventStreamInvalidate(currentStream)
    FSEventStreamRelease(currentStream)
  }

  deinit {
    cancel()
  }
}

private func retainApplicationDirectoryEventCallback(
  _ info: UnsafeRawPointer?
) -> UnsafeRawPointer? {
  guard let info else { return nil }
  return UnsafeRawPointer(
    Unmanaged<ApplicationDirectoryEventCallback>.fromOpaque(info).retain().toOpaque()
  )
}

private func releaseApplicationDirectoryEventCallback(_ info: UnsafeRawPointer?) {
  guard let info else { return }
  Unmanaged<ApplicationDirectoryEventCallback>.fromOpaque(info).release()
}

private func receiveApplicationDirectoryEvents(
  _ stream: ConstFSEventStreamRef,
  _ clientCallbackInfo: UnsafeMutableRawPointer?,
  _ eventCount: Int,
  _ eventPaths: UnsafeMutableRawPointer,
  _ eventFlags: UnsafePointer<FSEventStreamEventFlags>,
  _ eventIDs: UnsafePointer<FSEventStreamEventId>
) {
  guard eventCount > 0, let clientCallbackInfo else { return }
  Unmanaged<ApplicationDirectoryEventCallback>
    .fromOpaque(clientCallbackInfo)
    .takeUnretainedValue()
    .receiveEvents()
}
