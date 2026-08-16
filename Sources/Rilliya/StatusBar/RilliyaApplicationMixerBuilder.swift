import CoreGraphics
import Foundation
import RilliyaCore

enum RilliyaApplicationMixerBuilder {
  static let workflowID = UUID(
    uuid: (0x52, 0x69, 0x6C, 0x6C, 0x69, 0x79, 0x61, 0x4D, 0x69, 0x78, 0x65, 0x72, 0, 0, 0, 1)
  )
  static let outputNodeID = UUID(
    uuid: (0x52, 0x69, 0x6C, 0x6C, 0x69, 0x79, 0x61, 0x4F, 0x75, 0x74, 0x70, 0x75, 0x74, 0, 0, 1)
  )

  @MainActor
  static func makeWorkflow(
    applications: [RilliyaManagedApplication],
    defaultOutputDevice: AudioDevice?
  ) -> RoutingWorkflowModel? {
    guard !applications.isEmpty,
      let device = defaultOutputDevice,
      device.output != nil
    else { return nil }

    let outputSelection = RoutingOutputDeviceSelection(id: device.id, displayName: device.name)
    let outputValue = RoutingNodeValue.outputAudio(
      selection: outputSelection,
      channelPresentation: .aggregate
    )
    var nodes = [
      node(
        id: outputNodeID,
        value: outputValue,
        center: CGPoint(x: 640, y: 0)
      )
    ]
    var edges: [RoutingWorkspaceEdge] = []

    for (index, application) in applications.enumerated() {
      let centerY = CGFloat(index) * 180
      let sourceValue = RoutingNodeValue.applicationAudio(
        selection: RoutingApplicationSelection(
          stableID: application.id.uuidString,
          applicationURL: application.applicationURL,
          bundleIdentifier: application.bundleIdentifier,
          displayName: application.displayName
        ),
        channelPresentation: .aggregate
      )
      let gainValue = RoutingNodeValue.gain(configuration: application.gainConfiguration)
      nodes.append(
        node(
          id: application.sourceNodeID,
          value: sourceValue,
          center: CGPoint(x: 0, y: centerY)
        )
      )
      nodes.append(
        node(
          id: application.gainNodeID,
          value: gainValue,
          center: CGPoint(x: 320, y: centerY)
        )
      )
      edges.append(
        RoutingWorkspaceEdge(
          id: application.sourceToGainEdgeID,
          source: audioAddress(nodeID: application.sourceNodeID, direction: .output),
          target: audioAddress(nodeID: application.gainNodeID, direction: .input)
        )
      )
      edges.append(
        RoutingWorkspaceEdge(
          id: application.gainToOutputEdgeID,
          source: audioAddress(nodeID: application.gainNodeID, direction: .output),
          target: audioAddress(nodeID: outputNodeID, direction: .input)
        )
      )
    }

    guard
      let workspace = try? RoutingWorkspaceModel(
        restoringID: workflowID,
        nodes: nodes,
        edges: edges
      )
    else { return nil }
    return RoutingWorkflowModel(
      id: workflowID,
      name: "Application Controls",
      workspace: workspace,
      isRunning: true
    )
  }

  @MainActor
  static func applicationsReroutedByWorkflows(
    _ workflows: [RoutingWorkflowModel]
  ) -> Set<URL> {
    Set(
      workflows.filter(\.isRunning).flatMap { workflow in
        let sourceIDs = workflow.workspace.audioSourceNodeIDsFeedingOutputAudio
        return workflow.workspace.nodes.compactMap { node -> URL? in
          guard sourceIDs.contains(node.id),
            let selection = node.value.applicationSelection
          else { return nil }
          return canonicalApplicationURL(selection.applicationURL)
        }
      }
    )
  }

  private static func node(
    id: UUID,
    value: RoutingNodeValue,
    center: CGPoint
  ) -> RoutingWorkspaceNode {
    let size = RoutingCanvasMetrics.nodeSize(for: value)
    return RoutingWorkspaceNode(
      id: id,
      value: value,
      frame: CGRect(
        x: center.x - size.width / 2,
        y: center.y - size.height / 2,
        width: size.width,
        height: size.height
      )
    )
  }

  private static func audioAddress(
    nodeID: UUID,
    direction: RoutingPortDirection
  ) -> RoutingWorkspacePortAddress {
    RoutingWorkspacePortAddress(
      nodeID: nodeID,
      portID: RoutingGraphPortID(direction: direction, channel: .all)
    )
  }
}
