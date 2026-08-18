import AppKit
import FlowingDayGraphCanvas
import QuartzCore
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
    #expect((canvas.layer as? CAMetalLayer)?.maximumDrawableCount == 2)
  }

  /// Multisampling is taken when the GPU has it and given up when it does not.
  ///
  /// Asserting one fixed count only described whichever machine the test last ran on: it read as a
  /// promise that the canvas never multisamples, and went red the moment the canvas started to.
  /// What the canvas actually decides is this fallback, so this is what is worth holding it to.
  @Test @MainActor
  func canvasMultisamplesWhereItCanAndFallsBackWhereItCannot() throws {
    let workspace = RoutingWorkspaceModel()
    let scene = RoutingMetalScene(
      content: try #require(workspace.canvasContent),
      supplements: [:]
    )
    let canvas = RoutingMetalCanvasView(
      scene: scene,
      selection: [],
      configuration: FlowingGraphCanvasConfiguration(),
      contentInsets: EdgeInsets(),
      mouseTool: .select,
      showsDisabledPortCrosses: true,
      controller: RoutingMetalCanvasController(initialZoom: 1)
    )
    let device = try #require(canvas.device)
    let preferred = RoutingMetalEdgeStrokeMetrics.preferredSampleCount

    if device.supportsTextureSampleCount(preferred) {
      #expect(
        canvas.sampleCount == preferred,
        "a GPU offering \(preferred)x was drawn without it")
    } else {
      #expect(canvas.sampleCount == 1, "an unsupported sample count was asked for anyway")
    }

    // Whatever it settled on has to be something the GPU will actually render.
    #expect(device.supportsTextureSampleCount(canvas.sampleCount))
  }
}
