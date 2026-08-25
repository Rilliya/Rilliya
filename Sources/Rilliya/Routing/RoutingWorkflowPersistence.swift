import FlowingDayCanvas
import FlowingDayGraphCanvas
import Foundation
import RilliyaFileWriting
import RilliyaRealtime

struct RoutingWorkflowPersistenceToken: Equatable, Sendable {
  struct Workflow: Equatable, Sendable {
    let id: UUID
    let name: String
    let miniMapVisibilityOverride: Bool?
    let runsAutomaticallyOnLaunch: Bool
    let viewport: RoutingViewportSnapshot
    let workspaceRevision: UInt64
  }

  let selectedWorkflowID: UUID
  let workflows: [Workflow]

  @MainActor
  init(library: RoutingWorkflowLibrary) {
    selectedWorkflowID = library.selectedWorkflowID
    workflows = library.workflows.map { workflow in
      Workflow(
        id: workflow.id,
        name: workflow.name,
        miniMapVisibilityOverride: workflow.miniMapVisibilityOverride,
        runsAutomaticallyOnLaunch: workflow.runsAutomaticallyOnLaunch,
        viewport: RoutingViewportSnapshot(transform: workflow.canvasSession.viewport.transform),
        workspaceRevision: workflow.workspace.persistenceRevision
      )
    }
  }
}

struct RoutingWorkflowLibrarySnapshot: Codable, Equatable, Sendable {
  let selectedWorkflowID: UUID
  let workflows: [RoutingWorkflowSnapshot]

  @MainActor
  init(library: RoutingWorkflowLibrary) {
    selectedWorkflowID = library.selectedWorkflowID
    workflows = library.workflows.map(RoutingWorkflowSnapshot.init)
  }

  @MainActor
  func makeLibrary() throws -> RoutingWorkflowLibrary {
    guard !workflows.isEmpty else {
      throw RoutingWorkflowPersistenceError.emptyLibrary
    }
    guard workflows.count <= RoutingWorkflowPersistenceLimits.maximumWorkflowCount else {
      throw RoutingWorkflowPersistenceError.graphTooLarge
    }
    var totalNodeCount = 0
    var totalEdgeCount = 0
    for workflow in workflows {
      let nodes = totalNodeCount.addingReportingOverflow(workflow.nodes.count)
      let edges = totalEdgeCount.addingReportingOverflow(workflow.edges.count)
      guard !nodes.overflow, !edges.overflow,
        nodes.partialValue <= RoutingWorkflowPersistenceLimits.maximumTotalNodeCount,
        edges.partialValue <= RoutingWorkflowPersistenceLimits.maximumTotalEdgeCount
      else {
        throw RoutingWorkflowPersistenceError.graphTooLarge
      }
      totalNodeCount = nodes.partialValue
      totalEdgeCount = edges.partialValue
    }
    guard Set(workflows.map(\.id)).count == workflows.count else {
      throw RoutingWorkflowPersistenceError.duplicateWorkflowID
    }
    guard workflows.contains(where: { $0.id == selectedWorkflowID }) else {
      throw RoutingWorkflowPersistenceError.unknownSelectedWorkflow
    }
    return RoutingWorkflowLibrary(
      workflows: try workflows.map { try $0.makeWorkflow() },
      selectedWorkflowID: selectedWorkflowID
    )
  }
}

struct RoutingWorkflowSnapshot: Codable, Equatable, Sendable {
  let id: UUID
  let name: String
  let miniMapVisibilityOverride: Bool?
  let runsAutomaticallyOnLaunch: Bool
  let viewport: RoutingViewportSnapshot
  let nodes: [RoutingWorkspaceNode]
  let edges: [RoutingWorkspaceEdge]

  @MainActor
  init(workflow: RoutingWorkflowModel) {
    id = workflow.id
    name = workflow.name
    miniMapVisibilityOverride = workflow.miniMapVisibilityOverride
    runsAutomaticallyOnLaunch = workflow.runsAutomaticallyOnLaunch
    viewport = RoutingViewportSnapshot(transform: workflow.canvasSession.viewport.transform)
    nodes = workflow.workspace.nodes
    edges = workflow.workspace.edges
  }

  @MainActor
  func makeWorkflow() throws -> RoutingWorkflowModel {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      throw RoutingWorkflowPersistenceError.emptyWorkflowName
    }
    guard nodes.count <= RoutingWorkflowPersistenceLimits.maximumNodeCount,
      edges.count <= RoutingWorkflowPersistenceLimits.maximumEdgeCount
    else {
      throw RoutingWorkflowPersistenceError.graphTooLarge
    }
    guard nodes.allSatisfy(Self.isValidPersistedNode) else {
      throw RoutingWorkflowPersistenceError.invalidNode
    }
    let workspace = try RoutingWorkspaceModel(
      restoringID: id,
      nodes: nodes,
      edges: edges
    )
    let transform = try viewport.makeTransform()
    return RoutingWorkflowModel(
      id: id,
      name: normalizedName,
      workspace: workspace,
      miniMapVisibilityOverride: miniMapVisibilityOverride,
      runsAutomaticallyOnLaunch: runsAutomaticallyOnLaunch,
      isRunning: runsAutomaticallyOnLaunch,
      canvasSession: FlowingGraphCanvasSessionState(
        viewport: FlowingCanvasViewport(transform: transform)
      )
    )
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case name
    case miniMapVisibilityOverride
    case runsAutomaticallyOnLaunch
    case viewport
    case nodes
    case edges
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    miniMapVisibilityOverride = try container.decodeIfPresent(
      Bool.self,
      forKey: .miniMapVisibilityOverride
    )
    runsAutomaticallyOnLaunch =
      try container.decodeIfPresent(Bool.self, forKey: .runsAutomaticallyOnLaunch) ?? false
    viewport = try container.decode(RoutingViewportSnapshot.self, forKey: .viewport)
    nodes = try container.decode([RoutingWorkspaceNode].self, forKey: .nodes)
    edges = try container.decode([RoutingWorkspaceEdge].self, forKey: .edges)
  }

  private static func isValidPersistedNode(_ node: RoutingWorkspaceNode) -> Bool {
    guard
      node.audioChannelControls.allSatisfy({ channelIndex, control in
        (0..<RoutingVisualizerConfiguration.maximumAvailableChannelCount).contains(channelIndex)
          && control.gainDecibels.isFinite
          && control.gainDecibels >= RoutingAudioChannelControl.minimumGainDecibels
          && control.gainDecibels <= RoutingAudioChannelControl.maximumGainDecibels
      })
    else {
      return false
    }
    switch node.value {
    case .applicationAudio(let selection, let presentation):
      if let selection {
        guard !selection.id.isEmpty,
          !selection.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          selection.applicationURL.isFileURL
        else { return false }
      }
      return isValid(presentation)
    case .inputAudio(let selection, let presentation):
      if let selection,
        selection.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return false
      }
      return isValid(presentation)
    case .systemOutput(let selection, let presentation):
      if case .some(.device(let device)) = selection,
        device.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return false
      }
      return isValid(presentation)
    case .virtualOutput(let selection, let presentation):
      return isValidVirtualEndpointSelection(
        selection,
        presentation: presentation
      )
    case .outputAudio(let selection, let presentation):
      if let selection,
        selection.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return false
      }
      return isValid(presentation)
    case .virtualInput(let selection, let presentation):
      return isValidVirtualEndpointSelection(
        selection,
        presentation: presentation
      )
    case .visualizer(let configuration):
      let requestedChannels = configuration.channelSelection.requestedChannels
      return (1...RoutingVisualizerConfiguration.maximumAvailableChannelCount).contains(
        configuration.availableChannelCount
      )
        && !requestedChannels.isEmpty
        && requestedChannels.count <= RoutingVisualizerConfiguration.maximumSeparateLaneCount
        && requestedChannels.allSatisfy {
          (0..<RoutingVisualizerConfiguration.maximumAvailableChannelCount).contains($0)
        }
    case .audioMixer(let configuration):
      return
        (RoutingAudioMixerConfiguration
        .minimumChannelCount...RoutingAudioMixerConfiguration.maximumChannelCount).contains(
          configuration.channelCount)
    case .gain(let configuration):
      return configuration.gainDecibels.isFinite
        && (RoutingGainConfiguration
          .minimumGainDecibels...RoutingGainConfiguration.maximumGainDecibels).contains(
            configuration.gainDecibels
          )
    case .channelRouter(let configuration):
      return
        (RoutingChannelRouterConfiguration
        .minimumChannelCount...RoutingChannelRouterConfiguration.maximumChannelCount).contains(
          configuration.inputChannelCount
        )
        && (RoutingChannelRouterConfiguration
          .minimumChannelCount...RoutingChannelRouterConfiguration.maximumChannelCount).contains(
            configuration.outputChannelCount
          )
        && configuration.outputSources.allSatisfy { source in
          source.map { (0..<configuration.inputChannelCount).contains($0) } ?? true
        }
    case .peakLevel:
      return true
    case .signalGenerator(let configuration):
      return configuration.frequency.isFinite
        && (RoutingSignalGeneratorConfiguration
          .minimumFrequency...RoutingSignalGeneratorConfiguration.maximumFrequency).contains(
            configuration.frequency
          )
        && configuration.amplitude.isFinite
        && (0...1).contains(configuration.amplitude)
    case .filePlayback(let configuration):
      guard let selection = configuration.selection else { return true }
      guard selection.url.isFileURL,
        !selection.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        (1...AudioProcessingFormat.maximumChannelCount).contains(selection.channelCount),
        selection.nativeSampleRate.isFinite,
        selection.nativeSampleRate > 0
      else {
        return false
      }
      switch configuration.loopMode {
      case .once, .infinite:
        return true
      case .playCount(let count):
        return RoutingFilePlaybackLoopMode.validPlayCountRange.contains(count)
      }
    case .fileOutput(let configuration):
      if let destination = configuration.destination {
        guard destination.url.isFileURL,
          !destination.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          return false
        }
      }
      do {
        _ = try AudioFileWriterConfiguration(
          destinationURL: configuration.destination?.url
            ?? URL(fileURLWithPath: "/tmp/Rilliya-File-Output"),
          container: configuration.container,
          encoding: configuration.encoding,
          sampleRate: configuration.sampleRate,
          channelCount: configuration.channelCount
        )
        return true
      } catch {
        return false
      }
    case .networkSend(let configuration):
      return !configuration.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && configuration.host.utf8.count <= 255
        && configuration.port > 0
        && isValidNetworkFormat(
          sampleRate: configuration.sampleRate,
          channelCount: configuration.channelCount
        )
    case .networkReceive(let configuration):
      return configuration.port > 0
        && isValidNetworkFormat(
          sampleRate: configuration.sampleRate,
          channelCount: configuration.channelCount
        )
    case .delay(let configuration):
      return configuration.delaySeconds.isFinite
        && (RoutingDelayConfiguration
          .minimumDelaySeconds...RoutingDelayConfiguration.maximumDelaySeconds).contains(
            configuration.delaySeconds
          )
        && configuration.feedback.isFinite
        && (-RoutingDelayConfiguration.maximumFeedback...RoutingDelayConfiguration.maximumFeedback)
          .contains(configuration.feedback)
        && configuration.dryWetMix.isFinite
        && (0...1).contains(configuration.dryWetMix)
    case .noiseGate(let configuration):
      return configuration.isValid
    case .compressor(let configuration):
      return configuration.isValid
    }
  }

  private static func isValidNetworkFormat(sampleRate: Double, channelCount: Int) -> Bool {
    sampleRate.isFinite
      && sampleRate >= 1
      && sampleRate <= 768_000
      && abs(sampleRate.rounded() - sampleRate) < 0.001
      && (1...256).contains(channelCount)
  }

  private static func isValidVirtualEndpointSelection(
    _ selection: RoutingVirtualAudioEndpointSelection?,
    presentation: RoutingChannelPresentation
  ) -> Bool {
    if let selection,
      selection.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      return false
    }
    return isValid(presentation)
  }

  private static func isValid(_ presentation: RoutingChannelPresentation) -> Bool {
    switch presentation {
    case .aggregate:
      return true
    case .separate(let channelCount):
      return (1...RoutingVisualizerConfiguration.maximumAvailableChannelCount).contains(
        channelCount
      )
    }
  }
}

struct RoutingViewportSnapshot: Codable, Equatable, Sendable {
  let zoom: Double
  let offsetX: Double
  let offsetY: Double

  init(transform: FlowingCanvasTransform) {
    zoom = transform.zoom
    offsetX = transform.offset.width
    offsetY = transform.offset.height
  }

  func makeTransform() throws -> FlowingCanvasTransform {
    guard zoom.isFinite,
      (0.3...3).contains(zoom),
      offsetX.isFinite,
      offsetY.isFinite,
      abs(offsetX) <= RoutingWorkflowPersistenceLimits.maximumViewportOffset,
      abs(offsetY) <= RoutingWorkflowPersistenceLimits.maximumViewportOffset
    else {
      throw RoutingWorkflowPersistenceError.invalidViewport
    }
    return FlowingCanvasTransform(
      zoom: CGFloat(zoom),
      offset: CGSize(width: offsetX, height: offsetY)
    )
  }
}

enum RoutingWorkflowPersistenceError: Error, Equatable {
  case duplicateWorkflowID
  case emptyLibrary
  case emptyWorkflowName
  case graphTooLarge
  case invalidNode
  case invalidViewport
  case unknownSelectedWorkflow
  case unsupportedSchemaVersion(Int)
  case documentTooLarge
}

private enum RoutingWorkflowPersistenceLimits {
  static let maximumDocumentByteCount = 16 * 1_024 * 1_024
  static let maximumWorkflowCount = 256
  static let maximumNodeCount = 2_048
  static let maximumEdgeCount = 8_192
  static let maximumTotalNodeCount = 4_096
  static let maximumTotalEdgeCount = 16_384
  static let maximumViewportOffset = 10_000_000.0
}

actor RoutingWorkflowPersistenceStore {
  enum RestorationSource: Equatable, Sendable {
    case primary
    case backup
  }

  enum LoadResult: Equatable, Sendable {
    case noDocument
    case restored(RoutingWorkflowLibrarySnapshot, source: RestorationSource)
  }

  private struct DocumentHeader: Decodable {
    let schemaVersion: Int
  }

  private struct Document: Codable {
    // Rilliya is pre-1.0, so the output-audio selection shape is intentionally not migrated.
    static let currentSchemaVersion = 3

    let schemaVersion: Int
    let library: RoutingWorkflowLibrarySnapshot
  }

  let fileURL: URL
  let backupURL: URL

  init(fileURL: URL = RoutingWorkflowPersistenceStore.defaultFileURL()) {
    self.fileURL = fileURL
    backupURL = fileURL.deletingPathExtension().appendingPathExtension("backup.json")
  }

  func load() throws -> RoutingWorkflowLibrarySnapshot? {
    switch try loadResult() {
    case .noDocument:
      nil
    case .restored(let snapshot, _):
      snapshot
    }
  }

  func loadResult() throws -> LoadResult {
    let fileManager = FileManager.default
    let candidates: [(url: URL, source: RestorationSource)] = [
      (fileURL, .primary),
      (backupURL, .backup),
    ].filter { fileManager.fileExists(atPath: $0.url.path) }
    guard !candidates.isEmpty else { return .noDocument }

    var lastError: Error?
    for candidate in candidates {
      do {
        return .restored(
          try decodeDocument(at: candidate.url).library,
          source: candidate.source
        )
      } catch {
        lastError = error
      }
    }
    throw lastError ?? CocoaError(.fileReadCorruptFile)
  }

  func save(_ snapshot: RoutingWorkflowLibrarySnapshot) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    if fileManager.fileExists(atPath: fileURL.path),
      (try? decodeDocument(at: fileURL)) != nil
    {
      if fileManager.fileExists(atPath: backupURL.path) {
        try fileManager.removeItem(at: backupURL)
      }
      try fileManager.copyItem(at: fileURL, to: backupURL)
    }

    let document = Document(
      schemaVersion: Document.currentSchemaVersion,
      library: snapshot
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(document)
    guard data.count <= RoutingWorkflowPersistenceLimits.maximumDocumentByteCount else {
      throw RoutingWorkflowPersistenceError.documentTooLarge
    }
    try data.write(to: fileURL, options: .atomic)
  }

  private func decodeDocument(at url: URL) throws -> Document {
    let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
    guard
      (resourceValues.fileSize ?? RoutingWorkflowPersistenceLimits.maximumDocumentByteCount + 1)
        <= RoutingWorkflowPersistenceLimits.maximumDocumentByteCount
    else {
      throw RoutingWorkflowPersistenceError.documentTooLarge
    }
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    let decoder = JSONDecoder()
    let header = try decoder.decode(DocumentHeader.self, from: data)
    guard header.schemaVersion == Document.currentSchemaVersion else {
      throw RoutingWorkflowPersistenceError.unsupportedSchemaVersion(header.schemaVersion)
    }
    return try decoder.decode(Document.self, from: data)
  }

  nonisolated static func defaultFileURL() -> URL {
    let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    )[0]
    return
      applicationSupport
      .appendingPathComponent("moe.uwucocoa.rilliya", isDirectory: true)
      .appendingPathComponent("workflows.json", isDirectory: false)
  }
}
