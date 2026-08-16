import AppKit
import FlowingDayCanvas
import FlowingDayGraphCanvas
import FlowingDayGraphLayout
import MetalKit
import SwiftUI

@MainActor
final class RoutingMetalCanvasController: FlowingGraphCanvasMetalBackendController {
  @Published private(set) var mouseTool: RoutingCanvasMouseTool = .select
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

  func setMouseTool(_ mouseTool: RoutingCanvasMouseTool) {
    guard self.mouseTool != mouseTool else { return }
    self.mouseTool = mouseTool
    routingCanvas?.setMouseTool(mouseTool)
  }
}

enum RoutingCanvasMouseTool: String, CaseIterable, Hashable, Sendable {
  case select
  case pan
}

struct RoutingMetalCanvas: NSViewRepresentable {
  let scene: RoutingMetalScene
  let selection: Set<RoutingCanvasElementID>
  let configuration: FlowingGraphCanvasConfiguration
  let contentInsets: EdgeInsets
  let controller: RoutingMetalCanvasController
  let mouseTool: RoutingCanvasMouseTool
  let onSelectionChange: (Set<RoutingCanvasElementID>) -> Void
  let onMoveNodes: (Set<RoutingCanvasElementID>, CGSize) -> Void
  let onConnect: (RoutingCanvasElementID, RoutingCanvasElementID) -> Void
  let onDeleteNodes: (Set<UUID>) -> Void
  let onDeleteEdges: (Set<UUID>) -> Void
  let onToggleEdgeEnabled: (UUID) -> Void
  let onTogglePortEnabled: (UUID, RoutingGraphPortID) -> Void
  let onSetAudioChannelGain: (UUID, Int, Double) -> Void
  let onToggleAudioChannelMuted: (UUID, Int) -> Void
  let showsDisabledPortCrosses: Bool
  let onViewportChange: (FlowingCanvasViewport, FlowingCanvasViewportChangePhase) -> Void

  func makeNSView(context: Context) -> RoutingMetalCanvasView {
    let view = RoutingMetalCanvasView(
      scene: scene,
      selection: selection,
      configuration: configuration,
      contentInsets: contentInsets,
      mouseTool: mouseTool,
      showsDisabledPortCrosses: showsDisabledPortCrosses,
      controller: controller
    )
    configure(view)
    controller.attach(view)
    return view
  }

  func updateNSView(_ nsView: RoutingMetalCanvasView, context: Context) {
    configure(nsView)
    nsView.setMouseTool(mouseTool)
    nsView.update(
      scene: scene,
      selection: selection,
      configuration: configuration,
      contentInsets: contentInsets,
      showsDisabledPortCrosses: showsDisabledPortCrosses
    )
    controller.attach(nsView)
  }

  private func configure(_ view: RoutingMetalCanvasView) {
    view.onSelectionChange = onSelectionChange
    view.onMoveNodes = onMoveNodes
    view.onConnect = onConnect
    view.onDeleteNodes = onDeleteNodes
    view.onDeleteEdges = onDeleteEdges
    view.onToggleEdgeEnabled = onToggleEdgeEnabled
    view.onTogglePortEnabled = onTogglePortEnabled
    view.onSetAudioChannelGain = onSetAudioChannelGain
    view.onToggleAudioChannelMuted = onToggleAudioChannelMuted
    view.onViewportChange = onViewportChange
  }
}

@MainActor
final class RoutingMetalCanvasView: FlowingGraphCanvasMetalBackendView {
  var onSelectionChange: ((Set<RoutingCanvasElementID>) -> Void)?
  var onMoveNodes: ((Set<RoutingCanvasElementID>, CGSize) -> Void)?
  var onConnect: ((RoutingCanvasElementID, RoutingCanvasElementID) -> Void)?
  var onDeleteNodes: ((Set<UUID>) -> Void)?
  var onDeleteEdges: ((Set<UUID>) -> Void)?
  var onToggleEdgeEnabled: ((UUID) -> Void)?
  var onTogglePortEnabled: ((UUID, RoutingGraphPortID) -> Void)?
  var onSetAudioChannelGain: ((UUID, Int, Double) -> Void)?
  var onToggleAudioChannelMuted: ((UUID, Int) -> Void)?
  var onViewportChange: ((FlowingCanvasViewport, FlowingCanvasViewportChangePhase) -> Void)?

  private enum Constants {
    static let maximumFramesInFlight = 2
    static let preferredSampleCount = 1
    static let nodeCornerRadius: CGFloat = 16
    static let iconFrame = CGRect(x: 14, y: 14, width: 38, height: 38)
    static let portDiameter: CGFloat = 11
    static let portHitRadius: CGFloat = 13
    static let edgeWidth: CGFloat = 1.6
    static let connectionPreviewWidth: CGFloat = 1.8
    static let edgeLabelMinimumZoom: CGFloat = 0.58
    static let waveformWidth: CGFloat = 2
    static let fitPadding: CGFloat = 58
  }

  private let gridPipeline: any MTLRenderPipelineState
  private let shapePipeline: any MTLRenderPipelineState
  private let trianglePipeline: any MTLRenderPipelineState
  private let atlasPipeline: any MTLRenderPipelineState
  private let textAtlas: RoutingMetalTextAtlas
  private let inFlightSemaphore = DispatchSemaphore(value: Constants.maximumFramesInFlight)

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
  private var hoveredEdgeID: RoutingCanvasElementID?
  private var contextNodeIDs: Set<UUID> = []
  private var contextEdgeID: UUID?
  private var contextPortAddress: RoutingWorkspacePortAddress?
  private var mouseDownViewportPoint: CGPoint?
  private var mouseDownWorldPoint: CGPoint?
  private var mouseDownCameraOffset: CGSize?
  private var draggedNodeIDs: Set<RoutingCanvasElementID> = []
  private var dragTranslation = CGSize.zero
  private var marqueeBaseSelection: Set<RoutingCanvasElementID> = []
  private var marqueeWorldRect: CGRect?
  private var connectionSourceID: RoutingCanvasElementID?
  private var connectionLocation: CGPoint?
  private var connectionTargetID: RoutingCanvasElementID?
  private var audioGainDrag: AudioGainDrag?
  private var mouseTool: RoutingCanvasMouseTool
  private var showsDisabledPortCrosses: Bool

  private struct AudioGainDrag {
    let nodeID: UUID
    let channelIndex: Int
    let trackFrame: CGRect
  }

  private enum AudioChannelControlHit {
    case gain(AudioGainDrag)
    case mute(nodeID: UUID, channelIndex: Int)
  }
  #if PROFILE
    private let profilesAutomaticPan =
      ProcessInfo.processInfo.arguments.contains("--routing-auto-pan")
    private var profilingFrameCount = 0
    private var profilingLastFrameCount = 0
    private var profilingLastTimestamp = ProcessInfo.processInfo.systemUptime
  #endif

  init(
    scene: RoutingMetalScene,
    selection: Set<RoutingCanvasElementID>,
    configuration: FlowingGraphCanvasConfiguration,
    contentInsets: EdgeInsets,
    mouseTool: RoutingCanvasMouseTool,
    showsDisabledPortCrosses: Bool,
    controller: RoutingMetalCanvasController
  ) {
    guard let device = MTLCreateSystemDefaultDevice() else {
      preconditionFailure("Metal is unavailable")
    }
    self.scene = scene
    self.selection = selection
    graphConfiguration = configuration
    self.mouseTool = mouseTool
    self.showsDisabledPortCrosses = showsDisabledPortCrosses
    textAtlas = RoutingMetalTextAtlas(device: device)
    let sampleCount =
      device.supportsTextureSampleCount(Constants.preferredSampleCount)
      ? Constants.preferredSampleCount
      : 1
    do {
      let library = try RoutingMetalShaderLibrary.load(device: device)
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
    focusRingType = .none
    wantsLayer = true
    layer?.zPosition = -1
    (layer as? CAMetalLayer)?.maximumDrawableCount = Constants.maximumFramesInFlight
    colorPixelFormat = .bgra8Unorm
    self.sampleCount = sampleCount
    colorspace = CGColorSpace(name: CGColorSpace.sRGB)
    framebufferOnly = true
    #if PROFILE
      isPaused = !profilesAutomaticPan
      enableSetNeedsDisplay = !profilesAutomaticPan
    #else
      isPaused = true
      enableSetNeedsDisplay = true
    #endif
    updateClearColor()
  }

  @available(*, unavailable)
  required init(coder: NSCoder) {
    fatalError()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard let window else {
      releaseDrawables()
      return
    }
    window.makeFirstResponder(self)
    requestDisplay()
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

    if mouseTool == .pan {
      mouseDownCameraOffset = camera.offset
      NSCursor.closedHand.set()
      return
    }

    if let hit = audioChannelControl(at: worldPoint) {
      switch hit {
      case .gain(let drag):
        audioGainDrag = drag
        onSetAudioChannelGain?(
          drag.nodeID,
          drag.channelIndex,
          RoutingAudioSourceLayout.gainDecibels(at: worldPoint.x, in: drag.trackFrame)
        )
      case .mute(let nodeID, let channelIndex):
        onToggleAudioChannelMuted?(nodeID, channelIndex)
      }
      if let node = scene.nodes.first(where: {
        switch hit {
        case .gain(let drag): $0.workspaceID == drag.nodeID
        case .mute(let nodeID, _): $0.workspaceID == nodeID
        }
      }) {
        updateSelection([node.id])
      }
      return
    }

    if let port = port(at: worldPoint),
      port.value.direction == .output,
      port.value.isEnabled
    {
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
      } else if !selection.contains(node.id) {
        updateSelection([node.id])
      }
      if selection.contains(node.id) {
        let nodeElementIDs = Set(scene.nodes.map(\.id))
        draggedNodeIDs = selection.intersection(nodeElementIDs)
      }
      return
    }

    if let edge = edge(at: worldPoint) {
      let extendsSelection =
        event.modifierFlags.contains(.command)
        || event.modifierFlags.contains(.shift)
      if extendsSelection {
        var next = selection
        if next.contains(edge.id) {
          next.remove(edge.id)
        } else {
          next.insert(edge.id)
        }
        updateSelection(next)
      } else {
        updateSelection([edge.id])
      }
      return
    }

    let extendsSelection =
      event.modifierFlags.contains(.command)
      || event.modifierFlags.contains(.shift)
    marqueeBaseSelection = extendsSelection ? selection : []
    if !extendsSelection {
      updateSelection([])
    }
  }

  override func mouseDragged(with event: NSEvent) {
    guard let startViewportPoint = mouseDownViewportPoint else { return }
    let viewportPoint = convert(event.locationInWindow, from: nil)
    let worldPoint = camera.worldPoint(for: viewportPoint)

    if let audioGainDrag {
      onSetAudioChannelGain?(
        audioGainDrag.nodeID,
        audioGainDrag.channelIndex,
        RoutingAudioSourceLayout.gainDecibels(at: worldPoint.x, in: audioGainDrag.trackFrame)
      )
      return
    }

    if let sourceID = connectionSourceID, let source = scene.port(id: sourceID) {
      connectionLocation = worldPoint
      connectionTargetID = nearestConnectionTarget(to: worldPoint, source: source)?.id
      requestDisplay()
      return
    }

    if !draggedNodeIDs.isEmpty, let startWorldPoint = mouseDownWorldPoint {
      dragTranslation = CGSize(
        width: worldPoint.x - startWorldPoint.x,
        height: worldPoint.y - startWorldPoint.y
      )
      requestDisplay()
      return
    }

    if mouseTool == .pan, let startOffset = mouseDownCameraOffset {
      NSCursor.closedHand.set()
      camera.offset = CGSize(
        width: startOffset.width + viewportPoint.x - startViewportPoint.x,
        height: startOffset.height + viewportPoint.y - startViewportPoint.y
      )
      return
    }

    if mouseTool == .select, let startWorldPoint = mouseDownWorldPoint {
      let rect = CGRect(
        x: min(startWorldPoint.x, worldPoint.x),
        y: min(startWorldPoint.y, worldPoint.y),
        width: abs(worldPoint.x - startWorldPoint.x),
        height: abs(worldPoint.y - startWorldPoint.y)
      )
      marqueeWorldRect = rect
      let edgeIDs = Set(
        scene.edges.lazy.filter {
          RoutingMetalRouteGeometry.intersects($0.route, rectangle: rect)
        }.map(\.id)
      )
      updateSelection(
        marqueeBaseSelection
          .union(scene.nodeIDs(intersecting: rect))
          .union(edgeIDs)
      )
      requestDisplay()
    }
  }

  override func mouseUp(with event: NSEvent) {
    if let sourceID = connectionSourceID,
      let targetID = connectionTargetID
    {
      onConnect?(sourceID, targetID)
    } else if !draggedNodeIDs.isEmpty, dragTranslation != .zero {
      onMoveNodes?(draggedNodeIDs, dragTranslation)
    }
    resetPointerInteraction()
    finishViewportChange()
    requestDisplay()
  }

  override func mouseMoved(with event: NSEvent) {
    if mouseTool == .pan {
      hoveredPortID = nil
      hoveredNodeID = nil
      hoveredEdgeID = nil
      cursorForCurrentTool.set()
      requestDisplay()
      return
    }
    let worldPoint = camera.worldPoint(for: convert(event.locationInWindow, from: nil))
    let nextPort = port(at: worldPoint)
    let nextNode = nextPort == nil ? node(at: worldPoint) : nil
    let nextEdge = nextPort == nil && nextNode == nil ? edge(at: worldPoint) : nil
    hoveredPortID = nextPort?.id
    hoveredNodeID = nextNode?.id
    hoveredEdgeID = nextEdge?.id
    cursorForCurrentTool.set()
    requestDisplay()
  }

  override func mouseExited(with event: NSEvent) {
    hoveredNodeID = nil
    hoveredPortID = nil
    hoveredEdgeID = nil
    cursorForCurrentTool.set()
    requestDisplay()
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 51 || event.keyCode == 117 {
      let nodeIDs = Set(
        scene.nodes.filter { selection.contains($0.id) }.map(\.workspaceID)
      )
      let edgeIDs = Set(
        scene.edges.filter { selection.contains($0.id) }.map(\.workspaceID)
      )
      if !nodeIDs.isEmpty || !edgeIDs.isEmpty {
        onDeleteEdges?(edgeIDs)
        onDeleteNodes?(nodeIDs)
        updateSelection([])
        return
      }
    }
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
    contentInsets: EdgeInsets,
    showsDisabledPortCrosses: Bool
  ) {
    self.scene = scene
    self.selection = selection
    graphConfiguration = configuration
    self.contentInsets = contentInsets
    self.showsDisabledPortCrosses = showsDisabledPortCrosses
    if let hoveredNodeID, !scene.nodes.contains(where: { $0.id == hoveredNodeID }) {
      self.hoveredNodeID = nil
    }
    if let hoveredPortID, scene.port(id: hoveredPortID) == nil {
      self.hoveredPortID = nil
    }
    if let hoveredEdgeID, !scene.edges.contains(where: { $0.id == hoveredEdgeID }) {
      self.hoveredEdgeID = nil
    }
    requestDisplay()
  }

  func setMouseTool(_ mouseTool: RoutingCanvasMouseTool) {
    guard self.mouseTool != mouseTool else { return }
    resetPointerInteraction()
    self.mouseTool = mouseTool
    cursorForCurrentTool.set()
    requestDisplay()
  }

  override func menu(for event: NSEvent) -> NSMenu? {
    let viewportPoint = convert(event.locationInWindow, from: nil)
    let worldPoint = camera.worldPoint(for: viewportPoint)
    if let port = port(at: worldPoint) {
      contextNodeIDs = []
      contextEdgeID = nil
      contextPortAddress = RoutingWorkspacePortAddress(
        nodeID: port.workspaceNodeID,
        portID: port.value.id
      )
      let menu = NSMenu(title: "Port")
      let toggleItem = NSMenuItem(
        title: port.value.isEnabled ? "Disable Port" : "Enable Port",
        action: #selector(toggleContextPort),
        keyEquivalent: ""
      )
      toggleItem.target = self
      menu.addItem(toggleItem)
      return menu
    }
    if let node = node(at: worldPoint) {
      if !selection.contains(node.id) {
        updateSelection([node.id])
      }
      contextNodeIDs = Set(
        scene.nodes
          .filter { selection.contains($0.id) || $0.id == node.id }
          .map(\.workspaceID)
      )
      contextEdgeID = nil
      contextPortAddress = nil

      let menu = NSMenu(title: "Node")
      let deleteItem = NSMenuItem(
        title: contextNodeIDs.count == 1 ? "Delete Node" : "Delete \(contextNodeIDs.count) Nodes",
        action: #selector(deleteContextNode),
        keyEquivalent: ""
      )
      deleteItem.target = self
      menu.addItem(deleteItem)
      return menu
    }
    guard let edge = edge(at: worldPoint) else { return nil }
    updateSelection([edge.id])
    contextNodeIDs = []
    contextPortAddress = nil
    contextEdgeID = edge.workspaceID

    let menu = NSMenu(title: "Connection")
    let toggleItem = NSMenuItem(
      title: edge.isEnabled ? "Disable Connection" : "Enable Connection",
      action: #selector(toggleContextEdge),
      keyEquivalent: ""
    )
    toggleItem.target = self
    menu.addItem(toggleItem)
    menu.addItem(.separator())
    let deleteItem = NSMenuItem(
      title: "Delete Connection",
      action: #selector(deleteContextEdge),
      keyEquivalent: ""
    )
    deleteItem.target = self
    menu.addItem(deleteItem)
    return menu
  }

  @objc private func toggleContextEdge() {
    guard let contextEdgeID else { return }
    onToggleEdgeEnabled?(contextEdgeID)
    self.contextEdgeID = nil
  }

  @objc private func deleteContextNode() {
    guard !contextNodeIDs.isEmpty else { return }
    onDeleteNodes?(contextNodeIDs)
    updateSelection([])
    contextNodeIDs = []
  }

  @objc private func deleteContextEdge() {
    guard let contextEdgeID else { return }
    onDeleteEdges?([contextEdgeID])
    updateSelection([])
    self.contextEdgeID = nil
  }

  @objc private func toggleContextPort() {
    guard let contextPortAddress else { return }
    onTogglePortEnabled?(contextPortAddress.nodeID, contextPortAddress.portID)
    self.contextPortAddress = nil
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
    inFlightSemaphore.wait()
    guard bounds.width > 0, bounds.height > 0,
      let descriptor = currentRenderPassDescriptor,
      let drawable = currentDrawable,
      let commandBuffer = commandQueue.makeCommandBuffer(),
      let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
    else {
      inFlightSemaphore.signal()
      return
    }
    #if PROFILE
      applyProfilingPanIfNeeded()
    #endif
    frameIndex = (frameIndex + 1) % Constants.maximumFramesInFlight
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

    let triangleBuffer = prepareBuffer(values: geometry.triangles, buffers: &triangleBuffers)
    let shapeBuffer = prepareBuffer(values: geometry.shapes, buffers: &shapeBuffers)
    let atlasBuffer = prepareBuffer(values: geometry.atlasItems, buffers: &atlasBuffers)

    if let triangleBuffer {
      drawInstances(
        geometry.backgroundTriangleRange,
        instanceType: RoutingMetalTriangleInstance.self,
        buffer: triangleBuffer,
        pipeline: trianglePipeline,
        encoder: encoder,
        uniforms: &uniforms,
        vertexCount: 3
      )
    }
    if let shapeBuffer {
      drawInstances(
        geometry.backgroundShapeRange,
        instanceType: RoutingMetalShapeInstance.self,
        buffer: shapeBuffer,
        pipeline: shapePipeline,
        encoder: encoder,
        uniforms: &uniforms
      )
    }
    if let atlasBuffer {
      encoder.setFragmentTexture(textAtlas.glyphTexture, index: 0)
      encoder.setFragmentTexture(textAtlas.colorTexture, index: 1)
      drawInstances(
        geometry.backgroundAtlasRange,
        instanceType: RoutingMetalAtlasInstance.self,
        buffer: atlasBuffer,
        pipeline: atlasPipeline,
        encoder: encoder,
        uniforms: &uniforms
      )
    }
    for range in geometry.nodeRanges {
      if let shapeBuffer {
        drawInstances(
          range.shapeRange,
          instanceType: RoutingMetalShapeInstance.self,
          buffer: shapeBuffer,
          pipeline: shapePipeline,
          encoder: encoder,
          uniforms: &uniforms
        )
      }
      if let triangleBuffer {
        drawInstances(
          range.triangleRange,
          instanceType: RoutingMetalTriangleInstance.self,
          buffer: triangleBuffer,
          pipeline: trianglePipeline,
          encoder: encoder,
          uniforms: &uniforms,
          vertexCount: 3
        )
      }
      if let atlasBuffer {
        encoder.setFragmentTexture(textAtlas.glyphTexture, index: 0)
        encoder.setFragmentTexture(textAtlas.colorTexture, index: 1)
        drawInstances(
          range.atlasRange,
          instanceType: RoutingMetalAtlasInstance.self,
          buffer: atlasBuffer,
          pipeline: atlasPipeline,
          encoder: encoder,
          uniforms: &uniforms
        )
      }
    }
    encoder.endEncoding()
    let inFlightSemaphore = inFlightSemaphore
    commandBuffer.addCompletedHandler { _ in
      inFlightSemaphore.signal()
    }
    commandBuffer.present(drawable)
    commandBuffer.commit()
    #if PROFILE
      recordProfilingFrame(geometry: geometry)
    #endif
  }

  private func makeFrameGeometry(palette: RoutingMetalPalette) -> RoutingMetalFrameGeometry {
    textAtlas.beginFrame()
    frameGeometry.removeAll(keepingCapacity: true)
    let visibleRect = camera.visibleWorldRect(
      viewportSize: bounds.size,
      contentInsets: contentInsets,
      overscan: 96
    )
    let visibleElements = scene.renderElements(
      intersecting: visibleRect,
      selection: selection
    )
    for edge in visibleElements.edges {
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
    if let marqueeWorldRect, marqueeWorldRect.width > 0, marqueeWorldRect.height > 0 {
      appendMarquee(marqueeWorldRect, palette: palette, to: &frameGeometry)
    }
    frameGeometry.backgroundTriangleRange = frameGeometry.triangles.indices
    frameGeometry.backgroundShapeRange = frameGeometry.shapes.indices
    frameGeometry.backgroundAtlasRange = frameGeometry.atlasItems.indices
    for node in visibleElements.nodes {
      let shapeStart = frameGeometry.shapes.endIndex
      let triangleStart = frameGeometry.triangles.endIndex
      let atlasStart = frameGeometry.atlasItems.endIndex
      append(node: node, palette: palette, to: &frameGeometry)
      frameGeometry.nodeRanges.append(
        RoutingMetalNodeRange(
          shapeRange: shapeStart..<frameGeometry.shapes.endIndex,
          triangleRange: triangleStart..<frameGeometry.triangles.endIndex,
          atlasRange: atlasStart..<frameGeometry.atlasItems.endIndex
        )
      )
    }
    return frameGeometry
  }

  #if PROFILE
    private func applyProfilingPanIfNeeded() {
      guard profilesAutomaticPan else { return }
      let contentBounds = scene.contentBounds
      guard !contentBounds.isEmpty, camera.zoom > 0 else { return }
      let visibleSize = CGSize(
        width: bounds.width / camera.zoom,
        height: bounds.height / camera.zoom
      )
      let horizontalTravel = max(contentBounds.width - visibleSize.width, 0)
      let verticalTravel = max(contentBounds.height - visibleSize.height, 0)
      let minimumCenter = CGPoint(
        x: contentBounds.minX + min(visibleSize.width, contentBounds.width) / 2,
        y: contentBounds.minY + min(visibleSize.height, contentBounds.height) / 2
      )
      let phase = ProcessInfo.processInfo.systemUptime * 1.4
      let center = CGPoint(
        x: minimumCenter.x + (sin(phase) + 1) * horizontalTravel / 2,
        y: minimumCenter.y + (cos(phase * 0.73) + 1) * verticalTravel / 2
      )
      camera.offset = CGSize(
        width: bounds.midX - center.x * camera.zoom,
        height: bounds.midY - center.y * camera.zoom
      )
    }

    private func recordProfilingFrame(geometry: RoutingMetalFrameGeometry) {
      profilingFrameCount += 1
      let now = ProcessInfo.processInfo.systemUptime
      let interval = now - profilingLastTimestamp
      guard interval >= 1 else { return }
      let intervalFrameCount = profilingFrameCount - profilingLastFrameCount
      let achievedFramesPerSecond = Double(intervalFrameCount) / interval
      let dynamicBufferBytes =
        shapeBuffers.reduce(0) { $0 + $1.length }
        + triangleBuffers.reduce(0) { $0 + $1.length }
        + atlasBuffers.reduce(0) { $0 + $1.length }
      let maximumDrawableCount = (layer as? CAMetalLayer)?.maximumDrawableCount ?? 0
      let line =
        "PROFILE_RENDERER bounds=\(Int(bounds.width))x\(Int(bounds.height)) "
        + "drawable=\(Int(drawableSize.width))x\(Int(drawableSize.height)) "
        + "scale=\(String(format: "%.2f", window?.backingScaleFactor ?? 0)) "
        + "sampleCount=\(sampleCount) maximumDrawableCount=\(maximumDrawableCount) "
        + "requestedFPS=\(preferredFramesPerSecond) "
        + "achievedFPS=\(String(format: "%.1f", achievedFramesPerSecond)) "
        + "visibleShapes=\(geometry.shapes.count) visibleTriangles=\(geometry.triangles.count) "
        + "visibleAtlasItems=\(geometry.atlasItems.count) dynamicBufferBytes=\(dynamicBufferBytes)"
      FileHandle.standardError.write(Data("\(line)\n".utf8))
      profilingLastTimestamp = now
      profilingLastFrameCount = profilingFrameCount
    }
  #endif

  private func append(
    node: RoutingMetalScene.Node,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    let frame = translatedFrame(of: node)
    let isSelected = selection.contains(node.id)
    let isHovered = hoveredNodeID == node.id
    let accent = accent(for: node)
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
    if node.drawsIconPlate {
      geometry.shapes.append(
        RoutingMetalShapeInstance(
          rect: iconFrame,
          fill: node.usesNeutralPlaceholderIcon ? palette.field : accent.withAlpha(0.12),
          border: .zero,
          cornerRadius: 10,
          borderWidth: 0,
          opacity: 1
        )
      )
    }
    if let applicationURL = node.applicationURL,
      let applicationIcon = node.supplement.applicationIcon
    {
      append(
        atlas: textAtlas.applicationIcon(
          applicationIcon,
          applicationURL: applicationURL,
          size: iconFrame.size
        ),
        centeredIn: iconFrame,
        color: SIMD4(1, 1, 1, 1),
        to: &geometry
      )
    } else {
      append(
        atlas: textAtlas.symbol(node.symbolName, pointSize: 16, weight: .semibold),
        centeredIn: iconFrame,
        color: node.usesNeutralPlaceholderIcon ? palette.muted : accent,
        to: &geometry
      )
    }
    if node.supplement.isRunning {
      geometry.shapes.append(
        RoutingMetalShapeInstance(
          rect: CGRect(
            x: iconFrame.maxX - 8,
            y: iconFrame.maxY - 8,
            width: 9,
            height: 9
          ),
          fill: palette.running,
          border: palette.node,
          cornerRadius: 4.5,
          borderWidth: Float(2 / camera.zoom),
          opacity: 1
        )
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
    case .applicationAudio, .inputAudio, .outputAudio:
      appendAudioSource(
        node: node, frame: frame, accent: accent, palette: palette, to: &geometry)
    case .visualizer:
      appendVisualizer(node: node, frame: frame, accent: accent, palette: palette, to: &geometry)
    case .audioMixer:
      appendAudioMixer(node: node, frame: frame, accent: accent, palette: palette, to: &geometry)
    case .gain:
      appendGain(node: node, frame: frame, accent: accent, palette: palette, to: &geometry)
    case .channelRouter:
      appendChannelRouter(
        node: node,
        frame: frame,
        accent: accent,
        palette: palette,
        to: &geometry
      )
    case .peakLevel:
      appendPeakLevel(node: node, frame: frame, accent: accent, palette: palette, to: &geometry)
    case .signalGenerator:
      appendSignalGenerator(
        node: node,
        frame: frame,
        accent: accent,
        palette: palette,
        to: &geometry
      )
    case .filePlayback:
      appendFilePlayback(
        node: node,
        frame: frame,
        accent: accent,
        palette: palette,
        to: &geometry
      )
    case .fileOutput:
      appendFileOutput(
        node: node,
        frame: frame,
        accent: accent,
        palette: palette,
        to: &geometry
      )
    case .networkSend, .networkReceive:
      appendNetworkAudio(
        node: node,
        frame: frame,
        accent: accent,
        palette: palette,
        to: &geometry
      )
    case .delay:
      appendDelay(
        node: node,
        frame: frame,
        accent: accent,
        palette: palette,
        to: &geometry
      )
    case .noiseGate:
      appendNoiseGate(
        node: node,
        frame: frame,
        accent: accent,
        palette: palette,
        to: &geometry
      )
    case .compressor:
      appendCompressor(
        node: node,
        frame: frame,
        accent: accent,
        palette: palette,
        to: &geometry
      )
    }

    for port in node.ports {
      let position = translatedPosition(of: port)
      let diameter = Constants.portDiameter
      let isPortHovered = hoveredPortID == port.id || connectionTargetID == port.id
      let portAccent = port.value.isEnabled ? accent : palette.muted.withAlpha(0.52)
      let fill =
        port.value.isEnabled && isPortHovered
        ? accent
        : palette.control.withAlpha(port.value.isEnabled ? 1 : 0.56)
      geometry.shapes.append(
        RoutingMetalShapeInstance(
          rect: CGRect(
            x: position.x - diameter / 2,
            y: position.y - diameter / 2,
            width: diameter,
            height: diameter
          ),
          fill: fill,
          border: portAccent,
          cornerRadius: Float(diameter / 2),
          borderWidth: Float(1.5 / camera.zoom),
          opacity: 1
        )
      )
      if !node.embedsPortLabels {
        appendPortLabel(
          port.value,
          at: position,
          palette: palette,
          to: &geometry
        )
      }
      if !port.value.isEnabled, showsDisabledPortCrosses {
        let radius: CGFloat = 2.2
        appendRoundStroke(
          points: [
            CGPoint(x: position.x - radius, y: position.y - radius),
            CGPoint(x: position.x + radius, y: position.y + radius),
          ],
          width: 1.25 / camera.zoom,
          color: palette.muted.withAlpha(0.84),
          to: &geometry
        )
        appendRoundStroke(
          points: [
            CGPoint(x: position.x - radius, y: position.y + radius),
            CGPoint(x: position.x + radius, y: position.y - radius),
          ],
          width: 1.25 / camera.zoom,
          color: palette.muted.withAlpha(0.84),
          to: &geometry
        )
      }
    }
  }

  private func appendPortLabel(
    _ port: RoutingGraphPortValue,
    at position: CGPoint,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    guard
      let entry = textAtlas.monospacedText(port.shortLabel, size: 8, weight: .semibold)
    else {
      return
    }
    let gap: CGFloat = 9
    let originX =
      port.direction == .input
      ? position.x + gap
      : position.x - gap - entry.size.width
    append(
      atlas: entry,
      origin: CGPoint(x: originX, y: position.y - entry.size.height / 2),
      color: palette.muted.withAlpha(0.76),
      to: &geometry
    )
  }

  private func appendAudioSource(
    node: RoutingMetalScene.Node,
    frame: CGRect,
    accent: SIMD4<Float>,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    if case .some(.separate(let channelCount)) = node.value.audioSourceChannelPresentation,
      node.hasAudioSourceSelection
    {
      appendAudioSourceMeters(
        node: node,
        frame: frame,
        channelCount: channelCount,
        accent: accent,
        palette: palette,
        to: &geometry
      )
      return
    }
    guard
      let statusText =
        node.applicationStatusText ?? node.inputDeviceStatusText ?? node.outputDeviceStatusText,
      let statusSymbolName =
        node.applicationStatusSymbolName ?? node.inputDeviceStatusSymbolName
        ?? node.outputDeviceStatusSymbolName
    else {
      return
    }
    let statusFrame = RoutingAudioSourceStatusLayout.frame(
      in: frame,
      hasInputPort: node.ports.contains { $0.value.direction == .input },
      hasOutputPort: node.ports.contains { $0.value.direction == .output }
    )
    geometry.shapes.append(
      RoutingMetalShapeInstance(
        rect: statusFrame,
        fill: node.hasAudioSourceSelection ? palette.field : accent.withAlpha(0.1),
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
      color: node.hasAudioSourceSelection ? palette.muted : accent,
      to: &geometry
    )
    append(
      atlas: textAtlas.text(statusText, size: 10, weight: .medium),
      origin: CGPoint(
        x: statusFrame.minX + 25,
        y: statusFrame.midY - 7
      ),
      color: node.hasAudioSourceSelection ? palette.muted : accent,
      to: &geometry
    )
  }

  private func appendAudioSourceMeters(
    node: RoutingMetalScene.Node,
    frame: CGRect,
    channelCount: Int,
    accent: SIMD4<Float>,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    let rows = RoutingAudioSourceLayout.rowFrames(
      in: frame,
      channelCount: channelCount
    )
    appendAudioChannelControls(
      node: node,
      rows: rows,
      channelCount: channelCount,
      accent: accent,
      palette: palette,
      to: &geometry
    )
  }

  private func appendAudioMixer(
    node: RoutingMetalScene.Node,
    frame: CGRect,
    accent: SIMD4<Float>,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    guard case .audioMixer(let configuration) = node.value else { return }
    appendAudioChannelControls(
      node: node,
      rows: RoutingAudioMixerLayout.rowFrames(
        in: frame,
        channelCount: configuration.channelCount
      ),
      channelCount: configuration.channelCount,
      accent: accent,
      palette: palette,
      to: &geometry
    )
  }

  private func appendAudioChannelControls(
    node: RoutingMetalScene.Node,
    rows: [CGRect],
    channelCount: Int,
    accent: SIMD4<Float>,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    let metersByChannel = Dictionary(
      uniqueKeysWithValues: node.supplement.audioSourceMeters.map { ($0.channelIndex, $0) }
    )
    for (channelIndex, row) in rows.enumerated() {
      let label =
        channelIndex == 0 && channelCount == 2
        ? "L"
        : channelIndex == 1 && channelCount == 2 ? "R" : "Ch \(channelIndex + 1)"
      append(
        atlas: textAtlas.monospacedText(label, size: 8.5, weight: .semibold),
        origin: CGPoint(x: row.minX, y: row.midY - 6),
        color: palette.muted.withAlpha(0.82),
        to: &geometry
      )
      let meter = metersByChannel[channelIndex]
      let control = node.supplement.audioChannelControls[channelIndex] ?? .unity
      let meterFrame = RoutingAudioSourceLayout.gainTrackFrame(in: row)
      geometry.shapes.append(
        RoutingMetalShapeInstance(
          rect: meterFrame,
          fill: palette.field,
          border: .zero,
          cornerRadius: 4,
          borderWidth: 0,
          opacity: 1
        )
      )
      let normalizedLevel = CGFloat(meter?.normalizedLevel ?? 0)
      if normalizedLevel > 0 {
        geometry.shapes.append(
          RoutingMetalShapeInstance(
            rect: CGRect(
              x: meterFrame.minX,
              y: meterFrame.minY,
              width: meterFrame.width * normalizedLevel,
              height: meterFrame.height
            ),
            fill: meter?.isClipping == true
              ? palette.poppy.withAlpha(control.isMuted ? 0.28 : 1)
              : accent.withAlpha(control.isMuted ? 0.22 : 0.88),
            border: .zero,
            cornerRadius: 4,
            borderWidth: 0,
            opacity: 1
          )
        )
      }
      let knobDiameter: CGFloat = 8
      let knobCenterX =
        meterFrame.minX
        + meterFrame.width * RoutingAudioSourceLayout.gainFraction(for: control.gainDecibels)
      geometry.shapes.append(
        RoutingMetalShapeInstance(
          rect: CGRect(
            x: knobCenterX - knobDiameter / 2,
            y: meterFrame.midY - knobDiameter / 2,
            width: knobDiameter,
            height: knobDiameter
          ),
          fill: control.isMuted ? palette.muted.withAlpha(0.55) : accent,
          border: palette.canvas.withAlpha(0.9),
          cornerRadius: Float(knobDiameter / 2),
          borderWidth: 1,
          opacity: 1
        )
      )
      let gainDescription = control.gainDescription
      let gainSize = dynamicMonospacedTextSize(gainDescription, size: 7, weight: .medium)
      let gainFrame = RoutingAudioSourceLayout.gainValueFrame(in: row)
      appendDynamicMonospacedText(
        gainDescription,
        size: 7,
        weight: .medium,
        origin: CGPoint(
          x: gainFrame.maxX - gainSize.width,
          y: row.midY - gainSize.height / 2
        ),
        color: control.isMuted ? palette.muted.withAlpha(0.48) : palette.muted,
        to: &geometry
      )
      let muteFrame = RoutingAudioSourceLayout.muteButtonFrame(in: row)
      geometry.shapes.append(
        RoutingMetalShapeInstance(
          rect: muteFrame,
          fill: control.isMuted ? accent.withAlpha(0.13) : .zero,
          border: .zero,
          cornerRadius: 6,
          borderWidth: 0,
          opacity: 1
        )
      )
      append(
        atlas: textAtlas.symbol(
          control.isMuted ? "speaker.slash.fill" : "speaker.wave.1",
          pointSize: 7.5,
          weight: .semibold
        ),
        centeredIn: muteFrame,
        color: control.isMuted ? accent : palette.muted.withAlpha(0.7),
        to: &geometry
      )
    }
  }

  private func appendGain(
    node: RoutingMetalScene.Node,
    frame: CGRect,
    accent: SIMD4<Float>,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    guard case .gain(let configuration) = node.value else { return }
    let valueFrame = CGRect(
      x: frame.minX + RoutingVisualizerLayout.horizontalInset
        + RoutingVisualizerLayout.portLabelGutter,
      y: frame.maxY - 48,
      width: frame.width - 2 * RoutingVisualizerLayout.horizontalInset
        - 2 * RoutingVisualizerLayout.portLabelGutter,
      height: 34
    )
    geometry.shapes.append(
      RoutingMetalShapeInstance(
        rect: valueFrame,
        fill: accent.withAlpha(configuration.isMuted ? 0.04 : 0.09),
        border: .zero,
        cornerRadius: 8,
        borderWidth: 0,
        opacity: 1
      )
    )
    let label = configuration.isMuted ? "Muted" : configuration.gainDescription
    append(
      atlas: textAtlas.monospacedText(label, size: 10, weight: .semibold),
      origin: CGPoint(x: valueFrame.minX + 11, y: valueFrame.midY - 7),
      color: configuration.isMuted ? palette.muted.withAlpha(0.54) : palette.muted,
      to: &geometry
    )
    if configuration.isPolarityInverted {
      append(
        atlas: textAtlas.text("Ø", size: 11, weight: .semibold),
        origin: CGPoint(x: valueFrame.maxX - 23, y: valueFrame.midY - 8),
        color: accent,
        to: &geometry
      )
    }
  }

  private func appendChannelRouter(
    node: RoutingMetalScene.Node,
    frame: CGRect,
    accent: SIMD4<Float>,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    guard case .channelRouter(let configuration) = node.value else { return }
    let rowCount = max(configuration.inputChannelCount, configuration.outputChannelCount)
    let rows = RoutingAudioMixerLayout.rowFrames(in: frame, channelCount: rowCount)
    let routeStartX = frame.minX + 52
    let routeEndX = frame.maxX - 52
    let routeMidX = frame.midX

    for inputChannel in 0..<configuration.inputChannelCount
    where rows.indices.contains(inputChannel) {
      append(
        atlas: textAtlas.monospacedText("In \(inputChannel + 1)", size: 8, weight: .semibold),
        origin: CGPoint(x: frame.minX + 15, y: rows[inputChannel].midY - 6),
        color: palette.muted.withAlpha(0.82),
        to: &geometry
      )
    }
    for outputChannel in 0..<configuration.outputChannelCount
    where rows.indices.contains(outputChannel) {
      let label = "Out \(outputChannel + 1)"
      if let entry = textAtlas.monospacedText(label, size: 8, weight: .semibold) {
        append(
          atlas: entry,
          origin: CGPoint(x: frame.maxX - 15 - entry.size.width, y: rows[outputChannel].midY - 6),
          color: palette.muted.withAlpha(0.82),
          to: &geometry
        )
      }
      guard let sourceChannel = configuration.outputSources[outputChannel],
        rows.indices.contains(sourceChannel)
      else { continue }
      appendRoundStroke(
        points: [
          CGPoint(x: routeStartX, y: rows[sourceChannel].midY),
          CGPoint(x: routeMidX, y: rows[sourceChannel].midY),
          CGPoint(x: routeMidX, y: rows[outputChannel].midY),
          CGPoint(x: routeEndX, y: rows[outputChannel].midY),
        ],
        width: 1.6 / camera.zoom,
        color: accent.withAlpha(0.72),
        to: &geometry
      )
    }
  }

  private func appendVisualizer(
    node: RoutingMetalScene.Node,
    frame: CGRect,
    accent: SIMD4<Float>,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    guard case .visualizer(let configuration) = node.value else { return }
    let presentation = RoutingMetalVisualizerPresentation(
      signal: node.supplement.visualizerSignal
    )
    guard case .waveform(let lanes) = presentation else {
      append(
        atlas: textAtlas.text(
          RoutingMetalVisualizerPresentation.waitingMessage,
          size: 10,
          weight: .medium
        ),
        centeredIn: RoutingVisualizerLayout.waitingFrame(
          in: frame,
          configuration: configuration
        ),
        color: palette.muted.withAlpha(0.72),
        to: &geometry
      )
      return
    }
    let frames = RoutingVisualizerLayout.laneFrames(
      in: frame,
      configuration: configuration
    )
    for (lane, laneFrame) in zip(lanes, frames) {
      geometry.shapes.append(
        RoutingMetalShapeInstance(
          rect: laneFrame,
          fill: palette.field,
          border: .zero,
          cornerRadius: 8,
          borderWidth: 0,
          opacity: 1
        )
      )
      let samples = RoutingWaveformDisplayTransform.normalizedSamples(lane.samples)
      guard samples.count > 1 else { continue }
      let middle = laneFrame.midY
      let amplitude = laneFrame.height * 0.42
      let points = samples.enumerated().map { index, sample in
        CGPoint(
          x: laneFrame.minX + 8
            + (laneFrame.width - 16) * CGFloat(index)
              / CGFloat(samples.count - 1),
          y: middle - CGFloat(sample) * amplitude
        )
      }
      appendRoundStroke(
        points: points,
        width: Constants.waveformWidth / camera.zoom,
        color: accent.withAlpha(0.92),
        to: &geometry
      )
    }
  }

  private func appendPeakLevel(
    node: RoutingMetalScene.Node,
    frame: CGRect,
    accent: SIMD4<Float>,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    let valueFrame = CGRect(
      x: frame.minX + RoutingVisualizerLayout.horizontalInset
        + RoutingVisualizerLayout.portLabelGutter,
      y: frame.maxY - 54,
      width: frame.width
        - 2 * (RoutingVisualizerLayout.horizontalInset + RoutingVisualizerLayout.portLabelGutter),
      height: 40
    )
    geometry.shapes.append(
      RoutingMetalShapeInstance(
        rect: valueFrame,
        fill: palette.field,
        border: .zero,
        cornerRadius: 8,
        borderWidth: 0,
        opacity: 1
      )
    )
    guard let signal = node.supplement.peakLevelSignal else {
      append(
        atlas: textAtlas.text("Waiting for audio input", size: 10, weight: .medium),
        centeredIn: valueFrame,
        color: palette.muted.withAlpha(0.72),
        to: &geometry
      )
      return
    }
    appendDynamicMonospacedText(
      signal.linearDescription,
      size: 16,
      weight: .semibold,
      origin: CGPoint(x: valueFrame.minX + 12, y: valueFrame.midY - 10),
      color: signal.isClipping ? palette.poppy : palette.ink,
      to: &geometry
    )
    let decibelSize = dynamicMonospacedTextSize(
      signal.decibelsDescription,
      size: 9,
      weight: .medium
    )
    appendDynamicMonospacedText(
      signal.decibelsDescription,
      size: 9,
      weight: .medium,
      origin: CGPoint(
        x: valueFrame.maxX - 12 - decibelSize.width,
        y: valueFrame.midY - decibelSize.height / 2
      ),
      color: palette.muted,
      to: &geometry
    )
  }

  private func appendSignalGenerator(
    node: RoutingMetalScene.Node,
    frame: CGRect,
    accent: SIMD4<Float>,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    guard case .signalGenerator(let configuration) = node.value else { return }
    let valueFrame = CGRect(
      x: frame.minX + RoutingVisualizerLayout.horizontalInset,
      y: frame.maxY - 48,
      width: frame.width - 2 * RoutingVisualizerLayout.horizontalInset
        - RoutingVisualizerLayout.portLabelGutter,
      height: 34
    )
    geometry.shapes.append(
      RoutingMetalShapeInstance(
        rect: valueFrame,
        fill: accent.withAlpha(0.09),
        border: .zero,
        cornerRadius: 8,
        borderWidth: 0,
        opacity: 1
      )
    )
    let amplitude = Int((configuration.amplitude * 100).rounded())
    append(
      atlas: textAtlas.text("\(amplitude)% amplitude", size: 10, weight: .medium),
      origin: CGPoint(x: valueFrame.minX + 11, y: valueFrame.midY - 7),
      color: palette.muted,
      to: &geometry
    )
  }

  private func appendFilePlayback(
    node: RoutingMetalScene.Node,
    frame: CGRect,
    accent: SIMD4<Float>,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    guard case .filePlayback(let configuration) = node.value else { return }
    let valueFrame = CGRect(
      x: frame.minX + RoutingVisualizerLayout.horizontalInset,
      y: frame.maxY - 48,
      width: frame.width - 2 * RoutingVisualizerLayout.horizontalInset
        - RoutingVisualizerLayout.portLabelGutter,
      height: 34
    )
    geometry.shapes.append(
      RoutingMetalShapeInstance(
        rect: valueFrame,
        fill: accent.withAlpha(0.09),
        border: .zero,
        cornerRadius: 8,
        borderWidth: 0,
        opacity: 1
      )
    )
    let detail: String
    if let selection = configuration.selection {
      detail = "\(selection.channelCount) ch · \(configuration.loopMode.description)"
    } else {
      detail = "Select this node to configure"
    }
    append(
      atlas: textAtlas.text(detail, size: 10, weight: .medium),
      origin: CGPoint(x: valueFrame.minX + 11, y: valueFrame.midY - 7),
      color: palette.muted,
      to: &geometry
    )
  }

  private func appendFileOutput(
    node: RoutingMetalScene.Node,
    frame: CGRect,
    accent: SIMD4<Float>,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    guard case .fileOutput(let configuration) = node.value else { return }
    let valueFrame = CGRect(
      x: frame.minX + RoutingVisualizerLayout.horizontalInset
        + RoutingVisualizerLayout.portLabelGutter,
      y: frame.maxY - 48,
      width: frame.width - 2 * RoutingVisualizerLayout.horizontalInset
        - RoutingVisualizerLayout.portLabelGutter,
      height: 34
    )
    geometry.shapes.append(
      RoutingMetalShapeInstance(
        rect: valueFrame,
        fill: accent.withAlpha(0.09),
        border: .zero,
        cornerRadius: 8,
        borderWidth: 0,
        opacity: 1
      )
    )
    append(
      atlas: textAtlas.text(configuration.formatDescription, size: 10, weight: .medium),
      origin: CGPoint(x: valueFrame.minX + 11, y: valueFrame.midY - 7),
      color: palette.muted,
      to: &geometry
    )
  }

  private func appendNetworkAudio(
    node: RoutingMetalScene.Node,
    frame: CGRect,
    accent: SIMD4<Float>,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    let sampleRate: Double
    let channelCount: Int
    switch node.value {
    case .networkSend(let configuration):
      sampleRate = configuration.sampleRate
      channelCount = configuration.channelCount
    case .networkReceive(let configuration):
      sampleRate = configuration.sampleRate
      channelCount = configuration.channelCount
    default:
      return
    }
    let valueFrame = CGRect(
      x: frame.minX + RoutingVisualizerLayout.horizontalInset
        + RoutingVisualizerLayout.portLabelGutter,
      y: frame.maxY - 48,
      width: frame.width - 2 * RoutingVisualizerLayout.horizontalInset
        - 2 * RoutingVisualizerLayout.portLabelGutter,
      height: 34
    )
    geometry.shapes.append(
      RoutingMetalShapeInstance(
        rect: valueFrame,
        fill: accent.withAlpha(0.09),
        border: .zero,
        cornerRadius: 8,
        borderWidth: 0,
        opacity: 1
      )
    )
    let kilohertz = sampleRate / 1_000
    let detail =
      "\(channelCount) ch · "
      + kilohertz.formatted(
        .number.precision(.fractionLength(kilohertz == kilohertz.rounded() ? 0 : 1)))
      + " kHz"
    append(
      atlas: textAtlas.text(detail, size: 10, weight: .medium),
      origin: CGPoint(x: valueFrame.minX + 11, y: valueFrame.midY - 7),
      color: palette.muted,
      to: &geometry
    )
  }

  private func appendDelay(
    node: RoutingMetalScene.Node,
    frame: CGRect,
    accent: SIMD4<Float>,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    guard case .delay(let configuration) = node.value else { return }
    let valueFrame = CGRect(
      x: frame.minX + RoutingVisualizerLayout.horizontalInset
        + RoutingVisualizerLayout.portLabelGutter,
      y: frame.maxY - 48,
      width: frame.width - 2 * RoutingVisualizerLayout.horizontalInset
        - 2 * RoutingVisualizerLayout.portLabelGutter,
      height: 34
    )
    geometry.shapes.append(
      RoutingMetalShapeInstance(
        rect: valueFrame,
        fill: accent.withAlpha(0.09),
        border: .zero,
        cornerRadius: 8,
        borderWidth: 0,
        opacity: 1
      )
    )
    let wet = Int((configuration.dryWetMix * 100).rounded())
    append(
      atlas: textAtlas.text("\(wet)% wet", size: 10, weight: .medium),
      origin: CGPoint(x: valueFrame.minX + 11, y: valueFrame.midY - 7),
      color: palette.muted,
      to: &geometry
    )
  }

  private func appendNoiseGate(
    node: RoutingMetalScene.Node,
    frame: CGRect,
    accent: SIMD4<Float>,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    guard case .noiseGate(let configuration) = node.value else { return }
    let valueFrame = CGRect(
      x: frame.minX + RoutingVisualizerLayout.horizontalInset
        + RoutingVisualizerLayout.portLabelGutter,
      y: frame.maxY - 48,
      width: frame.width - 2 * RoutingVisualizerLayout.horizontalInset
        - 2 * RoutingVisualizerLayout.portLabelGutter,
      height: 34
    )
    geometry.shapes.append(
      RoutingMetalShapeInstance(
        rect: valueFrame,
        fill: accent.withAlpha(0.09),
        border: .zero,
        cornerRadius: 8,
        borderWidth: 0,
        opacity: 1
      )
    )
    let reduction = Int(configuration.reductionDecibels.rounded())
    append(
      atlas: textAtlas.text("\(reduction) dB reduction", size: 10, weight: .medium),
      origin: CGPoint(x: valueFrame.minX + 11, y: valueFrame.midY - 7),
      color: palette.muted,
      to: &geometry
    )
  }

  private func appendCompressor(
    node: RoutingMetalScene.Node,
    frame: CGRect,
    accent: SIMD4<Float>,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    guard case .compressor(let configuration) = node.value else { return }
    let valueFrame = CGRect(
      x: frame.minX + RoutingVisualizerLayout.horizontalInset
        + RoutingVisualizerLayout.portLabelGutter,
      y: frame.maxY - 48,
      width: frame.width - 2 * RoutingVisualizerLayout.horizontalInset
        - 2 * RoutingVisualizerLayout.portLabelGutter,
      height: 34
    )
    geometry.shapes.append(
      RoutingMetalShapeInstance(
        rect: valueFrame,
        fill: accent.withAlpha(0.09),
        border: .zero,
        cornerRadius: 8,
        borderWidth: 0,
        opacity: 1
      )
    )
    let ratio = configuration.ratio.formatted(.number.precision(.fractionLength(1)))
    append(
      atlas: textAtlas.text("\(ratio):1 ratio", size: 10, weight: .medium),
      origin: CGPoint(x: valueFrame.minX + 11, y: valueFrame.midY - 7),
      color: palette.muted,
      to: &geometry
    )
  }

  private func accent(for node: RoutingMetalScene.Node) -> SIMD4<Float> {
    let rgb = node.accentID.baseRGB
    return SIMD4(
      Float((rgb >> 16) & 0xFF) / 255,
      Float((rgb >> 8) & 0xFF) / 255,
      Float(rgb & 0xFF) / 255,
      1
    )
  }

  private func iconFrame(for nodeFrame: CGRect) -> CGRect {
    Constants.iconFrame.offsetBy(dx: nodeFrame.minX, dy: nodeFrame.minY)
  }

  private func append(
    edge: RoutingMetalScene.Edge,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    let route = RoutingMetalEdgeRouteProjection.route(
      edge.route,
      sourceMoves: draggedNodeIDs.contains(edge.sourceNodeID),
      targetMoves: draggedNodeIDs.contains(edge.targetNodeID),
      translation: dragTranslation
    )
    appendStroke(
      points: RoutingMetalRouteGeometry.points(for: route),
      width: edgeStrokeWidth(edge) / camera.zoom,
      color: edgeStrokeColor(edge, palette: palette),
      to: &geometry
    )
    guard camera.zoom >= Constants.edgeLabelMinimumZoom,
      let label = edge.label,
      let entry = textAtlas.text(label, size: 8.5, weight: .medium)
    else {
      return
    }
    let center = midpoint(of: RoutingMetalRouteGeometry.points(for: route))
    let labelFrame = CGRect(
      x: center.x - (entry.size.width + 14) / 2,
      y: center.y - (entry.size.height + 6) / 2,
      width: entry.size.width + 14,
      height: entry.size.height + 6
    )
    geometry.shapes.append(
      RoutingMetalShapeInstance(
        rect: labelFrame,
        fill: palette.control.withAlpha(0.96),
        border: palette.border,
        cornerRadius: Float(labelFrame.height / 2),
        borderWidth: Float(1 / camera.zoom),
        opacity: 1
      )
    )
    append(
      atlas: entry,
      centeredIn: labelFrame,
      color: palette.muted,
      to: &geometry
    )
  }

  private func edgeStrokeWidth(_ edge: RoutingMetalScene.Edge) -> CGFloat {
    if selection.contains(edge.id) { return 2.8 }
    if hoveredEdgeID == edge.id { return 2.2 }
    return Constants.edgeWidth
  }

  private func edgeStrokeColor(
    _ edge: RoutingMetalScene.Edge,
    palette: RoutingMetalPalette
  ) -> SIMD4<Float> {
    if !edge.isActive {
      return palette.muted.withAlpha(selection.contains(edge.id) ? 0.58 : 0.28)
    }
    return palette.fern.withAlpha(selection.contains(edge.id) ? 0.92 : 0.58)
  }

  private func midpoint(of points: [CGPoint]) -> CGPoint {
    guard let first = points.first else { return .zero }
    guard points.count > 1 else { return first }
    let lengths = zip(points, points.dropFirst()).map { distance(from: $0, to: $1) }
    let total = lengths.reduce(0, +)
    guard total > 0 else { return first }
    let target = total / 2
    var traversed: CGFloat = 0
    for (index, length) in lengths.enumerated() {
      if traversed + length >= target {
        let progress = (target - traversed) / max(length, 0.000_1)
        return CGPoint(
          x: points[index].x + (points[index + 1].x - points[index].x) * progress,
          y: points[index].y + (points[index + 1].y - points[index].y) * progress
        )
      }
      traversed += length
    }
    return points.last ?? first
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
      points: RoutingMetalRouteGeometry.points(for: route),
      width: Constants.connectionPreviewWidth / camera.zoom,
      color: (isValid ? palette.fern : palette.muted).withAlpha(0.82),
      to: &geometry
    )
  }

  private func appendMarquee(
    _ rect: CGRect,
    palette: RoutingMetalPalette,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    geometry.shapes.append(
      RoutingMetalShapeInstance(
        rect: rect,
        fill: palette.fern.withAlpha(0.08),
        border: palette.fern.withAlpha(0.72),
        cornerRadius: Float(5 / camera.zoom),
        borderWidth: Float(1 / camera.zoom),
        opacity: 1
      )
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

  private func appendRoundStroke(
    points: [CGPoint],
    width: CGFloat,
    color: SIMD4<Float>,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    appendStroke(points: points, width: width, color: color, to: &geometry)
    let radius = width / 2
    let segmentCount = 8
    for point in points {
      for segment in 0..<segmentCount {
        let firstAngle = CGFloat(segment) / CGFloat(segmentCount) * .pi * 2
        let secondAngle = CGFloat(segment + 1) / CGFloat(segmentCount) * .pi * 2
        let first = CGPoint(
          x: point.x + cos(firstAngle) * radius,
          y: point.y + sin(firstAngle) * radius
        )
        let second = CGPoint(
          x: point.x + cos(secondAngle) * radius,
          y: point.y + sin(secondAngle) * radius
        )
        geometry.triangles.append(
          RoutingMetalTriangleInstance(
            point0: point,
            point1: first,
            point2: second,
            color: color
          )
        )
      }
    }
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
        opacity: 1,
        textureKind: entry.textureKind.rawValue
      )
    )
  }

  private func dynamicMonospacedTextSize(
    _ value: String,
    size: CGFloat,
    weight: NSFont.Weight
  ) -> CGSize {
    RoutingDynamicMonospacedText.glyphs(in: value).reduce(into: CGSize.zero) {
      result, glyph in
      guard let entry = textAtlas.monospacedText(glyph, size: size, weight: weight)
      else {
        return
      }
      result.width += entry.size.width
      result.height = max(result.height, entry.size.height)
    }
  }

  private func appendDynamicMonospacedText(
    _ value: String,
    size: CGFloat,
    weight: NSFont.Weight,
    origin: CGPoint,
    color: SIMD4<Float>,
    to geometry: inout RoutingMetalFrameGeometry
  ) {
    var x = origin.x
    for glyph in RoutingDynamicMonospacedText.glyphs(in: value) {
      guard let entry = textAtlas.monospacedText(glyph, size: size, weight: weight)
      else {
        continue
      }
      append(
        atlas: entry,
        origin: CGPoint(x: x, y: origin.y),
        color: color,
        to: &geometry
      )
      x += entry.size.width
    }
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

  private func audioChannelControl(at point: CGPoint) -> AudioChannelControlHit? {
    for node in nodesInRenderOrder.reversed() {
      let channelCount: Int
      let rows: [CGRect]
      let frame = translatedFrame(of: node)
      if node.hasAudioSourceSelection,
        case .some(.separate(let sourceChannelCount)) =
          node.value.audioSourceChannelPresentation
      {
        channelCount = sourceChannelCount
        rows = RoutingAudioSourceLayout.rowFrames(
          in: frame,
          channelCount: sourceChannelCount
        )
      } else if case .audioMixer(let configuration) = node.value {
        channelCount = configuration.channelCount
        rows = RoutingAudioMixerLayout.rowFrames(
          in: frame,
          channelCount: configuration.channelCount
        )
      } else {
        continue
      }
      for (channelIndex, row) in rows.prefix(channelCount).enumerated() {
        if RoutingAudioSourceLayout.muteButtonFrame(in: row).contains(point) {
          return .mute(nodeID: node.workspaceID, channelIndex: channelIndex)
        }
        let track = RoutingAudioSourceLayout.gainTrackFrame(in: row)
        let hitFrame = CGRect(
          x: track.minX,
          y: row.minY,
          width: track.width,
          height: row.height
        )
        if hitFrame.contains(point) {
          return .gain(
            AudioGainDrag(
              nodeID: node.workspaceID,
              channelIndex: channelIndex,
              trackFrame: track
            )
          )
        }
      }
    }
    return nil
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

  private func edge(at point: CGPoint) -> RoutingMetalScene.Edge? {
    let hitDistance = 7 / camera.zoom
    return scene.edges.compactMap { edge -> (RoutingMetalScene.Edge, CGFloat)? in
      let route = RoutingMetalEdgeRouteProjection.route(
        edge.route,
        sourceMoves: draggedNodeIDs.contains(edge.sourceNodeID),
        targetMoves: draggedNodeIDs.contains(edge.targetNodeID),
        translation: dragTranslation
      )
      let routePoints = RoutingMetalRouteGeometry.points(for: route)
      let minimumDistance =
        zip(routePoints, routePoints.dropFirst()).map { pair in
          distance(from: point, toSegmentFrom: pair.0, to: pair.1)
        }.min() ?? .infinity
      return minimumDistance <= hitDistance ? (edge, minimumDistance) : nil
    }.min { $0.1 < $1.1 }?.0
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
    guard draggedNodeIDs.contains(node.id) else { return node.frame }
    return node.frame.offsetBy(dx: dragTranslation.width, dy: dragTranslation.height)
  }

  private func translatedPosition(of port: RoutingMetalScene.Port) -> CGPoint {
    guard draggedNodeIDs.contains(port.nodeID) else { return port.position }
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
    draggedNodeIDs.removeAll(keepingCapacity: true)
    dragTranslation = .zero
    marqueeBaseSelection.removeAll(keepingCapacity: true)
    marqueeWorldRect = nil
    connectionSourceID = nil
    connectionLocation = nil
    connectionTargetID = nil
    audioGainDrag = nil
    cursorForCurrentTool.set()
  }

  private var cursorForCurrentTool: NSCursor {
    mouseTool == .pan ? .openHand : .arrow
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

  private func distance(
    from point: CGPoint,
    toSegmentFrom start: CGPoint,
    to end: CGPoint
  ) -> CGFloat {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return distance(from: point, to: start) }
    let progress = min(
      max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0),
      1
    )
    return distance(
      from: point,
      to: CGPoint(x: start.x + progress * dx, y: start.y + progress * dy)
    )
  }

  private func drawInstances<T>(
    _ range: Range<Int>,
    instanceType: T.Type,
    buffer: any MTLBuffer,
    pipeline: any MTLRenderPipelineState,
    encoder: any MTLRenderCommandEncoder,
    uniforms: inout RoutingMetalUniforms,
    vertexCount: Int = 6
  ) {
    guard !range.isEmpty else { return }
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBytes(
      &uniforms,
      length: MemoryLayout<RoutingMetalUniforms>.stride,
      index: 0
    )
    encoder.setVertexBuffer(
      buffer,
      offset: range.lowerBound * MemoryLayout<T>.stride,
      index: 1
    )
    encoder.drawPrimitives(
      type: .triangle,
      vertexStart: 0,
      vertexCount: vertexCount,
      instanceCount: range.count
    )
  }

  private func prepareBuffer<T>(
    values: [T],
    buffers: inout [any MTLBuffer]
  ) -> (any MTLBuffer)? {
    guard !values.isEmpty else { return nil }
    return updateBuffer(values: values, buffers: &buffers)
  }

  private func updateBuffer<T>(
    values: [T],
    buffers: inout [any MTLBuffer]
  ) -> any MTLBuffer {
    let requiredLength = max(values.count * MemoryLayout<T>.stride, 1)
    if buffers.count != Constants.maximumFramesInFlight
      || buffers.contains(where: { $0.length < requiredLength })
    {
      guard let device else {
        preconditionFailure("The routing canvas lost its Metal device")
      }
      let capacity = max(requiredLength.nextPowerOfTwo, 256)
      buffers = (0..<Constants.maximumFramesInFlight).map { index in
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
  let brook = SIMD4<Float>(0x29 / 255, 0xA3 / 255, 0xC5 / 255, 1)
  let seafoam = SIMD4<Float>(0x4D / 255, 0xA5 / 255, 0xA0 / 255, 1)
  let pollen = SIMD4<Float>(0xA6 / 255, 0x97 / 255, 0x4F / 255, 1)
  let poppy = SIMD4<Float>(0xE9 / 255, 0x64 / 255, 0x52 / 255, 1)
  let wisteria = SIMD4<Float>(0x96 / 255, 0x8A / 255, 0xC7 / 255, 1)
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
  var textureKind: UInt32
  var padding = SIMD2<Float>.zero
}

private struct RoutingMetalFrameGeometry {
  var shapes: [RoutingMetalShapeInstance] = []
  var triangles: [RoutingMetalTriangleInstance] = []
  var atlasItems: [RoutingMetalAtlasInstance] = []
  var backgroundTriangleRange = 0..<0
  var backgroundShapeRange = 0..<0
  var backgroundAtlasRange = 0..<0
  var nodeRanges: [RoutingMetalNodeRange] = []

  mutating func removeAll(keepingCapacity: Bool) {
    shapes.removeAll(keepingCapacity: keepingCapacity)
    triangles.removeAll(keepingCapacity: keepingCapacity)
    atlasItems.removeAll(keepingCapacity: keepingCapacity)
    backgroundTriangleRange = 0..<0
    backgroundShapeRange = 0..<0
    backgroundAtlasRange = 0..<0
    nodeRanges.removeAll(keepingCapacity: keepingCapacity)
  }
}

private struct RoutingMetalNodeRange {
  let shapeRange: Range<Int>
  let triangleRange: Range<Int>
  let atlasRange: Range<Int>
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
