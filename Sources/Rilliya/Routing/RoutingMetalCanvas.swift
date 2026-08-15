import AppKit
import FlowingDayCanvas
import FlowingDayGraphCanvas
import FlowingDayGraphLayout
import MetalKit
import SwiftUI

@MainActor
final class RoutingMetalCanvasController: FlowingGraphCanvasMetalBackendController {
  private weak var routingCanvas: RoutingMetalCanvasView?
  private var hasAttachedCanvas = false

  override init(initialZoom: CGFloat) {
    super.init(initialZoom: initialZoom)
  }

  func attach(_ canvas: RoutingMetalCanvasView) {
    if hasAttachedCanvas, routingCanvas !== canvas {
      canvas.restoreCamera(
        FlowingGraphCanvasMetalCamera(
          zoom: viewport.transform.zoom,
          offset: viewport.transform.offset
        )
      )
    }
    hasAttachedCanvas = true
    routingCanvas = canvas
    super.attach(canvas)
  }

  func adjustZoom(by delta: CGFloat) {
    routingCanvas?.setZoom(zoom + delta)
  }

  func fit() {
    routingCanvas?.fitContent()
  }
}

struct RoutingMetalCanvas: NSViewRepresentable {
  let scene: RoutingMetalScene
  let selection: Set<RoutingCanvasElementID>
  let configuration: FlowingGraphCanvasConfiguration
  let contentInsets: EdgeInsets
  let controller: RoutingMetalCanvasController
  let onSelectionChange: (Set<RoutingCanvasElementID>) -> Void
  let onMoveNode: (RoutingCanvasElementID, CGSize) -> Void
  let onConnect: (RoutingCanvasElementID, RoutingCanvasElementID) -> Void
  let onViewportChange: (FlowingCanvasViewport, FlowingCanvasViewportChangePhase) -> Void

  func makeNSView(context: Context) -> RoutingMetalCanvasView {
    let view = RoutingMetalCanvasView(
      scene: scene,
      selection: selection,
      configuration: configuration,
      contentInsets: contentInsets,
      controller: controller
    )
    configure(view)
    controller.attach(view)
    return view
  }

  func updateNSView(_ nsView: RoutingMetalCanvasView, context: Context) {
    configure(nsView)
    nsView.update(
      scene: scene,
      selection: selection,
      configuration: configuration,
      contentInsets: contentInsets
    )
    controller.attach(nsView)
  }

  private func configure(_ view: RoutingMetalCanvasView) {
    view.onSelectionChange = onSelectionChange
    view.onMoveNode = onMoveNode
    view.onConnect = onConnect
    view.onViewportChange = onViewportChange
  }
}

@MainActor
final class RoutingMetalCanvasView: FlowingGraphCanvasMetalBackendView {
  var onSelectionChange: ((Set<RoutingCanvasElementID>) -> Void)?
  var onMoveNode: ((RoutingCanvasElementID, CGSize) -> Void)?
  var onConnect: ((RoutingCanvasElementID, RoutingCanvasElementID) -> Void)?
  var onViewportChange: ((FlowingCanvasViewport, FlowingCanvasViewportChangePhase) -> Void)?

  private enum Constants {
    static let preferredSampleCount = 4
    static let nodeCornerRadius: CGFloat = 16
    static let iconFrame = CGRect(x: 14, y: 14, width: 38, height: 38)
    static let portDiameter: CGFloat = 13
    static let portHitRadius: CGFloat = 13
    static let edgeWidth: CGFloat = 1.6
    static let connectionPreviewWidth: CGFloat = 1.8
    static let waveformWidth: CGFloat = 1.25
    static let fitPadding: CGFloat = 58
  }

  private let gridPipeline: any MTLRenderPipelineState
  private let shapePipeline: any MTLRenderPipelineState
  private let trianglePipeline: any MTLRenderPipelineState
  private let atlasPipeline: any MTLRenderPipelineState
  private let textAtlas: RoutingMetalTextAtlas
  private let inFlightSemaphore = DispatchSemaphore(value: 3)

  private var shapeBuffers: [any MTLBuffer] = []
  private var triangleBuffers: [any MTLBuffer] = []
  private var atlasBuffers: [any MTLBuffer] = []
  private var frameIndex = 0
  private var frameGeometry = RoutingMetalFrameGeometry()
  private var scene: RoutingMetalScene
  private var selection: Set<RoutingCanvasElementID>
  private var graphConfiguration: FlowingGraphCanvasConfiguration
  private var trackingArea: NSTrackingArea?
  private var hoveredNodeID: RoutingCanvasElementID?
  private var hoveredPortID: RoutingCanvasElementID?
  private var mouseDownViewportPoint: CGPoint?
  private var mouseDownWorldPoint: CGPoint?
  private var mouseDownCameraOffset: CGSize?
  private var draggedNodeID: RoutingCanvasElementID?
  private var dragTranslation = CGSize.zero
  private var connectionSourceID: RoutingCanvasElementID?
  private var connectionLocation: CGPoint?
  private var connectionTargetID: RoutingCanvasElementID?

  init(
    scene: RoutingMetalScene,
    selection: Set<RoutingCanvasElementID>,
    configuration: FlowingGraphCanvasConfiguration,
    contentInsets: EdgeInsets,
    controller: RoutingMetalCanvasController
  ) {
    guard let device = MTLCreateSystemDefaultDevice() else {
      preconditionFailure("Metal is unavailable")
    }
    self.scene = scene
    self.selection = selection
    graphConfiguration = configuration
    textAtlas = RoutingMetalTextAtlas(device: device)
    let sampleCount =
      device.supportsTextureSampleCount(Constants.preferredSampleCount)
      ? Constants.preferredSampleCount
      : 1
    do {
      let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
      gridPipeline = try Self.makePipeline(
        device: device,
        library: library,
        vertex: "gridVertex",
        fragment: "gridFragment",
        sampleCount: sampleCount
      )
      shapePipeline = try Self.makePipeline(
        device: device,
        library: library,
        vertex: "shapeVertex",
        fragment: "shapeFragment",
        sampleCount: sampleCount,
        blends: true
      )
      trianglePipeline = try Self.makePipeline(
        device: device,
        library: library,
        vertex: "triangleVertex",
        fragment: "flatFragment",
        sampleCount: sampleCount,
        blends: true
      )
      atlasPipeline = try Self.makePipeline(
        device: device,
        library: library,
        vertex: "atlasVertex",
        fragment: "atlasFragment",
        sampleCount: sampleCount,
        blends: true
      )
    } catch {
      preconditionFailure("Routing Metal pipeline creation failed: \(error)")
    }
    super.init(
      device: device,
      configuration: FlowingGraphCanvasMetalBackendConfiguration(
        initialZoom: configuration.canvas.initialZoom,
        zoomRange: configuration.canvas.zoomRange,
        pinchSensitivity: configuration.canvas.pinchSensitivity,
        discreteScrollMultiplier: configuration.canvas.discreteScrollMultiplier,
        preferredFramesPerSecond: 120,
        preferredSampleCount: sampleCount
      ),
      contentInsets: contentInsets,
      viewportController: controller
    )
    wantsLayer = true
    layer?.zPosition = -1
    colorPixelFormat = .bgra8Unorm
    self.sampleCount = sampleCount
    colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    framebufferOnly = true
    isPaused = true
    enableSetNeedsDisplay = true
    updateClearColor()
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    window?.makeFirstResponder(self)
  }

  override func layout() {
    super.layout()
    onViewportChange?(viewport, .ended)
    requestDisplay()
  }

  override func updateTrackingAreas() {
    if let trackingArea {
      removeTrackingArea(trackingArea)
    }
    let next = NSTrackingArea(
      rect: .zero,
      options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
      owner: self
    )
    addTrackingArea(next)
    trackingArea = next
    super.updateTrackingAreas()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateClearColor()
    requestDisplay()
  }

  override func viewportDidChange(phase: FlowingCanvasViewportChangePhase) {
    super.viewportDidChange(phase: phase)
    onViewportChange?(viewport, phase)
    requestDisplay()
  }

  override func scrollWheel(with event: NSEvent) {
    super.scrollWheel(with: event)
    requestDisplay()
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    resetPointerInteraction()
    let viewportPoint = convert(event.locationInWindow, from: nil)
    let worldPoint = camera.worldPoint(for: viewportPoint)
    mouseDownViewportPoint = viewportPoint
    mouseDownWorldPoint = worldPoint

    if let port = port(at: worldPoint), port.value.direction == .output {
      connectionSourceID = port.id
      connectionLocation = port.position
      if !selection.contains(port.nodeID) {
        updateSelection([port.nodeID])
      }
      return
    }

    if let node = node(at: worldPoint) {
      let extendsSelection =
        event.modifierFlags.contains(.command)
        || event.modifierFlags.contains(.shift)
      if extendsSelection {
        var next = selection
        if next.contains(node.id) {
          next.remove(node.id)
        } else {
          next.insert(node.id)
        }
        updateSelection(next)
      } else if !selection.contains(node.id) || selection.count != 1 {
        updateSelection([node.id])
      }
      draggedNodeID = node.id
      return
    }

    updateSelection([])
    mouseDownCameraOffset = camera.offset
  }

  override func mouseDragged(with event: NSEvent) {
    guard let startViewportPoint = mouseDownViewportPoint else { return }
    let viewportPoint = convert(event.locationInWindow, from: nil)
    let worldPoint = camera.worldPoint(for: viewportPoint)

    if let sourceID = connectionSourceID, let source = scene.port(id: sourceID) {
      connectionLocation = worldPoint
      connectionTargetID = nearestConnectionTarget(to: worldPoint, source: source)?.id
      requestDisplay()
      return
    }

    if draggedNodeID != nil, let startWorldPoint = mouseDownWorldPoint {
      dragTranslation = CGSize(
        width: worldPoint.x - startWorldPoint.x,
        height: worldPoint.y - startWorldPoint.y
      )
      requestDisplay()
      return
    }

    if let startOffset = mouseDownCameraOffset {
      NSCursor.closedHand.set()
      camera.offset = CGSize(
        width: startOffset.width + viewportPoint.x - startViewportPoint.x,
        height: startOffset.height + viewportPoint.y - startViewportPoint.y
      )
    }
  }

  override func mouseUp(with event: NSEvent) {
    if let sourceID = connectionSourceID,
      let targetID = connectionTargetID
    {
      onConnect?(sourceID, targetID)
    } else if let nodeID = draggedNodeID,
      dragTranslation != .zero
    {
      onMoveNode?(nodeID, dragTranslation)
    }
    resetPointerInteraction()
    finishViewportChange()
    requestDisplay()
  }

  override func mouseMoved(with event: NSEvent) {
    let worldPoint = camera.worldPoint(for: convert(event.locationInWindow, from: nil))
    let nextPort = port(at: worldPoint)
    let nextNode = nextPort == nil ? node(at: worldPoint) : nil
    hoveredPortID = nextPort?.id
    hoveredNodeID = nextNode?.id
    NSCursor.arrow.set()
    requestDisplay()
  }

  override func mouseExited(with event: NSEvent) {
    hoveredNodeID = nil
    hoveredPortID = nil
    NSCursor.arrow.set()
    requestDisplay()
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 {
      updateSelection([])
      return
    }
    super.keyDown(with: event)
  }

  func update(
    scene: RoutingMetalScene,
    selection: Set<RoutingCanvasElementID>,
    configuration: FlowingGraphCanvasConfiguration,
    contentInsets: EdgeInsets
  ) {
    self.scene = scene
    self.selection = selection
    graphConfiguration = configuration
    self.contentInsets = contentInsets
    if let hoveredNodeID, !scene.nodes.contains(where: { $0.id == hoveredNodeID }) {
      self.hoveredNodeID = nil
    }
    if let hoveredPortID, scene.port(id: hoveredPortID) == nil {
      self.hoveredPortID = nil
    }
    requestDisplay()
  }

  func restoreCamera(_ camera: FlowingGraphCanvasMetalCamera) {
    self.camera = camera
  }

  func fitContent() {
    guard bounds.width > 0, bounds.height > 0, !scene.nodes.isEmpty else { return }
    camera.fit(
      scene.contentBounds,
      viewportSize: bounds.size,
      contentInsets: contentInsets,
      padding: Constants.fitPadding,
      maximumZoom: 1.25,
      range: graphConfiguration.canvas.zoomRange
    )
    finishViewportChange()
  }

  override func renderFrame(in view: MTKView) {
    guard bounds.width > 0, bounds.height > 0,
      let descriptor = currentRenderPassDescriptor,
      let drawable = currentDrawable,
      let commandBuffer = commandQueue.makeCommandBuffer(),
      let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
    else {
      return
    }
    frameIndex = (frameIndex + 1) % 3
    inFlightSemaphore.wait()
    let palette = RoutingMetalPalette(isDark: isDarkAppearance)
    let geometry = makeFrameGeometry(palette: palette)
    var uniforms = RoutingMetalUniforms(
      viewportSize: SIMD2(Float(bounds.width), Float(bounds.height)),
      cameraOffset: SIMD2(Float(camera.offset.width), Float(camera.offset.height)),
      backgroundColor: palette.canvas,
      gridColor: palette.grid,
      zoom: Float(camera.zoom),
      padding: .zero
    )

    encoder.setRenderPipelineState(gridPipeline)
    encoder.setFragmentBytes(
      &uniforms,
      length: MemoryLayout<RoutingMetalUniforms>.stride,
      index: 0
    )
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

    drawInstances(
      geometry.triangles,
      buffers: &triangleBuffers,
      pipeline: trianglePipeline,
      encoder: encoder,
      uniforms: &uniforms,
      vertexCount: 3
    )
    drawInstances(
      geometry.shapes,
      buffers: &shapeBuffers,
      pipeline: shapePipeline,
      encoder: encoder,
      uniforms: &uniforms
    )
    if !geometry.atlasItems.isEmpty {
      let buffer = updateBuffer(values: geometry.atlasItems, buffers: &atlasBuffers)
      encoder.setRenderPipelineState(atlasPipeline)
      encoder.setVertexBytes(
        &uniforms,
        length: MemoryLayout<RoutingMetalUniforms>.stride,
        index: 0
      )
      encoder.setVertexBuffer(buffer, offset: 0, index: 1)
      encoder.setFragmentTexture(textAtlas.texture, index: 0)
      encoder.drawPrimitives(
        type: .triangle,
        vertexStart: 0,
        vertexCount: 6,
        instanceCount: geometry.atlasItems.count
      )
    }
    encoder.endEncoding()
    let inFlightSemaphore = inFlightSemaphore
    commandBuffer.addCompletedHandler { _ in
      inFlightSemaphore.signal()
    }
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  private func makeFrameGeometry(palette: RoutingMetalPalette) -> RoutingMetalFrameGeometry {
    frameGeometry.removeAll(keepingCapacity: true)
    for edge in scene.edges {
      append(edge: edge, palette: palette, to: &frameGeometry)
    }
    if let sourceID = connectionSourceID,
      let source = scene.port(id: sourceID),
      let location = connectionLocation
    {
      let target = connectionTargetID.flatMap(scene.port)
      appendConnectionPreview(
        source: translatedPosition(of: source),
        target: target.map(translatedPosition) ?? location,
        isValid: target != nil,
        palette: palette,
        to: &frameGeometry
      )
    }
    for node in nodesInRenderOrder {
      append(node: node, palette: palette, to: &frameGeometry)
    }
    return frameGeometry
  }

  private func append(
    node: RoutingMetalScene.Node,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    let frame = translatedFrame(of: node)
    let isSelected = selection.contains(node.id)
    let isHovered = hoveredNodeID == node.id
    let accent = node.miniMapStyleIndex == 0 ? palette.fern : palette.seafoam
    geometry.shapes.append(
      RoutingMetalShapeInstance(
        rect: frame,
        fill: palette.node,
        border: isSelected ? accent : palette.border,
        cornerRadius: Float(Constants.nodeCornerRadius),
        borderWidth: Float((isSelected ? 2 : 1) / camera.zoom),
        opacity: 1
      )
    )
    if isHovered || isSelected {
      geometry.shapes.append(
        RoutingMetalShapeInstance(
          rect: frame.insetBy(dx: -2 / camera.zoom, dy: -2 / camera.zoom),
          fill: .zero,
          border: accent.withAlpha(isSelected ? 0.24 : 0.12),
          cornerRadius: Float(Constants.nodeCornerRadius + 2 / camera.zoom),
          borderWidth: Float(3 / camera.zoom),
          opacity: 1
        )
      )
    }

    let iconFrame = Constants.iconFrame.offsetBy(dx: frame.minX, dy: frame.minY)
    geometry.shapes.append(
      RoutingMetalShapeInstance(
        rect: iconFrame,
        fill: node.miniMapStyleIndex == 0 ? palette.field : accent.withAlpha(0.12),
        border: .zero,
        cornerRadius: 10,
        borderWidth: 0,
        opacity: 1
      )
    )
    if let applicationURL = node.applicationURL {
      append(
        atlas: textAtlas.applicationIcon(at: applicationURL, size: iconFrame.size),
        centeredIn: iconFrame,
        color: SIMD4(1, 1, 1, 1),
        to: &geometry
      )
    } else {
      append(
        atlas: textAtlas.symbol(node.symbolName, pointSize: 16, weight: .semibold),
        centeredIn: iconFrame,
        color: node.miniMapStyleIndex == 1 ? accent : palette.muted,
        to: &geometry
      )
    }
    append(
      atlas: textAtlas.text(node.title, size: 10, weight: .medium),
      origin: CGPoint(x: frame.minX + 63, y: frame.minY + 14),
      color: palette.muted,
      to: &geometry
    )
    append(
      atlas: textAtlas.text(truncated(node.subtitle, limit: 27), size: 13, weight: .semibold),
      origin: CGPoint(x: frame.minX + 63, y: frame.minY + 31),
      color: palette.ink,
      to: &geometry
    )

    switch node.value {
    case .applicationAudio:
      appendApplicationStatus(
        node: node, frame: frame, accent: accent, palette: palette, to: &geometry)
    case .visualizer:
      appendVisualizer(node: node, frame: frame, accent: accent, palette: palette, to: &geometry)
    }

    for port in node.ports {
      let position = translatedPosition(of: port)
      let diameter = Constants.portDiameter
      let isPortHovered = hoveredPortID == port.id || connectionTargetID == port.id
      let fill = isPortHovered ? accent : palette.control
      geometry.shapes.append(
        RoutingMetalShapeInstance(
          rect: CGRect(
            x: position.x - diameter / 2,
            y: position.y - diameter / 2,
            width: diameter,
            height: diameter
          ),
          fill: fill,
          border: accent,
          cornerRadius: Float(diameter / 2),
          borderWidth: Float(1.5 / camera.zoom),
          opacity: 1
        )
      )
    }
  }

  private func appendApplicationStatus(
    node: RoutingMetalScene.Node,
    frame: CGRect,
    accent: SIMD4<Float>,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    guard let statusText = node.applicationStatusText,
      let statusSymbolName = node.applicationStatusSymbolName
    else {
      return
    }
    let statusFrame = CGRect(
      x: frame.minX + 14,
      y: frame.maxY - 44,
      width: frame.width - 28,
      height: 30
    )
    geometry.shapes.append(
      RoutingMetalShapeInstance(
        rect: statusFrame,
        fill: node.hasApplicationSelection ? palette.field : accent.withAlpha(0.1),
        border: .zero,
        cornerRadius: 8,
        borderWidth: 0,
        opacity: 1
      )
    )
    append(
      atlas: textAtlas.symbol(statusSymbolName, pointSize: 9, weight: .semibold),
      centeredIn: CGRect(
        x: statusFrame.minX + 9,
        y: statusFrame.minY,
        width: 14,
        height: statusFrame.height
      ),
      color: node.hasApplicationSelection ? palette.muted : accent,
      to: &geometry
    )
    if node.supplement.isRunning {
      geometry.shapes.append(
        RoutingMetalShapeInstance(
          rect: CGRect(
            x: iconFrame(for: frame).maxX - 8, y: iconFrame(for: frame).maxY - 8, width: 9,
            height: 9),
          fill: palette.running,
          border: palette.node,
          cornerRadius: 4.5,
          borderWidth: Float(2 / camera.zoom),
          opacity: 1
        )
      )
    }
    append(
      atlas: textAtlas.text(statusText, size: 10, weight: .medium),
      origin: CGPoint(
        x: statusFrame.minX + 25,
        y: statusFrame.midY - 7
      ),
      color: node.hasApplicationSelection ? palette.muted : accent,
      to: &geometry
    )
  }

  private func appendVisualizer(
    node: RoutingMetalScene.Node,
    frame: CGRect,
    accent: SIMD4<Float>,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    let waveformFrame = CGRect(
      x: frame.minX + 14,
      y: frame.maxY - 56,
      width: frame.width - 28,
      height: 42
    )
    geometry.shapes.append(
      RoutingMetalShapeInstance(
        rect: waveformFrame,
        fill: palette.field,
        border: .zero,
        cornerRadius: 8,
        borderWidth: 0,
        opacity: 1
      )
    )
    guard let waveforms = node.supplement.visualizerSignal?.waveforms,
      !waveforms.isEmpty
    else {
      let middle = waveformFrame.midY
      let dashWidth: CGFloat = 3
      let dashGap: CGFloat = 3
      var x = waveformFrame.minX + 9
      while x < waveformFrame.maxX - 9 {
        appendStroke(
          points: [
            CGPoint(x: x, y: middle),
            CGPoint(x: min(x + dashWidth, waveformFrame.maxX - 9), y: middle),
          ],
          width: 1 / camera.zoom,
          color: accent.withAlpha(0.42),
          to: &geometry
        )
        x += dashWidth + dashGap
      }
      let waitingText = textAtlas.text("Waiting for audio", size: 9, weight: .medium)
      if let waitingText {
        let labelFrame = CGRect(
          x: waveformFrame.midX - waitingText.size.width / 2 - 6,
          y: waveformFrame.midY - waitingText.size.height / 2,
          width: waitingText.size.width + 12,
          height: waitingText.size.height
        )
        geometry.shapes.append(
          RoutingMetalShapeInstance(
            rect: labelFrame,
            fill: palette.field,
            border: .zero,
            cornerRadius: 0,
            borderWidth: 0,
            opacity: 1
          )
        )
        append(
          atlas: waitingText,
          centeredIn: labelFrame,
          color: palette.muted.withAlpha(0.72),
          to: &geometry
        )
      }
      return
    }
    let laneHeight = waveformFrame.height / CGFloat(waveforms.count)
    for (laneIndex, samples) in waveforms.enumerated() where samples.count > 1 {
      let middle = waveformFrame.minY + laneHeight * (CGFloat(laneIndex) + 0.5)
      let amplitude = laneHeight * 0.38
      let points = samples.enumerated().map { index, sample in
        CGPoint(
          x: waveformFrame.minX + 8
            + (waveformFrame.width - 16) * CGFloat(index) / CGFloat(samples.count - 1),
          y: middle - CGFloat(sample) * amplitude
        )
      }
      appendStroke(
        points: points,
        width: Constants.waveformWidth / camera.zoom,
        color: accent.withAlpha(laneIndex == 0 ? 0.95 : 0.64),
        to: &geometry
      )
    }
  }

  private func iconFrame(for nodeFrame: CGRect) -> CGRect {
    Constants.iconFrame.offsetBy(dx: nodeFrame.minX, dy: nodeFrame.minY)
  }

  private func append(
    edge: RoutingMetalScene.Edge,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    appendStroke(
      points: points(for: edge.route),
      width: Constants.edgeWidth / camera.zoom,
      color: palette.fern.withAlpha(selection.contains(edge.id) ? 0.9 : 0.58),
      to: &geometry
    )
  }

  private func appendConnectionPreview(
    source: CGPoint,
    target: CGPoint,
    isValid: Bool,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    let distance = max(abs(target.x - source.x) * 0.45, 36)
    let route = FlowingGraphEdgeRoute(
      start: source,
      segments: [
        .cubic(
          control1: CGPoint(x: source.x + distance, y: source.y),
          control2: CGPoint(x: target.x - distance, y: target.y),
          end: target
        )
      ]
    )
    appendStroke(
      points: points(for: route),
      width: Constants.connectionPreviewWidth / camera.zoom,
      color: (isValid ? palette.fern : palette.muted).withAlpha(0.82),
      to: &geometry
    )
  }

  private func appendStroke(
    points: [CGPoint],
    width: CGFloat,
    color: SIMD4<Float>,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    guard points.count > 1 else { return }
    for pair in zip(points, points.dropFirst()) {
      let start = pair.0
      let end = pair.1
      let dx = end.x - start.x
      let dy = end.y - start.y
      let length = max(hypot(dx, dy), .leastNonzeroMagnitude)
      let normal = CGVector(dx: -dy / length * width / 2, dy: dx / length * width / 2)
      let p0 = CGPoint(x: start.x + normal.dx, y: start.y + normal.dy)
      let p1 = CGPoint(x: start.x - normal.dx, y: start.y - normal.dy)
      let p2 = CGPoint(x: end.x + normal.dx, y: end.y + normal.dy)
      let p3 = CGPoint(x: end.x - normal.dx, y: end.y - normal.dy)
      geometry.triangles.append(
        RoutingMetalTriangleInstance(point0: p0, point1: p1, point2: p2, color: color)
      )
      geometry.triangles.append(
        RoutingMetalTriangleInstance(point0: p2, point1: p1, point2: p3, color: color)
      )
    }
  }

  private func points(for route: FlowingGraphEdgeRoute) -> [CGPoint] {
    var result = [route.start]
    var start = route.start
    for segment in route.segments {
      switch segment {
      case .line(let end):
        result.append(end)
        start = end
      case .quadratic(let control, let end):
        for step in 1...12 {
          let t = CGFloat(step) / 12
          let inverse = 1 - t
          result.append(
            CGPoint(
              x: inverse * inverse * start.x + 2 * inverse * t * control.x + t * t * end.x,
              y: inverse * inverse * start.y + 2 * inverse * t * control.y + t * t * end.y
            )
          )
        }
        start = end
      case .cubic(let control1, let control2, let end):
        for step in 1...18 {
          let t = CGFloat(step) / 18
          let inverse = 1 - t
          result.append(
            CGPoint(
              x: inverse * inverse * inverse * start.x
                + 3 * inverse * inverse * t * control1.x
                + 3 * inverse * t * t * control2.x + t * t * t * end.x,
              y: inverse * inverse * inverse * start.y
                + 3 * inverse * inverse * t * control1.y
                + 3 * inverse * t * t * control2.y + t * t * t * end.y
            )
          )
        }
        start = end
      }
    }
    return result
  }

  private func append(
    atlas entry: RoutingMetalAtlasEntry?,
    origin: CGPoint,
    color: SIMD4<Float>,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    guard let entry else { return }
    geometry.atlasItems.append(
      RoutingMetalAtlasInstance(
        origin: SIMD2(Float(origin.x), Float(origin.y)),
        size: SIMD2(Float(entry.size.width), Float(entry.size.height)),
        textureOrigin: entry.textureOrigin,
        textureSize: entry.textureSize,
        color: color,
        opacity: 1
      )
    )
  }

  private func append(
    atlas entry: RoutingMetalAtlasEntry?,
    centeredIn frame: CGRect,
    color: SIMD4<Float>,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    guard let entry else { return }
    append(
      atlas: entry,
      origin: CGPoint(
        x: frame.midX - entry.size.width / 2,
        y: frame.midY - entry.size.height / 2
      ),
      color: color,
      to: &geometry
    )
  }

  private var nodesInRenderOrder: [RoutingMetalScene.Node] {
    scene.nodesInRenderOrder(selection: selection)
  }

  private func node(at point: CGPoint) -> RoutingMetalScene.Node? {
    nodesInRenderOrder.reversed().first { translatedFrame(of: $0).contains(point) }
  }

  private func port(at point: CGPoint) -> RoutingMetalScene.Port? {
    let radius = Constants.portHitRadius / camera.zoom
    for node in nodesInRenderOrder.reversed() {
      for port in node.ports.reversed() {
        let position = translatedPosition(of: port)
        if hypot(position.x - point.x, position.y - point.y) <= radius {
          return port
        }
      }
    }
    return nil
  }

  private func nearestConnectionTarget(
    to point: CGPoint,
    source: RoutingMetalScene.Port
  ) -> RoutingMetalScene.Port? {
    let radius = Constants.portHitRadius * 1.6 / camera.zoom
    return nodesInRenderOrder.reversed().lazy.flatMap(\.ports).filter { target in
      self.scene.validatesConnection(from: source, to: target)
    }.min { first, second in
      self.distance(from: first.position, to: point)
        < self.distance(from: second.position, to: point)
    }.flatMap { candidate in
      self.distance(from: candidate.position, to: point) <= radius ? candidate : nil
    }
  }

  private func translatedFrame(of node: RoutingMetalScene.Node) -> CGRect {
    guard draggedNodeID == node.id else { return node.frame }
    return node.frame.offsetBy(dx: dragTranslation.width, dy: dragTranslation.height)
  }

  private func translatedPosition(of port: RoutingMetalScene.Port) -> CGPoint {
    guard draggedNodeID == port.nodeID else { return port.position }
    return CGPoint(
      x: port.position.x + dragTranslation.width,
      y: port.position.y + dragTranslation.height
    )
  }

  private func updateSelection(_ next: Set<RoutingCanvasElementID>) {
    guard selection != next else { return }
    selection = next
    onSelectionChange?(next)
    requestDisplay()
  }

  private func resetPointerInteraction() {
    mouseDownViewportPoint = nil
    mouseDownWorldPoint = nil
    mouseDownCameraOffset = nil
    draggedNodeID = nil
    dragTranslation = .zero
    connectionSourceID = nil
    connectionLocation = nil
    connectionTargetID = nil
    NSCursor.arrow.set()
  }

  private func requestDisplay() {
    needsDisplay = true
  }

  private func updateClearColor() {
    let palette = RoutingMetalPalette(isDark: isDarkAppearance)
    clearColor = MTLClearColor(
      red: Double(palette.canvas.x),
      green: Double(palette.canvas.y),
      blue: Double(palette.canvas.z),
      alpha: 1
    )
  }

  private var isDarkAppearance: Bool {
    effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }

  private func truncated(_ value: String, limit: Int) -> String {
    guard value.count > limit else { return value }
    return String(value.prefix(max(limit - 1, 1))) + "…"
  }

  private func distance(from first: CGPoint, to second: CGPoint) -> CGFloat {
    hypot(first.x - second.x, first.y - second.y)
  }

  private func drawInstances<T>(
    _ values: [T],
    buffers: inout [any MTLBuffer],
    pipeline: any MTLRenderPipelineState,
    encoder: any MTLRenderCommandEncoder,
    uniforms: inout RoutingMetalUniforms,
    vertexCount: Int = 6
  ) {
    guard !values.isEmpty else { return }
    let buffer = updateBuffer(values: values, buffers: &buffers)
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBytes(
      &uniforms,
      length: MemoryLayout<RoutingMetalUniforms>.stride,
      index: 0
    )
    encoder.setVertexBuffer(buffer, offset: 0, index: 1)
    encoder.drawPrimitives(
      type: .triangle,
      vertexStart: 0,
      vertexCount: vertexCount,
      instanceCount: values.count
    )
  }

  private func updateBuffer<T>(
    values: [T],
    buffers: inout [any MTLBuffer]
  ) -> any MTLBuffer {
    let requiredLength = max(values.count * MemoryLayout<T>.stride, 1)
    if buffers.count != 3 || buffers.contains(where: { $0.length < requiredLength }) {
      guard let device else {
        preconditionFailure("The routing canvas lost its Metal device")
      }
      let capacity = max(requiredLength.nextPowerOfTwo, 256)
      buffers = (0..<3).map { index in
        guard let buffer = device.makeBuffer(length: capacity, options: .storageModeShared) else {
          preconditionFailure("Unable to allocate routing Metal buffer \(index)")
        }
        return buffer
      }
    }
    let buffer = buffers[frameIndex]
    values.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      buffer.contents().copyMemory(from: baseAddress, byteCount: bytes.count)
    }
    return buffer
  }

  private static func makePipeline(
    device: any MTLDevice,
    library: any MTLLibrary,
    vertex: String,
    fragment: String,
    sampleCount: Int,
    blends: Bool = false
  ) throws -> any MTLRenderPipelineState {
    let descriptor = MTLRenderPipelineDescriptor()
    guard let colorAttachment = descriptor.colorAttachments[0] else {
      preconditionFailure("Metal did not provide a primary color attachment")
    }
    descriptor.vertexFunction = library.makeFunction(name: vertex)
    descriptor.fragmentFunction = library.makeFunction(name: fragment)
    colorAttachment.pixelFormat = .bgra8Unorm
    descriptor.rasterSampleCount = sampleCount
    if blends {
      colorAttachment.isBlendingEnabled = true
      colorAttachment.sourceRGBBlendFactor = .sourceAlpha
      colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
      colorAttachment.sourceAlphaBlendFactor = .one
      colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    }
    return try device.makeRenderPipelineState(descriptor: descriptor)
  }

  private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Uniforms {
      float2 viewportSize;
      float2 cameraOffset;
      float4 backgroundColor;
      float4 gridColor;
      float zoom;
      float3 padding;
    };

    struct ShapeInstance {
      float2 origin;
      float2 size;
      float4 fillColor;
      float4 borderColor;
      float cornerRadius;
      float borderWidth;
      float opacity;
      float padding;
    };

    struct TriangleInstance {
      float2 point0;
      float2 point1;
      float2 point2;
      float2 padding;
      float4 color;
    };

    struct AtlasInstance {
      float2 origin;
      float2 size;
      float2 textureOrigin;
      float2 textureSize;
      float4 color;
      float opacity;
      float3 padding;
    };

    struct GridOutput {
      float4 position [[position]];
      float2 viewportPoint;
    };

    struct ShapeOutput {
      float4 position [[position]];
      float2 uv;
      float2 pixelSize;
      float4 fillColor [[flat]];
      float4 borderColor [[flat]];
      float cornerRadius [[flat]];
      float borderWidth [[flat]];
      float opacity [[flat]];
    };

    struct FlatOutput {
      float4 position [[position]];
      float4 color [[flat]];
    };

    struct AtlasOutput {
      float4 position [[position]];
      float2 uv;
      float4 color [[flat]];
      float opacity [[flat]];
    };

    constant float2 quadVertices[6] = {
      float2(0, 0), float2(1, 0), float2(0, 1),
      float2(0, 1), float2(1, 0), float2(1, 1)
    };

    float4 viewportPosition(float2 worldPoint, constant Uniforms &uniforms) {
      float2 viewportPoint = worldPoint * uniforms.zoom + uniforms.cameraOffset;
      return float4(
        viewportPoint.x / uniforms.viewportSize.x * 2 - 1,
        1 - viewportPoint.y / uniforms.viewportSize.y * 2,
        0,
        1
      );
    }

    vertex GridOutput gridVertex(uint vertexID [[vertex_id]]) {
      float2 uv = quadVertices[vertexID];
      GridOutput output;
      output.position = float4(uv.x * 2 - 1, 1 - uv.y * 2, 0, 1);
      output.viewportPoint = uv;
      return output;
    }

    fragment float4 gridFragment(
      GridOutput input [[stage_in]],
      constant Uniforms &uniforms [[buffer(0)]]
    ) {
      float2 viewportPoint = input.viewportPoint * uniforms.viewportSize;
      float2 worldPoint = (viewportPoint - uniforms.cameraOffset) / uniforms.zoom;
      float baseVisualSpacing = max(24.0 * uniforms.zoom, 0.001);
      float levelScale = exp2(ceil(log2(13.0 / baseVisualSpacing)));
      float spacing = 24.0 * levelScale;
      float2 cell = (fract(worldPoint / spacing + 0.5) - 0.5) * spacing * uniforms.zoom;
      float fine = 1.0 - smoothstep(0.55, 1.35, length(cell));
      float2 coarseCell =
        (fract(worldPoint / (spacing * 2.0) + 0.5) - 0.5) * spacing * 2.0 * uniforms.zoom;
      float coarse = 1.0 - smoothstep(0.65, 1.55, length(coarseCell));
      float strength = max(fine * 0.20, coarse * 0.31);
      return float4(mix(uniforms.backgroundColor.rgb, uniforms.gridColor.rgb, strength), 1);
    }

    vertex ShapeOutput shapeVertex(
      uint vertexID [[vertex_id]],
      uint instanceID [[instance_id]],
      constant Uniforms &uniforms [[buffer(0)]],
      constant ShapeInstance *instances [[buffer(1)]]
    ) {
      ShapeInstance instance = instances[instanceID];
      float2 uv = quadVertices[vertexID];
      ShapeOutput output;
      output.position = viewportPosition(instance.origin + uv * instance.size, uniforms);
      output.uv = uv;
      output.pixelSize = max(instance.size * uniforms.zoom, float2(1));
      output.fillColor = instance.fillColor;
      output.borderColor = instance.borderColor;
      output.cornerRadius = instance.cornerRadius * uniforms.zoom;
      output.borderWidth = instance.borderWidth * uniforms.zoom;
      output.opacity = instance.opacity;
      return output;
    }

    fragment float4 shapeFragment(ShapeOutput input [[stage_in]]) {
      float radius = min(input.cornerRadius, min(input.pixelSize.x, input.pixelSize.y) * 0.5);
      float2 point = (input.uv - 0.5) * input.pixelSize;
      float2 bounds = input.pixelSize * 0.5 - radius;
      float2 delta = abs(point) - bounds;
      float distance = length(max(delta, 0.0)) + min(max(delta.x, delta.y), 0.0) - radius;
      float coverage = 1.0 - smoothstep(-0.55, 0.7, distance);
      float border = input.borderWidth > 0
        ? smoothstep(-input.borderWidth - 0.6, -input.borderWidth + 0.35, distance)
        : 0.0;
      float4 color = mix(input.fillColor, input.borderColor, border);
      color.a *= coverage * input.opacity;
      return color;
    }

    vertex FlatOutput triangleVertex(
      uint vertexID [[vertex_id]],
      uint instanceID [[instance_id]],
      constant Uniforms &uniforms [[buffer(0)]],
      constant TriangleInstance *instances [[buffer(1)]]
    ) {
      TriangleInstance instance = instances[instanceID];
      float2 point = vertexID == 0 ? instance.point0 : (vertexID == 1 ? instance.point1 : instance.point2);
      FlatOutput output;
      output.position = viewportPosition(point, uniforms);
      output.color = instance.color;
      return output;
    }

    fragment float4 flatFragment(FlatOutput input [[stage_in]]) {
      return input.color;
    }

    vertex AtlasOutput atlasVertex(
      uint vertexID [[vertex_id]],
      uint instanceID [[instance_id]],
      constant Uniforms &uniforms [[buffer(0)]],
      constant AtlasInstance *instances [[buffer(1)]]
    ) {
      AtlasInstance instance = instances[instanceID];
      float2 corner = quadVertices[vertexID];
      AtlasOutput output;
      output.position = viewportPosition(instance.origin + corner * instance.size, uniforms);
      output.uv = instance.textureOrigin + float2(corner.x, 1 - corner.y) * instance.textureSize;
      output.color = instance.color;
      output.opacity = instance.opacity;
      return output;
    }

    fragment float4 atlasFragment(
      AtlasOutput input [[stage_in]],
      texture2d<float> atlas [[texture(0)]]
    ) {
      constexpr sampler textureSampler(filter::linear, address::clamp_to_edge);
      float4 sample = atlas.sample(textureSampler, input.uv);
      float4 color = sample * input.color;
      color.a *= input.opacity;
      return color;
    }
    """
}

private struct RoutingMetalPalette {
  let canvas: SIMD4<Float>
  let grid: SIMD4<Float>
  let node: SIMD4<Float>
  let control: SIMD4<Float>
  let field: SIMD4<Float>
  let ink: SIMD4<Float>
  let muted: SIMD4<Float>
  let border: SIMD4<Float>
  let fern = SIMD4<Float>(0x58 / 255, 0xA9 / 255, 0x7B / 255, 1)
  let seafoam = SIMD4<Float>(0x4D / 255, 0xA5 / 255, 0xA0 / 255, 1)
  let running = SIMD4<Float>(0.20, 0.72, 0.36, 1)

  init(isDark: Bool) {
    if isDark {
      canvas = SIMD4(0x16 / 255, 0x16 / 255, 0x17 / 255, 1)
      grid = SIMD4(0x8A / 255, 0x8A / 255, 0x84 / 255, 1)
      node = SIMD4(0x23 / 255, 0x23 / 255, 0x26 / 255, 1)
      control = SIMD4(0x2E / 255, 0x2E / 255, 0x31 / 255, 1)
      field = SIMD4(0x2A / 255, 0x2A / 255, 0x2D / 255, 1)
      ink = SIMD4(0xF1 / 255, 0xF1 / 255, 0xEF / 255, 1)
      muted = SIMD4(0x9B / 255, 0x9B / 255, 0x96 / 255, 1)
      border = SIMD4(1, 1, 1, 0.09)
    } else {
      canvas = SIMD4(0xFC / 255, 0xFC / 255, 0xFB / 255, 1)
      grid = SIMD4(0x78 / 255, 0x82 / 255, 0x7D / 255, 1)
      node = SIMD4(1, 1, 1, 1)
      control = SIMD4(1, 1, 1, 1)
      field = SIMD4(0xF2 / 255, 0xF6 / 255, 0xF3 / 255, 1)
      ink = SIMD4(0x1D / 255, 0x1D / 255, 0x1B / 255, 1)
      muted = SIMD4(0x6C / 255, 0x6C / 255, 0x66 / 255, 1)
      border = SIMD4(0, 0, 0, 0.08)
    }
  }
}

private struct RoutingMetalUniforms {
  var viewportSize: SIMD2<Float>
  var cameraOffset: SIMD2<Float>
  var backgroundColor: SIMD4<Float>
  var gridColor: SIMD4<Float>
  var zoom: Float
  var padding: SIMD3<Float>
}

private struct RoutingMetalShapeInstance {
  var origin: SIMD2<Float>
  var size: SIMD2<Float>
  var fillColor: SIMD4<Float>
  var borderColor: SIMD4<Float>
  var cornerRadius: Float
  var borderWidth: Float
  var opacity: Float
  var padding: Float = 0

  init(
    rect: CGRect,
    fill: SIMD4<Float>,
    border: SIMD4<Float>,
    cornerRadius: Float,
    borderWidth: Float,
    opacity: Float
  ) {
    origin = SIMD2(Float(rect.minX), Float(rect.minY))
    size = SIMD2(Float(rect.width), Float(rect.height))
    fillColor = fill
    borderColor = border
    self.cornerRadius = cornerRadius
    self.borderWidth = borderWidth
    self.opacity = opacity
  }
}

private struct RoutingMetalTriangleInstance {
  var point0: SIMD2<Float>
  var point1: SIMD2<Float>
  var point2: SIMD2<Float>
  var padding = SIMD2<Float>.zero
  var color: SIMD4<Float>

  init(point0: CGPoint, point1: CGPoint, point2: CGPoint, color: SIMD4<Float>) {
    self.point0 = SIMD2(Float(point0.x), Float(point0.y))
    self.point1 = SIMD2(Float(point1.x), Float(point1.y))
    self.point2 = SIMD2(Float(point2.x), Float(point2.y))
    self.color = color
  }
}

private struct RoutingMetalAtlasInstance {
  var origin: SIMD2<Float>
  var size: SIMD2<Float>
  var textureOrigin: SIMD2<Float>
  var textureSize: SIMD2<Float>
  var color: SIMD4<Float>
  var opacity: Float
  var padding = SIMD3<Float>.zero
}

private struct RoutingMetalFrameGeometry {
  var shapes: [RoutingMetalShapeInstance] = []
  var triangles: [RoutingMetalTriangleInstance] = []
  var atlasItems: [RoutingMetalAtlasInstance] = []

  mutating func removeAll(keepingCapacity: Bool) {
    shapes.removeAll(keepingCapacity: keepingCapacity)
    triangles.removeAll(keepingCapacity: keepingCapacity)
    atlasItems.removeAll(keepingCapacity: keepingCapacity)
  }
}

extension SIMD4 where Scalar == Float {
  fileprivate func withAlpha(_ alpha: Float) -> Self {
    SIMD4(x, y, z, alpha)
  }
}

extension Int {
  fileprivate var nextPowerOfTwo: Int {
    guard self > 1 else { return 1 }
    return 1 << (Int.bitWidth - (self - 1).leadingZeroBitCount)
  }
}
