import AppKit
import FlowingDayGraphCanvas
import SwiftUI
import Testing

@testable import Rilliya

struct RoutingMetalCanvasTests {
  @Test @MainActor
  func canvasRetainsKeyboardFocusWithoutDrawingAnAppKitFocusRing() throws {
    let workspace = RoutingWorkspaceModel()
    let scene = RoutingMetalScene(
      content: try #require(workspace.canvasContent),
      supplements: [:]
    )
    let controller = RoutingMetalCanvasController(initialZoom: 1)
    let canvas = RoutingMetalCanvasView(
      scene: scene,
      selection: [],
      configuration: FlowingGraphCanvasConfiguration(),
      contentInsets: EdgeInsets(),
      mouseTool: .select,
      showsDisabledPortCrosses: true,
      controller: controller
    )

    #expect(canvas.acceptsFirstResponder)
    #expect(canvas.focusRingType == .none)
  }
}
