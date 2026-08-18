import AppKit
import SwiftUI

enum NativeWindowChrome {
  static let title = "Rilliya"
  static let contentEdgeInset: CGFloat = 8
  static let visualWindowCornerRadius: CGFloat = 12
  static let trafficLightLeadingInset: CGFloat = 12
  static let trafficLightLeadingOrigin = contentEdgeInset + trafficLightLeadingInset

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

  /// Moves the traffic lights to our leading inset without restyling the group.
  ///
  /// How far apart AppKit sets these buttons is not the same on every macOS — 6 points through
  /// macOS 15 and 9 from macOS 26 — and neither is their size. So each button keeps the horizontal
  /// offset AppKit gave it relative to the close button, and only the group's leading edge moves.
  /// Writing a spacing down here would look native on whichever release it was measured on and
  /// wrong on the others.
  ///
  /// Preserving the offsets also makes this idempotent, which matters because `layout()` calls it
  /// on every pass.
  @MainActor
  static func positionTrafficLights(in window: NSWindow) {
    let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
      .compactMap(window.standardWindowButton)
    guard let close = buttons.first else { return }

    let nativeLeadingEdge = close.frame.minX
    for button in buttons {
      guard let titlebar = button.superview else { continue }
      let offsetFromClose = button.frame.minX - nativeLeadingEdge
      let artworkInset = max((button.frame.height - button.frame.width) / 2, 0)
      let frameTopInset = trafficLightLeadingOrigin - artworkInset
      let originY = titlebar.bounds.maxY - button.frame.height - frameTopInset
      button.setFrameOrigin(
        NSPoint(x: trafficLightLeadingOrigin + offsetFromClose, y: originY)
      )
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
