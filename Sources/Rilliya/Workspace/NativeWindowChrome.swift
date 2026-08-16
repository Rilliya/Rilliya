import AppKit
import SwiftUI

enum NativeWindowChrome {
  static let title = "Rilliya"
  static let contentEdgeInset: CGFloat = 8
  static let visualWindowCornerRadius: CGFloat = 12
  static let trafficLightLeadingInset: CGFloat = 12
  static let trafficLightLeadingOrigin = contentEdgeInset + trafficLightLeadingInset
  static let trafficLightBottomOrigin: CGFloat = 1
  static let trafficLightSpacing: CGFloat = 9

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
    positionTrafficLights(in: window)
    #if PROFILE
      if RoutingProfilingScenario.fromProcessArguments() != nil {
        window.setContentSize(NSSize(width: 1_080, height: 680))
      }
    #endif
  }

  @MainActor
  static func positionTrafficLights(in window: NSWindow) {
    let buttonTypes: [NSWindow.ButtonType] = [
      .closeButton,
      .miniaturizeButton,
      .zoomButton,
    ]
    var nextX = trafficLightLeadingOrigin
    for type in buttonTypes {
      guard let button = window.standardWindowButton(type) else { continue }
      button.setFrameOrigin(NSPoint(x: nextX, y: trafficLightBottomOrigin))
      nextX += button.frame.width + trafficLightSpacing
    }
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

  override func layout() {
    super.layout()
    guard let window else { return }
    NativeWindowChrome.positionTrafficLights(in: window)
  }
}
