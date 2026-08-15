import Foundation
import RilliyaKit

enum RoutingPreparedAudioGraphError: Error, Equatable, LocalizedError, Sendable {
  case missingOutputNode
  case missingCapture(UUID)
  case incompatibleSampleRate(UUID)
  case invalidRoute
  case cycle

  var errorDescription: String? {
    switch self {
    case .missingOutputNode:
      "The selected destination is not an Output Audio node."
    case .missingCapture(let nodeID):
      "Audio capture for node \(nodeID) is not ready."
    case .incompatibleSampleRate(let nodeID):
      "Audio source \(nodeID) needs explicit sample-rate conversion before playback."
    case .invalidRoute:
      "The audio graph contains a route that cannot be compiled."
    case .cycle:
      "The audio graph contains a feedback cycle without an explicit delay node."
    }
  }
}

final class RoutingPreparedAudioGraphSource: PreparedAudioSource, @unchecked Sendable {
  let preparation: AudioRenderPreparation
  let timing = AudioNodeTiming.transparent

  private let storage: RoutingPreparedAudioStorage
  private let captureReads: [RoutingPreparedCaptureRead]
  private let gainOperations: [RoutingPreparedGainOperation]
  private let mixOperations: [RoutingPreparedMixOperation]
  private let finalMix: RoutingPreparedMixOperation

  init(
    preparation: AudioRenderPreparation,
    nodes: [RoutingWorkspaceNode],
    edges: [RoutingWorkspaceEdge],
    outputNodeID: UUID,
    frameBuffers: [UUID: AudioRealtimeFrameBuffer]
  ) throws {
    var compiler = RoutingPreparedAudioGraphCompiler(
      preparation: preparation,
      nodes: nodes,
      edges: edges.filter(\.isEnabled),
      outputNodeID: outputNodeID,
      frameBuffers: frameBuffers
    )
    let plan = try compiler.compile()
    let storage = RoutingPreparedAudioStorage(
      bufferCount: plan.bufferCount,
      maximumFrameCount: preparation.maximumFrameCount
    )
    self.preparation = preparation
    self.storage = storage
    captureReads = try plan.captureReads.map {
      try RoutingPreparedCaptureRead(
        plan: $0,
        storage: storage,
        maximumFrameCount: preparation.maximumFrameCount
      )
    }
    gainOperations = try plan.gainOperations.map {
      try RoutingPreparedGainOperation(
        plan: $0,
        preparation: preparation,
        storage: storage
      )
    }
    mixOperations = try plan.mixOperations.map {
      try RoutingPreparedMixOperation(
        plan: $0,
        outputChannelCount: 1,
        preparation: preparation,
        storage: storage
      )
    }
    finalMix = try RoutingPreparedMixOperation(
      plan: plan.finalMix,
      outputChannelCount: preparation.format.channelCount,
      preparation: preparation,
      storage: storage
    )
  }

  func render(
    outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRenderResult {
    guard (0...preparation.maximumFrameCount).contains(frameCount) else {
      return .invalidFrameCount
    }
    guard outputChannels.count >= preparation.format.channelCount else {
      return .insufficientChannels
    }
    for captureRead in captureReads {
      guard captureRead.render(frameCount: frameCount) == .rendered else {
        return .insufficientChannels
      }
    }
    for operation in gainOperations {
      guard operation.render(frameCount: frameCount) == .rendered else {
        return .insufficientChannels
      }
    }
    for operation in mixOperations {
      guard operation.render(frameCount: frameCount) == .rendered else {
        return .insufficientChannels
      }
    }
    return finalMix.render(outputChannels: outputChannels, frameCount: frameCount)
  }
}

private struct RoutingCompiledAudioChannel: Hashable {
  let channelIndex: Int
  let bufferIndex: Int
}

private struct RoutingCaptureReadPlan {
  let frameBuffer: AudioRealtimeFrameBuffer
  let outputBufferIndices: [Int]
}

private struct RoutingGainPlan {
  let inputBufferIndices: [Int]
  let outputBufferIndices: [Int]
  let controls: [RoutingAudioChannelControl]
}

private struct RoutingMixPlan {
  let inputBufferIndices: [Int]
  let routes: [(inputIndex: Int, destinationChannel: Int, gain: Float)]
  let outputBufferIndices: [Int]
  let outputControls: [RoutingAudioChannelControl]
}

private struct RoutingPreparedAudioGraphPlan {
  let bufferCount: Int
  let captureReads: [RoutingCaptureReadPlan]
  let gainOperations: [RoutingGainPlan]
  let mixOperations: [RoutingMixPlan]
  let finalMix: RoutingMixPlan
}

private struct RoutingPreparedAudioGraphCompiler {
  private let preparation: AudioRenderPreparation
  private let nodesByID: [UUID: RoutingWorkspaceNode]
  private let incomingEdgesByNodeID: [UUID: [RoutingWorkspaceEdge]]
  private let outputNodeID: UUID
  private let frameBuffers: [UUID: AudioRealtimeFrameBuffer]

  private var nextBufferIndex = 0
  private var captureReadPlans: [RoutingCaptureReadPlan] = []
  private var gainPlans: [RoutingGainPlan] = []
  private var mixPlans: [RoutingMixPlan] = []
  private var rawSignalsByBuffer: [ObjectIdentifier: [RoutingCompiledAudioChannel]] = [:]
  private var sourceSignalsByNodeID: [UUID: [RoutingCompiledAudioChannel]] = [:]
  private var signalsByAddress: [RoutingWorkspacePortAddress: [RoutingCompiledAudioChannel]] = [:]

  init(
    preparation: AudioRenderPreparation,
    nodes: [RoutingWorkspaceNode],
    edges: [RoutingWorkspaceEdge],
    outputNodeID: UUID,
    frameBuffers: [UUID: AudioRealtimeFrameBuffer]
  ) {
    self.preparation = preparation
    nodesByID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    incomingEdgesByNodeID = Dictionary(grouping: edges, by: { $0.target.nodeID })
    self.outputNodeID = outputNodeID
    self.frameBuffers = frameBuffers
  }

  mutating func compile() throws -> RoutingPreparedAudioGraphPlan {
    guard let outputNode = nodesByID[outputNodeID],
      case .outputAudio = outputNode.value
    else {
      throw RoutingPreparedAudioGraphError.missingOutputNode
    }
    var finalContributions: [(bufferIndex: Int, destinationChannel: Int)] = []
    for edge in sortedIncomingEdges(for: outputNodeID) {
      let signal = try resolveOutput(edge.source, visited: [])
      guard let targetChannel = edge.target.portID.audioChannel else {
        throw RoutingPreparedAudioGraphError.invalidRoute
      }
      switch targetChannel {
      case .all:
        for channel in signal
        where preparation.format.channelCount > channel.channelIndex {
          finalContributions.append((channel.bufferIndex, channel.channelIndex))
        }
      case .channel(let channelIndex):
        guard preparation.format.channelCount > channelIndex else { continue }
        for channel in signal {
          finalContributions.append((channel.bufferIndex, channelIndex))
        }
      }
    }

    let finalMix = RoutingMixPlan(
      inputBufferIndices: finalContributions.map(\.bufferIndex),
      routes: finalContributions.enumerated().map { inputIndex, contribution in
        (inputIndex, contribution.destinationChannel, 1)
      },
      outputBufferIndices: [],
      outputControls: (0..<preparation.format.channelCount).map { _ in .unity }
    )
    return RoutingPreparedAudioGraphPlan(
      bufferCount: nextBufferIndex,
      captureReads: captureReadPlans,
      gainOperations: gainPlans,
      mixOperations: mixPlans,
      finalMix: finalMix
    )
  }

  private mutating func resolveOutput(
    _ address: RoutingWorkspacePortAddress,
    visited: Set<RoutingWorkspacePortAddress>
  ) throws -> [RoutingCompiledAudioChannel] {
    if let cached = signalsByAddress[address] { return cached }
    guard address.portID.direction == .output,
      let node = nodesByID[address.nodeID]
    else {
      throw RoutingPreparedAudioGraphError.invalidRoute
    }
    guard !visited.contains(address) else { throw RoutingPreparedAudioGraphError.cycle }
    var visited = visited
    visited.insert(address)

    let signal: [RoutingCompiledAudioChannel]
    switch node.value {
    case .applicationAudio, .inputAudio:
      signal = try sourceSignal(for: node, address: address)
    case .visualizer(let configuration):
      signal = try visualizerSignal(
        nodeID: node.id,
        address: address,
        configuration: configuration,
        visited: visited
      )
    case .audioMixer:
      signal = try mixerSignal(node: node, address: address, visited: visited)
    case .outputAudio, .peakLevel:
      throw RoutingPreparedAudioGraphError.invalidRoute
    }
    signalsByAddress[address] = signal
    return signal
  }

  private mutating func sourceSignal(
    for node: RoutingWorkspaceNode,
    address: RoutingWorkspacePortAddress
  ) throws -> [RoutingCompiledAudioChannel] {
    let processed: [RoutingCompiledAudioChannel]
    if let existing = sourceSignalsByNodeID[node.id] {
      processed = existing
    } else {
      guard let frameBuffer = frameBuffers[node.id] else {
        throw RoutingPreparedAudioGraphError.missingCapture(node.id)
      }
      guard frameBuffer.format.sampleRate == preparation.format.sampleRate else {
        throw RoutingPreparedAudioGraphError.incompatibleSampleRate(node.id)
      }
      let raw: [RoutingCompiledAudioChannel]
      let bufferIdentity = ObjectIdentifier(frameBuffer)
      if let existing = rawSignalsByBuffer[bufferIdentity] {
        raw = existing
      } else {
        let indices = allocateBuffers(count: frameBuffer.format.channelCount)
        raw = indices.enumerated().map {
          RoutingCompiledAudioChannel(channelIndex: $0.offset, bufferIndex: $0.element)
        }
        rawSignalsByBuffer[bufferIdentity] = raw
        captureReadPlans.append(
          RoutingCaptureReadPlan(
            frameBuffer: frameBuffer,
            outputBufferIndices: indices
          )
        )
      }
      let outputIndices = allocateBuffers(count: raw.count)
      gainPlans.append(
        RoutingGainPlan(
          inputBufferIndices: raw.map(\.bufferIndex),
          outputBufferIndices: outputIndices,
          controls: raw.map { node.audioChannelControl(at: $0.channelIndex) }
        )
      )
      processed = zip(raw, outputIndices).map {
        RoutingCompiledAudioChannel(channelIndex: $0.0.channelIndex, bufferIndex: $0.1)
      }
      sourceSignalsByNodeID[node.id] = processed
    }

    switch address.portID.audioChannel {
    case .some(.all):
      return processed
    case .some(.channel(let channelIndex)):
      return processed.filter { $0.channelIndex == channelIndex }
    case .none:
      throw RoutingPreparedAudioGraphError.invalidRoute
    }
  }

  private mutating func visualizerSignal(
    nodeID: UUID,
    address: RoutingWorkspacePortAddress,
    configuration: RoutingVisualizerConfiguration,
    visited: Set<RoutingWorkspacePortAddress>
  ) throws -> [RoutingCompiledAudioChannel] {
    guard let outputChannel = address.portID.audioChannel else {
      throw RoutingPreparedAudioGraphError.invalidRoute
    }
    let incoming = sortedIncomingEdges(for: nodeID)
    switch (configuration.mode, outputChannel) {
    case (.mixed, .all):
      guard let edge = incoming.first(where: { $0.target.portID.audioChannel == .all }) else {
        return []
      }
      return try resolveOutput(edge.source, visited: visited)
    case (.separate, .channel(let channelIndex)):
      guard
        let edge = incoming.first(where: {
          $0.target.portID.audioChannel == .channel(channelIndex)
        })
      else { return [] }
      return try resolveOutput(edge.source, visited: visited).map {
        RoutingCompiledAudioChannel(channelIndex: channelIndex, bufferIndex: $0.bufferIndex)
      }
    case (.separate, .all):
      guard configuration.includesMixedOutput else { return [] }
      let inputs = try incoming.flatMap { edge -> [RoutingCompiledAudioChannel] in
        guard case .some(.channel(let channelIndex)) = edge.target.portID.audioChannel,
          configuration.normalizedSelectedChannels.contains(channelIndex)
        else { return [] }
        return try resolveOutput(edge.source, visited: visited)
      }
      return try makeMixSignal(inputs, destinationChannel: 0, normalized: true, control: .unity)
    default:
      return []
    }
  }

  private mutating func mixerSignal(
    node: RoutingWorkspaceNode,
    address: RoutingWorkspacePortAddress,
    visited: Set<RoutingWorkspacePortAddress>
  ) throws -> [RoutingCompiledAudioChannel] {
    guard case .some(.channel(let channelIndex)) = address.portID.audioChannel else {
      throw RoutingPreparedAudioGraphError.invalidRoute
    }
    let inputs = try sortedIncomingEdges(for: node.id).flatMap {
      edge -> [RoutingCompiledAudioChannel] in
      guard edge.target.portID.audioChannel == .channel(channelIndex) else { return [] }
      return try resolveOutput(edge.source, visited: visited)
    }
    return try makeMixSignal(
      inputs,
      destinationChannel: channelIndex,
      normalized: false,
      control: node.audioChannelControl(at: channelIndex)
    )
  }

  private mutating func makeMixSignal(
    _ inputs: [RoutingCompiledAudioChannel],
    destinationChannel: Int,
    normalized: Bool,
    control: RoutingAudioChannelControl
  ) throws -> [RoutingCompiledAudioChannel] {
    guard !inputs.isEmpty else { return [] }
    let outputIndex = allocateBuffers(count: 1)[0]
    let routeGain = normalized ? 1 / Float(inputs.count) : 1
    mixPlans.append(
      RoutingMixPlan(
        inputBufferIndices: inputs.map(\.bufferIndex),
        routes: inputs.indices.map { ($0, 0, routeGain) },
        outputBufferIndices: [outputIndex],
        outputControls: [control]
      )
    )
    return [
      RoutingCompiledAudioChannel(
        channelIndex: destinationChannel,
        bufferIndex: outputIndex
      )
    ]
  }

  private func sortedIncomingEdges(for nodeID: UUID) -> [RoutingWorkspaceEdge] {
    (incomingEdgesByNodeID[nodeID] ?? []).sorted { $0.id.uuidString < $1.id.uuidString }
  }

  private mutating func allocateBuffers(count: Int) -> [Int] {
    guard count > 0 else { return [] }
    let result = Array(nextBufferIndex..<(nextBufferIndex + count))
    nextBufferIndex += count
    return result
  }
}

private final class RoutingPreparedAudioStorage {
  let maximumFrameCount: Int

  private let bufferCount: Int
  private let samples: UnsafeMutablePointer<Float>

  init(bufferCount: Int, maximumFrameCount: Int) {
    precondition(bufferCount >= 0 && maximumFrameCount > 0)
    self.bufferCount = bufferCount
    self.maximumFrameCount = maximumFrameCount
    samples = .allocate(capacity: max(bufferCount * maximumFrameCount, 1))
    samples.initialize(repeating: 0, count: max(bufferCount * maximumFrameCount, 1))
  }

  deinit {
    samples.deinitialize(count: max(bufferCount * maximumFrameCount, 1))
    samples.deallocate()
  }

  func pointer(at bufferIndex: Int) -> UnsafeMutablePointer<Float> {
    precondition((0..<bufferCount).contains(bufferIndex))
    return samples.advanced(by: bufferIndex * maximumFrameCount)
  }
}

private final class RoutingPreparedPointerList {
  let mutable: UnsafeMutablePointer<UnsafeMutablePointer<Float>>
  let immutable: UnsafeMutablePointer<UnsafePointer<Float>>
  let count: Int

  init(bufferIndices: [Int], storage: RoutingPreparedAudioStorage) {
    count = bufferIndices.count
    mutable = .allocate(capacity: max(count, 1))
    immutable = .allocate(capacity: max(count, 1))
    if count == 0 {
      let fallback = UnsafeMutablePointer<Float>.allocate(capacity: 1)
      fallback.initialize(to: 0)
      mutable.initialize(to: fallback)
      immutable.initialize(to: UnsafePointer(fallback))
    } else {
      for (offset, bufferIndex) in bufferIndices.enumerated() {
        let pointer = storage.pointer(at: bufferIndex)
        mutable.advanced(by: offset).initialize(to: pointer)
        immutable.advanced(by: offset).initialize(to: UnsafePointer(pointer))
      }
    }
  }

  deinit {
    if count == 0 {
      let fallback = mutable.pointee
      fallback.deinitialize(count: 1)
      fallback.deallocate()
      mutable.deinitialize(count: 1)
      immutable.deinitialize(count: 1)
    } else {
      mutable.deinitialize(count: count)
      immutable.deinitialize(count: count)
    }
    mutable.deallocate()
    immutable.deallocate()
  }

  var mutableBuffer: UnsafeBufferPointer<UnsafeMutablePointer<Float>> {
    UnsafeBufferPointer(start: mutable, count: count)
  }

  var immutableBuffer: UnsafeBufferPointer<UnsafePointer<Float>> {
    UnsafeBufferPointer(start: immutable, count: count)
  }
}

private final class RoutingPreparedCaptureRead {
  private let source: PreparedAudioFrameBufferSource
  private let outputs: RoutingPreparedPointerList

  init(
    plan: RoutingCaptureReadPlan,
    storage: RoutingPreparedAudioStorage,
    maximumFrameCount: Int
  ) throws {
    source = try PreparedAudioFrameBufferSource(
      frameBuffer: plan.frameBuffer,
      maximumFrameCount: maximumFrameCount
    )
    outputs = RoutingPreparedPointerList(
      bufferIndices: plan.outputBufferIndices,
      storage: storage
    )
  }

  func render(frameCount: Int) -> AudioRenderResult {
    source.render(outputChannels: outputs.mutableBuffer, frameCount: frameCount)
  }
}

private final class RoutingPreparedGainOperation {
  private let processor: PreparedAudioChannelGainProcessor
  private let inputs: RoutingPreparedPointerList
  private let outputs: RoutingPreparedPointerList

  init(
    plan: RoutingGainPlan,
    preparation: AudioRenderPreparation,
    storage: RoutingPreparedAudioStorage
  ) throws {
    let controls = try AudioChannelGainControlBank(channelCount: plan.controls.count)
    for (channel, control) in plan.controls.enumerated() {
      try controls.setControl(
        AudioChannelGainControl(
          linearGain: control.linearGain,
          isMuted: control.isMuted
        ),
        at: channel
      )
    }
    processor = try PreparedAudioChannelGainProcessor(
      preparation: AudioRenderPreparation(
        format: AudioProcessingFormat(
          sampleRate: preparation.format.sampleRate,
          channelCount: plan.controls.count
        ),
        maximumFrameCount: preparation.maximumFrameCount
      ),
      controls: controls,
      rampDurationSeconds: 0
    )
    inputs = RoutingPreparedPointerList(bufferIndices: plan.inputBufferIndices, storage: storage)
    outputs = RoutingPreparedPointerList(bufferIndices: plan.outputBufferIndices, storage: storage)
  }

  func render(frameCount: Int) -> AudioRenderResult {
    processor.process(
      inputChannels: inputs.immutableBuffer,
      outputChannels: outputs.mutableBuffer,
      frameCount: frameCount
    )
  }
}

private final class RoutingPreparedMixOperation {
  private let processor: PreparedAudioMixerProcessor
  private let inputs: RoutingPreparedPointerList
  private let preparedOutputs: RoutingPreparedPointerList?

  init(
    plan: RoutingMixPlan,
    outputChannelCount: Int,
    preparation: AudioRenderPreparation,
    storage: RoutingPreparedAudioStorage
  ) throws {
    let controls = try AudioChannelGainControlBank(channelCount: outputChannelCount)
    for (channel, control) in plan.outputControls.enumerated()
    where channel < outputChannelCount {
      try controls.setControl(
        AudioChannelGainControl(
          linearGain: control.linearGain,
          isMuted: control.isMuted
        ),
        at: channel
      )
    }
    let outputPreparation = try AudioRenderPreparation(
      format: AudioProcessingFormat(
        sampleRate: preparation.format.sampleRate,
        channelCount: outputChannelCount
      ),
      maximumFrameCount: preparation.maximumFrameCount
    )
    processor = try PreparedAudioMixerProcessor(
      preparation: AudioMixerRenderPreparation(
        inputFormats: try plan.inputBufferIndices.map { _ in
          try AudioProcessingFormat(sampleRate: preparation.format.sampleRate, channelCount: 1)
        },
        output: outputPreparation
      ),
      routes: try plan.routes.map {
        try AudioChannelRoute(
          inputIndex: $0.inputIndex,
          sourceChannel: 0,
          destinationChannel: $0.destinationChannel,
          gain: $0.gain
        )
      },
      outputControls: controls,
      rampDurationSeconds: 0
    )
    inputs = RoutingPreparedPointerList(bufferIndices: plan.inputBufferIndices, storage: storage)
    preparedOutputs =
      plan.outputBufferIndices.isEmpty
      ? nil
      : RoutingPreparedPointerList(bufferIndices: plan.outputBufferIndices, storage: storage)
  }

  func render(frameCount: Int) -> AudioRenderResult {
    guard let preparedOutputs else { return .insufficientChannels }
    return render(outputChannels: preparedOutputs.mutableBuffer, frameCount: frameCount)
  }

  func render(
    outputChannels: UnsafeBufferPointer<UnsafeMutablePointer<Float>>,
    frameCount: Int
  ) -> AudioRenderResult {
    processor.process(
      inputChannels: inputs.immutableBuffer,
      outputChannels: outputChannels,
      frameCount: frameCount
    )
  }
}
