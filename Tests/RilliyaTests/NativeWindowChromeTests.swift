import AppKit
import Testing

@testable import Rilliya

@MainActor
struct NativeWindowChromeTests {
  @Test
  func configurationPreservesNativeWindowSemanticsWhileHidingTitleChrome() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )

    NativeWindowChrome.configure(window)

    #expect(window.title == "Rilliya")
    #expect(window.titleVisibility == .hidden)
    #expect(window.titlebarAppearsTransparent)
    #expect(window.titlebarSeparatorStyle == .none)
    #expect(window.styleMask.contains(.titled))
    #expect(window.styleMask.contains(.closable))
    #expect(window.styleMask.contains(.miniaturizable))
    #expect(window.styleMask.contains(.resizable))
    #expect(window.styleMask.contains(.fullSizeContentView))
    #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
    #expect(window.standardWindowButton(.miniaturizeButton)?.isHidden == false)
    #expect(window.standardWindowButton(.zoomButton)?.isHidden == false)
  }

  @Test
  func customTitlebarRegionRetainsNativeWindowDraggingSemantics() {
    let dragRegion = NativeWindowDragRegionView()

    #expect(dragRegion.mouseDownCanMoveWindow)
  }
}
