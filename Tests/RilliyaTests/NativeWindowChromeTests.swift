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
    let buttons: [(name: String, type: NSWindow.ButtonType)] = [
      ("close", .closeButton),
      ("miniaturize", .miniaturizeButton),
      ("zoom", .zoomButton),
    ]
    // How AppKit spaces and sizes these differs by macOS release — 6 points apart and 16 tall
    // through macOS 15, 9 apart and 14 tall from 26 — so what is asserted is that the group is
    // moved rather than respaced, which holds on every release.
    let nativeLeadingEdge = window.standardWindowButton(.closeButton)?.frame.minX ?? 0
    let nativeOffsets = buttons.map {
      (window.standardWindowButton($0.type)?.frame.minX ?? 0) - nativeLeadingEdge
    }

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
    let closeButtonArtworkInset =
      max(((closeButton?.frame.height ?? 0) - (closeButton?.frame.width ?? 0)) / 2, 0)
    let closeButtonVisualTopInset =
      (closeButton?.superview?.bounds.maxY ?? 0) - (closeButton?.frame.maxY ?? 0)
      + closeButtonArtworkInset
    #expect(closeButton?.frame.origin.x == NativeWindowChrome.trafficLightLeadingOrigin)
    #expect(closeButtonVisualTopInset == NativeWindowChrome.trafficLightLeadingOrigin)
    #expect(
      closeButtonVisualTopInset - NativeWindowChrome.contentEdgeInset
        == NativeWindowChrome.trafficLightLeadingInset
    )

    func expectNativeOffsetsPreserved(_ occasion: String) {
      let leadingEdge = window.standardWindowButton(.closeButton)?.frame.minX ?? 0
      #expect(leadingEdge == NativeWindowChrome.trafficLightLeadingOrigin)
      for (button, nativeOffset) in zip(buttons, nativeOffsets) {
        let offset = (window.standardWindowButton(button.type)?.frame.minX ?? 0) - leadingEdge
        #expect(
          offset == nativeOffset,
          "\(occasion): \(button.name) is \(offset) from close, not the native \(nativeOffset)"
        )
      }
    }

    expectNativeOffsetsPreserved("after configuring")
    // `layout()` positions on every pass, so doing it again must not walk the group along.
    NativeWindowChrome.positionTrafficLights(in: window)
    expectNativeOffsetsPreserved("after positioning a second time")
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
