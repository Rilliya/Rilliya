import AppKit
import SwiftUI

enum NativeWindowChrome {
  static let title = "Rilliya"

  @MainActor
  static func configure(_ window: NSWindow) {
    window.title = title
    window.styleMask.formUnion([
      .titled,
      .closable,
      .miniaturizable,
      .resizable,
      .fullSizeContentView,
    ])
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.titlebarSeparatorStyle = .none
  }
}

struct NativeWindowChromeAttachment: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    NativeWindowChromeView()
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

struct NativeWindowDragRegion: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    NativeWindowDragRegionView()
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
}

@MainActor
final class NativeWindowDragRegionView: NSView {
  override var mouseDownCanMoveWindow: Bool { true }

  override func mouseDown(with event: NSEvent) {
    window?.performDrag(with: event)
  }
}

@MainActor
private final class NativeWindowChromeView: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else { return }
    NativeWindowChrome.configure(window)
  }
}
