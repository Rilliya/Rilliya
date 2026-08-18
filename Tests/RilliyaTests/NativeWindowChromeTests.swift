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
    let nativeCloseButton = window.standardWindowButton(.closeButton)
    let nativeMiniaturizeButton = window.standardWindowButton(.miniaturizeButton)
    let nativeTrafficLightSpacing =
      (nativeMiniaturizeButton?.frame.minX ?? 0) - (nativeCloseButton?.frame.maxX ?? 0)

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

    let closeButton = window.standardWindowButton(.closeButton)
    let miniaturizeButton = window.standardWindowButton(.miniaturizeButton)
    let zoomButton = window.standardWindowButton(.zoomButton)
    let closeButtonArtworkInset =
      max(((closeButton?.frame.height ?? 0) - (closeButton?.frame.width ?? 0)) / 2, 0)
    let closeButtonVisualTopInset =
      (closeButton?.superview?.bounds.maxY ?? 0) - (closeButton?.frame.maxY ?? 0)
      + closeButtonArtworkInset
    #expect(closeButton?.frame.origin.x == NativeWindowChrome.trafficLightLeadingOrigin)
    #expect(NativeWindowChrome.trafficLightSpacing == nativeTrafficLightSpacing)
    #expect(closeButtonVisualTopInset == NativeWindowChrome.trafficLightLeadingOrigin)
    #expect(
      closeButtonVisualTopInset - NativeWindowChrome.contentEdgeInset
        == NativeWindowChrome.trafficLightLeadingInset
    )
    #expect(
      miniaturizeButton?.frame.origin.x
        == NativeWindowChrome.trafficLightLeadingOrigin
        + (closeButton?.frame.width ?? 0)
        + NativeWindowChrome.trafficLightSpacing
    )
    #expect(
      zoomButton?.frame.origin.x
        == (miniaturizeButton?.frame.maxX ?? 0) + NativeWindowChrome.trafficLightSpacing
    )
  }

  @Test
  func paletteUsesEqualTopLeadingAndBottomInsetsWithHoverBreathingRoom() {
    #expect(RoutingNodePaletteMetrics.outerTopInset == RoutingNodePaletteMetrics.outerLeadingInset)
    #expect(
      RoutingNodePaletteMetrics.outerBottomInset == RoutingNodePaletteMetrics.outerLeadingInset
    )
    #expect(
      RoutingNodePaletteMetrics.panelCornerRadius
        == NativeWindowChrome.visualWindowCornerRadius
    )
    #expect(
      RoutingNodePaletteMetrics.scrollIndicatorTrailingOffset
        == RoutingNodePaletteMetrics.panelHorizontalPadding
    )
    #expect(RoutingNodePaletteMetrics.cardHoverOutset > 0)
  }

  @Test
  func customTitlebarRegionRetainsNativeWindowDraggingSemantics() {
    let dragRegion = NativeWindowDragRegionView()

    #expect(dragRegion.mouseDownCanMoveWindow)
  }
}
